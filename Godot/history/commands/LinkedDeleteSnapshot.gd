# LinkedDeleteSnapshot.gd
# Shared remove/restore logic for TrackDeleteCommand and ChannelDeleteCommand.
# Collects a track subtree plus its linked mixer channels (or a channel plus its linked tracks),
# snapshots every side effect of Project.remove_track/remove_channel, and restores it on undo.
class_name LinkedDeleteSnapshot extends RefCounted

## Project the tracks and channels belong to.
var project: Project = null

## Tracks to delete, parents before children.
var tracks: Array[Track] = []

## Channels to delete, parents before children (nested aux returns after their parent).
var channels: Array[Channel] = []

## TrackReorderCommand layout captured before removal.
var _layout: Dictionary = {}

## Channel -> {output_channel_id, parent_channel_id, child_channel_ids} for every channel before removal.
var _channel_state: Dictionary = {}

## project.channels in order before removal.
var _channel_order: Array[Channel] = []

## project.tracks in order before removal.
var _track_order: Array[Track] = []


## Tracks whose channel stays in the mixer (include_track_channels false); re-registered on restore.
var _detached_tracks: Array[Track] = []


## Collect `root_tracks` (with subtrees) and `root_channels`, closing over linked partners.
## A channel reached only through a track is kept if a track outside the set still uses it.
## With `include_track_channels` false, tracks never pull in their channels (Delete Track).
func _init(
	p_project: Project = null,
	root_tracks: Array[Track] = [],
	root_channels: Array[Channel] = [],
	include_track_channels: bool = true
) -> void:
	project = p_project
	if project == null:
		return
	var pending_tracks: Array[Track] = root_tracks.duplicate()
	var pending_channels: Array[Channel] = root_channels.duplicate()
	while not pending_tracks.is_empty() or not pending_channels.is_empty():
		while not pending_tracks.is_empty():
			var t: Track = pending_tracks.pop_front()
			if t == null or tracks.has(t) or project.get_track_by_id(t.id) != t:
				continue
			_add_subtree(t)
		for t in tracks:
			if not include_track_channels:
				break
			var ch := project.get_track_mixer_channel(t)
			if ch and not channels.has(ch) and _only_used_by_set(ch):
				pending_channels.append(ch)
		while not pending_channels.is_empty():
			var ch: Channel = pending_channels.pop_front()
			if ch == null or ch.is_master or channels.has(ch) or project.get_channel_by_id(ch.id) != ch:
				continue
			channels.append(ch)
			for t in _users_of(ch):
				if not tracks.has(t):
					pending_tracks.append(t)
			# Aux returns belong to the parent's devices; they go with it.
			for child in project.get_channel_children(ch):
				if child.is_aux_return():
					pending_channels.append(child)
	# A plugin return can't be deleted on its own, only with its parent (or by removing its source).
	var kept: Array[Channel] = []
	for ch in channels:
		if not _is_lone_return(ch):
			kept.append(ch)
	channels = kept


## True when `ch` is a plugin return whose parent channel isn't deleted with it.
func _is_lone_return(ch: Channel) -> bool:
	if not ch.is_plugin_return() or ch.parent_channel_id < 0:
		return false
	for other in channels:
		if other.id == ch.parent_channel_id:
			return _is_lone_return(other)
	return project.get_channel_by_id(ch.parent_channel_id) != null


## Number of channels this delete removes.
func channel_count() -> int:
	return channels.size()


