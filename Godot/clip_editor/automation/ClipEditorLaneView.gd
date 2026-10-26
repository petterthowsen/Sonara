# ClipEditorLaneView.gd
# MIDI editor meaning of "shown": the lane has an entry in `Track.clip_editor_lanes`, in pane
# order. A newly opened lane gets `ValueLane.DEFAULT_HEIGHT`; lanes that stay open keep theirs.
class_name ClipEditorLaneView extends "res://arranger/tracklist/AutomationLaneView.gd"


# Loaded lazily: ValueLane is a UI script, and a static reference would pull it into every
# headless model test that touches this view.
static func _default_height() -> float:
	var limits: GDScript = load("res://clip_editor/value_lanes/ValueLane.gd")
	return limits.DEFAULT_HEIGHT


func _entry_index(track: Object, lane: Object) -> int:
	for i in range(track.clip_editor_lanes.size()):
		if track.clip_editor_lanes[i]["id"] == lane.id:
			return i
	return -1


func is_shown(track: Object, lane: Object) -> bool:
	return lane != null and _entry_index(track, lane) >= 0


func set_shown(track: Object, lane: Object, on: bool) -> void:
	if lane == null:
		return
	var index := _entry_index(track, lane)
	if on == (index >= 0):
		return
	var entries: Array[Dictionary] = []
	entries.assign(track.clip_editor_lanes.duplicate(true))
	if on:
		entries.append({"id": lane.id, "height": _default_height()})
	else:
		entries.remove_at(index)
	track.set_clip_editor_lanes(entries)


func shown_lanes(track: Object) -> Array:
	var out: Array = []
	for entry in track.clip_editor_lanes:
		for lane in track.automation_lanes:
			if lane.id == entry["id"]:
				out.append(lane)
				break
	return out


func capture(track: Object) -> Variant:
	return track.clip_editor_lanes.duplicate(true)


func restore(track: Object, state: Variant) -> void:
	if not (state is Array):
		return
	var entries: Array[Dictionary] = []
	entries.assign(state.duplicate(true))
	track.set_clip_editor_lanes(entries)


func apply_shown(track: Object, lanes: Array) -> void:
	var entries: Array[Dictionary] = []
	for lane in lanes:
		var index := _entry_index(track, lane)
		var height: float = track.clip_editor_lanes[index]["height"] if index >= 0 else _default_height()
		entries.append({"id": lane.id, "height": height})
	track.set_clip_editor_lanes(entries)


func on_lane_created(track: Object, lane: Object) -> void:
	set_shown(track, lane, true)
