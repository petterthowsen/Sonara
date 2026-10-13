# AddAutomationLaneTool.gd
# Add an automation lane (with one seed point holding the current value) as one undo step.
class_name AddAutomationLaneTool extends AiTool


func get_name() -> String:
	return "add_automation_lane"


func get_description() -> String:
	return "Add an automation lane for one parameter of a track's own channel. The lane starts with one point at 1.1.000 holding the current value, so the sound doesn't change. One lane per parameter. Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": AutomationToolUtil.target_properties(),
		"required": ["track", "param"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var track = resolve_track(project, args)
	if track is Dictionary:
		return track
	var target = AutomationToolUtil.resolve_target(project, track, args)
	if target is Dictionary:
		return target
	var channel: Channel = track.get_linked_channel()
	var existing: AutomationLane = track.get_automation_lane_for(target)
	if existing:
		return fail("%s already has a %s lane (one lane per parameter)." % [track.name, existing.target.display_name(channel)])
	var lane: AutomationLane = AutomationToolUtil.new_lane(track, target)
	var seed_value: float = target.current_normalized_value(channel)
	var specs := [{"tick": 0, "value": seed_value, "curve": AutomationPoint.CurveType.LINEAR, "tension": 0.0}]
	AutomationActions.create_lane_with_points(track, lane, specs)
	track.automation_expanded = true
	var label: String = target.display_name(channel)
	return ok_text("Added %s lane on %s (starts at %s)" % [label, track.name, target.format_value(channel, seed_value)],
		AutomationToolUtil.describe_lane(track, lane))
