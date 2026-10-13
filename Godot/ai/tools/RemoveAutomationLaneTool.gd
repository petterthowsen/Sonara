# RemoveAutomationLaneTool.gd
# Delete an automation lane and all its points as one undo step.
class_name RemoveAutomationLaneTool extends AiTool


func get_name() -> String:
	return "remove_automation_lane"


func get_description() -> String:
	return "Delete an automation lane (and all its points) from a track. Undoable."


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
	if track.automation_lanes.is_empty():
		return fail("%s has no automation lanes" % track.name)
	var channel: Channel = track.get_linked_channel()
	var lane: AutomationLane = null
	var param_key := NameStyle.key(str(args.get("param", "")))
	if str(args.get("path", "")).strip_edges().is_empty() and not param_key.is_empty():
		# A lane whose device moved no longer resolves; its label still names it.
		var hits: Array[AutomationLane] = []
		for l in track.automation_lanes:
			if NameStyle.key(l.target.display_name(channel)) == param_key:
				hits.append(l)
		if hits.size() > 1:
			return fail("%s has %d lanes labelled '%s' (their devices are gone). Remove them in the arranger." % [track.name, hits.size(), str(args.param)])
		if hits.size() == 1:
			lane = hits[0]
	if lane == null:
		var target = AutomationToolUtil.resolve_target(project, track, args)
		if target is Dictionary:
			return target
		lane = track.get_automation_lane_for(target)
	if lane == null:
		var labels: PackedStringArray = []
		for l in track.automation_lanes:
			labels.append(l.target.display_name(channel))
		return fail("%s has no lane for '%s'. Its lanes: %s" % [track.name, str(args.get("param", "")), ", ".join(labels)])
	var label: String = lane.target.display_name(channel)
	var count := lane.points.size()
	AutomationActions.delete_lane(track, lane)
	return ok_text("Removed %s lane from %s (%d points)" % [label, track.name, count])
