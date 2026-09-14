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


## Capture current parent/order/children (and paired channel nest/route) for every track.
static func capture_layout(p_project: Project) -> Dictionary:
	var layout: Dictionary = {}
	if p_project == null:
		return layout
	for track in p_project.tracks:
		var ch := p_project.get_track_mixer_channel(track)
		layout[track.id] = {
			"parent_track_id": track.parent_track_id,
			"order": track.order,
			"child_track_ids": track.child_track_ids.duplicate(),
			"channel_parent_id": ch.parent_channel_id if ch else -1,
			"output_channel_id": ch.output_channel_id if ch else -1,
			"channel_child_ids": ch.child_channel_ids.duplicate() if ch else [],
		}
	return layout


## True if two layout snapshots describe the same parent/order/children.
static func layouts_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for id in a:
		if not b.has(id):
			return false
		var ae: Dictionary = a[id]
		var be: Dictionary = b[id]
		if ae["parent_track_id"] != be["parent_track_id"]:
			return false
		if ae["order"] != be["order"]:
			return false
		if ae["child_track_ids"] != be["child_track_ids"]:
			return false
		if ae.get("channel_parent_id", -1) != be.get("channel_parent_id", -1):
			return false
		if ae.get("output_channel_id", -1) != be.get("output_channel_id", -1):
			return false
		if ae.get("channel_child_ids", []) != be.get("channel_child_ids", []):
			return false
	return true


## Apply the after layout.
func do() -> void:
	if project:
		project.apply_track_layout(after_layout)


## Apply the before layout.
func undo() -> void:
	if project:
		project.apply_track_layout(before_layout)
