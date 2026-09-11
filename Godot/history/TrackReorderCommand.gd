# TrackReorderCommand.gd
# Undoable track reorder / folder reparent (stores before/after order snapshots).
class_name TrackReorderCommand extends Command

## Project whose track order is changed.
var project: Project = null

## Snapshot of track id -> {parent_track_id, order, child_track_ids} before.
var before_layout: Dictionary = {}

## Snapshot after the reorder.
var after_layout: Dictionary = {}


## Create a reorder command from before/after layout dictionaries.
func _init(
	p_project: Project = null,
	p_before: Dictionary = {},
	p_after: Dictionary = {}
) -> void:
	name = "Reorder Tracks"
	project = p_project
	before_layout = p_before
	after_layout = p_after


## Capture current parent/order/children for every track in the project.
static func capture_layout(p_project: Project) -> Dictionary:
	var layout: Dictionary = {}
	if p_project == null:
		return layout
	for track in p_project.tracks:
		layout[track.id] = {
			"parent_track_id": track.parent_track_id,
			"order": track.order,
			"child_track_ids": track.child_track_ids.duplicate(),
		}
	return layout


## Apply the after layout.
func do() -> void:
	_apply(after_layout)


## Apply the before layout.
func undo() -> void:
	_apply(before_layout)


## Write parent/order/children from a layout snapshot (order setter refreshes UI listeners).
func _apply(layout: Dictionary) -> void:
	if project == null:
		return
	for track in project.tracks:
		if not layout.has(track.id):
			continue
		var entry: Dictionary = layout[track.id]
		track.parent_track_id = entry["parent_track_id"]
		track.child_track_ids = entry["child_track_ids"].duplicate()
		track.order = entry["order"]  # emits order_changed for UI