## Snapshot every side effect, then remove the tracks and channels.
func remove() -> void:
	if project == null:
		return
	_layout = TrackReorderCommand.capture_layout(project)
	_channel_order = project.channels.duplicate()
	_track_order = project.tracks.duplicate()
	_channel_state.clear()
	for ch in project.channels:
		_channel_state[ch] = {
			"output_channel_id": ch.output_channel_id,
			"parent_channel_id": ch.parent_channel_id,
			"child_channel_ids": ch.child_channel_ids.duplicate(),
		}

	# A surviving channel must forget removed tracks, or its later removal reroutes the ghosts.
	_detached_tracks.clear()
	for t in tracks:
		var ch := project.get_track_mixer_channel(t)
		if ch and not channels.has(ch):
			ch.unregister_track(t)
			_detached_tracks.append(t)

	for t in tracks:
		if project.get_track_by_id(t.id) == t:
			project.remove_track(t.id)

	# Children before parents, so a parent's removal doesn't un-nest and reroute them first.
	for i in range(channels.size() - 1, -1, -1):
		var ch := channels[i]
		# Removed tracks are still registered; drop them so remove_channel doesn't
		# reroute them to Master (and register them there).
		for t in ch.routed_tracks.duplicate():
			if tracks.has(t):
				ch.unregister_track(t)
		project.remove_channel(ch.id)


## Re-add the same Channel and Track objects and restore routes, nesting and layout.
func restore() -> void:
	if project == null:
		return
	for ch in channels:
		if project.get_channel_by_id(ch.id) != null:
			continue
		# Set before add so the mixer treats a nested strip as a fold-out child.
		var state: Dictionary = _channel_state.get(ch, {})
		ch.parent_channel_id = int(state.get("parent_channel_id", -1))
		project.add_channel(ch)
	_restore_order(project.channels, _channel_order)

	for t in tracks:
		if project.get_track_by_id(t.id) == null:
			project.add_track(t)
	_restore_order(project.tracks, _track_order)
	for t in _detached_tracks:
		var ch := project.get_track_mixer_channel(t)
		if ch:
			ch.register_track(t)

	var touched: Array[Channel] = []
	for ch in _channel_state:
		if project.get_channel_by_id(ch.id) != ch:
			continue
		var state: Dictionary = _channel_state[ch]
		var changed := channels.has(ch)
		var child_ids: Array[int] = []
		child_ids.assign(state["child_channel_ids"])
		if ch.child_channel_ids != child_ids:
			ch.child_channel_ids = child_ids
			changed = true
		if ch.parent_channel_id != int(state["parent_channel_id"]):
			ch.parent_channel_id = int(state["parent_channel_id"])
			changed = true
		if not ch.is_master and ch.output_channel_id != int(state["output_channel_id"]):
			ch.set_route(int(state["output_channel_id"]))
		if changed:
			touched.append(ch)
	for ch in touched:
		ch.notify_hierarchy_changed()

	if not _layout.is_empty():
		project.apply_track_layout(_layout)

	# A re-created engine channel lost its aux-out map, and a parent's map may point at
	# a return that was just re-added; resend both (no-op when not connected).
	for ch in touched:
		AuxReturnSync.sync_aux_map_to_engine(ch)


## Add `root` and its descendants (by parent id and child_track_ids), parents first.
func _add_subtree(root: Track) -> void:
	if tracks.has(root):
		return
	tracks.append(root)
	for child in project.get_track_children(root):
		_add_subtree(child)
	for child_id in root.child_track_ids:
		var child := project.get_track_by_id(child_id)
		if child:
			_add_subtree(child)


## Tracks in the project whose mixer channel is `ch`.
func _users_of(ch: Channel) -> Array[Track]:
	var result: Array[Track] = []
	for t in project.tracks:
		if t.default_channel_id == ch.id:
			result.append(t)
	return result


## True when every track using `ch` is already in the delete set.
func _only_used_by_set(ch: Channel) -> bool:
	if ch.is_master:
		return false
	for t in _users_of(ch):
		if not tracks.has(t):
			return false
	return true


## Reorder `current` in place to follow `before`; items not in `before` keep their relative order at the end.
static func _restore_order(current: Array, before: Array) -> void:
	var ordered: Array = []
	for item in before:
		if current.has(item):
			ordered.append(item)
	for item in current:
		if not ordered.has(item):
			ordered.append(item)
	for i in ordered.size():
		current[i] = ordered[i]
