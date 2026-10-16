# TrackVisibility.gd
# Spec 047: every rule for showing and hiding tracks as a set, and for the project's visibility
# presets. Static functions over a Project, so hotkeys and the Track List panel share one path.
# Every mutating call is one undo step through HistoryUtil.
#
# Hidden lives on the channel (issue 70), so visibility is set per *target*: the track's linked
# channel, or the track itself when it has none. A target is hidden when any of its tracks is in the
# requested set; each target is set once.
class_name TrackVisibility extends RefCounted


## What `set_hidden` has to be called on for `track`: its linked channel, or the track itself.
static func target_of(_project: Project, track: Track) -> Object:
	var channel := track.get_linked_channel()
	return channel if channel != null else track


## Sorted IDs of the tracks whose own hidden flag is set (not the cascaded state).
static func capture(project: Project) -> Array[int]:
	var ids: Array[int] = []
	for track in project.tracks:
		if track.hidden:
			ids.append(track.id)
	ids.sort()
	return ids


## Command that makes exactly the tracks in `hidden_ids` hidden and every other track visible
## (IDs with no track are ignored), or null when no target changes. Not executed.
static func hidden_changes(project: Project, hidden_ids: Array) -> VisibilityStateCommand:
	var wanted := {}  # target -> bool hidden
	for track in project.tracks:
		var target := target_of(project, track)
		wanted[target] = bool(wanted.get(target, false)) or hidden_ids.has(track.id)
	var old_values := {}
	var new_values := {}
	for target in wanted:
		var hidden: bool = wanted[target]
		if target.hidden != hidden:
			old_values[target] = target.hidden
			new_values[target] = hidden
	if new_values.is_empty():
		return null
	return VisibilityStateCommand.new("Change Track Visibility", project, old_values, new_values)


## Hide exactly `hidden_ids` as one undo step. The active preset is left alone.
static func apply_hidden_set(project: Project, hidden_ids: Array, label: String = "Change Track Visibility") -> void:
	_execute(project, label, hidden_changes(project, hidden_ids), project.visibility_presets.active_index)


## Make every track visible and clear the active preset, as one undo step.
static func show_all(project: Project) -> void:
	_execute(project, "Show All Tracks", hidden_changes(project, []), -1)


## Apply preset `index`: hide exactly the tracks it stores, show every other one, make it active.
## One undo step. Returns false (and does nothing) when no preset has that index.
static func apply_preset(project: Project, index: int) -> bool:
	var presets := project.visibility_presets
	if index < 0 or index >= presets.count():
		return false
	var ids: Array = presets.get_preset(index)["hidden_track_ids"]
	_execute(project, "Apply Visibility Preset", hidden_changes(project, ids), index)
	return true


## Re-apply the active preset, discarding unsaved changes. False when there is none.
static func reset_preset(project: Project) -> bool:
	return apply_preset(project, project.visibility_presets.active_index)


## Step through "All" and then the presets in order, wrapping at either end. `direction` is +1
## (next) or -1 (previous). With no active preset the current position is "All".
static func step_preset(project: Project, direction: int) -> void:
	var presets := project.visibility_presets
	var slots := presets.count() + 1  # slot 0 = All, slot n = preset n - 1
	var next := posmod(presets.active_index + 1 + direction, slots)
	if next == 0:
		show_all(project)
	else:
		apply_preset(project, next - 1)


## Shift-click on a track's toggle: show `track` with its ancestors and descendants and hide every
## other track. When that is already the visible state, show all tracks instead. One undo step; the
## active preset is left alone.
static func show_only(project: Project, track: Track) -> void:
	if is_only_visible_branch(project, track):
		apply_hidden_set(project, [], "Show All Tracks")
		return
	var visible_targets := _branch_targets(project, track, true)
	var hidden_ids: Array[int] = []
	for other in project.tracks:
		if not visible_targets.has(target_of(project, other)):
			hidden_ids.append(other.id)
	apply_hidden_set(project, hidden_ids, "Show Only Track")


## True when `track`'s branch (the track, its ancestors, its descendants) is the only visible part
## of the project.
static func is_only_visible_branch(project: Project, track: Track) -> bool:
	var visible_targets := _branch_targets(project, track, true)
	for other in project.tracks:
		var should_hide := not visible_targets.has(target_of(project, other))
		if other.hidden != should_hide:
			return false
	return true


## Make `track` and all its descendants visible and leave every other track as it is. One undo step.
static func show_branch(project: Project, track: Track) -> void:
	var shown_targets := _branch_targets(project, track, false)
	var hidden_ids: Array[int] = []
	for other in project.tracks:
		if other.hidden and not shown_targets.has(target_of(project, other)):
			hidden_ids.append(other.id)
	apply_hidden_set(project, hidden_ids, "Show Branch")


