# MoveTrackTool.gd
# Reorder tracks, or move them into / out of a group or folder, as one undo step.
class_name MoveTrackTool extends AiTool


func get_name() -> String:
	return "move_track"


func get_description() -> String:
	return "Reorder tracks, or move them into or out of a group or folder. Moves the listed tracks together, in the given order. Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"tracks": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Track names (a bus name also works), moved as a block in this order",
			},
			"into": {
				"type": "string",
				"description": "Group or folder name, or \"top\" for the top level. Omitted = stay under the current parent",
			},
			"after": {
				"type": "string",
				"description": "Sibling name to place the block after, or \"start\" for first. Omitted = last under the target parent",
			},
		},
		"required": ["tracks"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var names = args.get("tracks", [])
	if not names is Array or names.is_empty():
		return fail("tracks is required (a list of track names)")

	# 1. Resolve names to tracks, or track-less channels.
	var moved: Array[Track] = []
	var moved_channels: Array[Channel] = []
	var seen: Dictionary = {}
	for n in names:
		var name := str(n).strip_edges()
		var key := NameStyle.key(name)
		if seen.has(key):
			return fail("\"%s\" is listed twice. Nothing was changed." % name)
		seen[key] = true
		var found: Dictionary = project.find_by_name(name)
		var track: Track = found.get("track")
		var channel: Channel = found.get("channel")
		if track:
			moved.append(track)
		elif channel:
			moved_channels.append(channel)
		else:
			return _unchanged(_not_found(project, "track", name))
	if not moved.is_empty() and not moved_channels.is_empty():
		return fail("Move buses and tracks in separate calls. Nothing was changed.")
	if moved.is_empty():
		return _move_channels(project, moved_channels, args)
	return _move_tracks(project, moved, args)


## Append "Nothing was changed." to a fail dict.
static func _unchanged(err: Dictionary) -> Dictionary:
	return fail("%s. Nothing was changed." % str(err.get("error", "")))


func _move_tracks(project: Project, moved: Array[Track], args: Dictionary) -> Dictionary:
	# 2. Target parent.
	var parent_id: int = moved[0].parent_track_id
	var parent: Track = null
	var into_name := str(args.get("into", "")).strip_edges()
	if not into_name.is_empty():
		if NameStyle.key(into_name) == "top":
			parent_id = -1
		else:
			parent = project.find_by_name(into_name).get("track")
			if parent == null:
				return _unchanged(_not_found(project, "group or folder", into_name))
			if not parent.can_contain_tracks():
				return fail("\"%s\" is not a group or folder. Nothing was changed." % parent.name)
			parent_id = parent.id
	elif parent_id >= 0:
		parent = project.get_track_by_id(parent_id)
	var parent_label := "\"%s\"" % parent.name if parent else "the top level"

	# 3. Sibling to sit after.
	var after: Track = null
	var after_label := ""
	var after_name := str(args.get("after", "")).strip_edges()
	if not after_name.is_empty():
		if NameStyle.key(after_name) == "start":
			after_label = "start"
		else:
			var sib: Track = project.find_by_name(after_name).get("track")
			if sib == null:
				return _unchanged(_not_found(project, "track", after_name))
			if sib.parent_track_id != parent_id or moved.has(sib):
				return fail("\"%s\" is not inside %s (or is itself being moved). Nothing was changed." % [sib.name, parent_label])
			after = sib
			after_label = sib.name
	else:
		var siblings: Array[Track] = project._sorted_track_siblings(parent_id)
		for i in range(siblings.size() - 1, -1, -1):
			if not moved.has(siblings[i]):
				after = siblings[i]
				break

	# 4. Pre-check every track.
	for t in moved:
		if not project.can_place_track(t, parent_id):
			return fail("Cannot move \"%s\" into %s (into itself or its own child, a parent that can't hold tracks, or an aux return away from its source). Nothing was changed." % [t.name, parent_label])

	# 5. Apply as one history entry.
	var before := TrackReorderCommand.capture_layout(project)
	project.begin_track_layout_batch()
	var cursor := after
	for t in moved:
		project.place_track(t, parent_id, cursor)
		cursor = t
	project.end_track_layout_batch()
	var after_layout := TrackReorderCommand.capture_layout(project)
	if TrackReorderCommand.layouts_equal(before, after_layout):
		return ok_text("Already in place", {"tracks": _rows(project)})
	HistoryUtil.record(TrackReorderCommand.new(project, before, after_layout))
	if parent and not parent.is_folder_expanded:
		parent.is_folder_expanded = true

	var moved_names: PackedStringArray = []
	for t in moved:
		moved_names.append(t.name)
	var text := "Moved %s" % ", ".join(moved_names)
	if parent:
		text += " into \"%s\"" % parent.name
	elif not into_name.is_empty():
		text += " to the top level"
	if after_label == "start":
		text += " to the start"
	elif not after_label.is_empty():
		text += " after \"%s\"" % after_label
	return ok_text(text, {"tracks": _rows(project)})


## Track-less channels. Mixer nesting rules apply: buses and aux returns can't be nested
## into a group, so in practice this un-nests, or reports why the move is refused.
func _move_channels(project: Project, moved: Array[Channel], args: Dictionary) -> Dictionary:
	var parent: Channel = null
	var into_name := str(args.get("into", "")).strip_edges()
	if into_name.is_empty():
		return fail("into is required when moving buses: a group name, or \"top\" to un-nest. Nothing was changed.")
	if NameStyle.key(into_name) != "top":
		parent = project.find_by_name(into_name).get("channel")
		if parent == null or not parent.is_group_channel:
			return fail("\"%s\" is not a group. Nothing was changed." % into_name)
	var after: Channel = null
	var after_name := str(args.get("after", "")).strip_edges()
	if not after_name.is_empty() and NameStyle.key(after_name) != "start":
		after = project.find_by_name(after_name).get("channel")
		if after == null:
			return _unchanged(_not_found(project, "channel", after_name))
	for c in moved:
		if parent:
			if not project.can_nest_channel(c, parent, after):
				return fail("Cannot nest \"%s\" under \"%s\" (buses and aux returns can't be nested into a group). Nothing was changed." % [c.name, parent.name])
		elif not MixerChannelDrag.can_unnest(c):
			return fail("\"%s\" is not nested, so it can't be moved to the top level. Nothing was changed." % c.name)
	var cursor := after
	var changed := 0
	var names: PackedStringArray = []
	for c in moved:
		if MixerChannelDrag.commit(project, c, parent, cursor):
			changed += 1
		cursor = c
		names.append(c.name)
	if changed == 0:
		return ok_text("Already in place")
	var text := "Moved %s" % ", ".join(names)
	text += " into \"%s\"" % parent.name if parent else " to the top level"
	return ok_text(text, {"channels": names})


static func _rows(project: Project) -> Array:
	var rows: Array = []
	for t in project.get_visual_track_list():
		rows.append(compact_track(t))
	return rows
