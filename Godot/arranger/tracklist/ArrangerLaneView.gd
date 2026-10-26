# ArrangerLaneView.gd
# Arranger meaning of "shown": `lane.visible`. Applying a shown set also expands the track's
# automation rows (REQ-022), so loaded lanes are actually visible.
class_name ArrangerLaneView extends "res://arranger/tracklist/AutomationLaneView.gd"


func is_shown(_track: Object, lane: Object) -> bool:
	return lane != null and lane.visible


func set_shown(_track: Object, lane: Object, on: bool) -> void:
	if lane != null:
		lane.set_visible(on)


func shown_lanes(track: Object) -> Array:
	var out: Array = []
	for lane in track.automation_lanes:
		if lane != null and lane.visible:
			out.append(lane)
	return out


func capture(track: Object) -> Variant:
	var visible := {}
	for lane in track.automation_lanes:
		visible[lane.id] = lane.visible
	return {"visible": visible, "expanded": track.automation_expanded}


func restore(track: Object, state: Variant) -> void:
	if not (state is Dictionary):
		return
	var visible: Dictionary = state["visible"]
	for lane in track.automation_lanes:
		if visible.has(lane.id):
			lane.set_visible(visible[lane.id])
	track.automation_expanded = state["expanded"]


func apply_shown(track: Object, lanes: Array) -> void:
	for lane in track.automation_lanes:
		lane.set_visible(lanes.has(lane))
	if not lanes.is_empty():
		track.automation_expanded = true