## True while `track` itself is visible but at least one of its descendants is hidden.
static func is_mixed(project: Project, track: Track) -> bool:
	if track.hidden:
		return false
	for descendant in _descendants(project, track):
		if descendant.hidden:
			return true
	return false


## True when the active preset's stored state differs from the current hidden tracks. Never true
## with no active preset.
static func is_dirty(project: Project) -> bool:
	var presets := project.visibility_presets
	if presets.active_index < 0 or presets.active_index >= presets.count():
		return false
	var existing := _track_id_set(project)
	var stored: Array[int] = []
	for id in presets.get_preset(presets.active_index)["hidden_track_ids"]:
		if existing.has(id):
			stored.append(id)
	stored.sort()
	return stored != capture(project)


## Text for the preset selector: the active preset ("1: Orchestra", plus " *" when it has unsaved
## changes), else "Custom" while something is hidden, else "All".
static func selector_label(project: Project) -> String:
	var presets := project.visibility_presets
	if presets.active_index >= 0 and presets.active_index < presets.count():
		var label := presets.display_name(presets.active_index)
		return label + " *" if is_dirty(project) else label
	return "Custom" if not capture(project).is_empty() else "All"


## Append a preset holding the current hidden state, named "Vis Group N" (N = its position), and
## make it active. One undo step. Returns its index.
static func add_preset(project: Project) -> int:
	var presets := project.visibility_presets
	var before := presets.snapshot()
	var index := presets.add("Vis Group %d" % (presets.count() + 1), capture(project))
	presets.set_active(index)
	_record_presets(project, "Add Visibility Preset", before)
	return index


static func rename_preset(project: Project, index: int, new_name: String) -> void:
	var presets := project.visibility_presets
	new_name = new_name.strip_edges()
	if new_name.is_empty() or index < 0 or index >= presets.count():
		return
	var before := presets.snapshot()
	presets.rename(index, new_name)
	_record_presets(project, "Rename Visibility Preset", before)


static func delete_preset(project: Project, index: int) -> void:
	var presets := project.visibility_presets
	if index < 0 or index >= presets.count():
		return
	var before := presets.snapshot()
	presets.remove(index)
	_record_presets(project, "Delete Visibility Preset", before)


## Move preset `index` to position `to` (ignored when out of range). The active preset follows.
static func move_preset(project: Project, index: int, to: int) -> void:
	var presets := project.visibility_presets
	if index < 0 or index >= presets.count() or to < 0 or to >= presets.count() or index == to:
		return
	var before := presets.snapshot()
	presets.move(index, to)
	_record_presets(project, "Move Visibility Preset", before)


## Store the current hidden state in the active preset. One undo step.
static func save_preset(project: Project) -> void:
	var presets := project.visibility_presets
	if presets.active_index < 0 or presets.active_index >= presets.count():
		return
	var before := presets.snapshot()
	presets.set_hidden_ids(presets.active_index, capture(project))
	_record_presets(project, "Save Visibility Preset", before)


## Execute `visibility` (may be null) together with a switch of the active preset to
## `active_index` (when it differs) as one history entry.
static func _execute(project: Project, label: String, visibility: VisibilityStateCommand, active_index: int) -> void:
	var cmds: Array[Command] = []
	if visibility != null:
		visibility.name = label
		cmds.append(visibility)
	var presets := project.visibility_presets
	if presets.active_index != active_index:
		var before := presets.snapshot()
		var after := presets.snapshot()
		after["active"] = active_index
		cmds.append(VisibilityPresetsStateCommand.new(label, presets, before, after))
	HistoryUtil.execute_many(label, cmds)


## Record an edit of the preset list that was already applied, if it changed anything.
static func _record_presets(project: Project, label: String, before: Dictionary) -> void:
	var after := project.visibility_presets.snapshot()
	if after == before:
		return
	var cmd := VisibilityPresetsStateCommand.new(label, project.visibility_presets, before, after)
	HistoryUtil.record(cmd)


## Set of visibility targets for `track`, its descendants and (with `with_ancestors`) its ancestors.
static func _branch_targets(project: Project, track: Track, with_ancestors: bool) -> Dictionary:
	var targets := {}
	targets[target_of(project, track)] = true
	for descendant in _descendants(project, track):
		targets[target_of(project, descendant)] = true
	if with_ancestors:
		var parent: Track = project.get_track_by_id(track.parent_track_id) if track.parent_track_id >= 0 else null
		var seen := 0
		while parent != null and seen < 64:
			targets[target_of(project, parent)] = true
			parent = project.get_track_by_id(parent.parent_track_id) if parent.parent_track_id >= 0 else null
			seen += 1
	return targets


static func _descendants(project: Project, track: Track) -> Array[Track]:
	var out: Array[Track] = []
	for child in project.get_track_children(track):
		out.append(child)
		out.append_array(_descendants(project, child))
	return out


static func _track_id_set(project: Project) -> Dictionary:
	var ids := {}
	for track in project.tracks:
		ids[track.id] = true
	return ids
