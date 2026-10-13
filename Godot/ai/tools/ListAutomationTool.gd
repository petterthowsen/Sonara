# ListAutomationTool.gd
# Read-only: automation lanes per track, with point values in real units.
class_name ListAutomationTool extends AiTool


func get_name() -> String:
	return "list_automation"


func get_description() -> String:
	return "List automation lanes: per track, each lane's parameter, point count and (up to 16) its points as [position, value] in real units. Omit track to list every track that has lanes."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {"track": {"type": "string", "description": "Track name (optional)"}},
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var tracks: Array = []
	if not str(args.get("track", "")).strip_edges().is_empty():
		var track = resolve_track(project, args)
		if track is Dictionary:
			return track
		tracks.append(track)
	else:
		for t in project.get_visual_track_list():
			if not t.automation_lanes.is_empty():
				tracks.append(t)
	var rows: Array = []
	for t in tracks:
		var channel: Channel = t.get_linked_channel()
		var lanes: Array = []
		for lane in t.automation_lanes:
			var row: Dictionary = AutomationToolUtil.describe_lane(t, lane)
			if not lane.target.is_resolvable(channel):
				row["unresolved"] = true
			lanes.append(row)
		rows.append({"track": t.name, "lanes": lanes})
	return ok({"tracks": rows})
