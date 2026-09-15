# CreateTrackTool.gd
class_name CreateTrackTool extends AiTool


func get_name() -> String:
	return "create_track"


func get_description() -> String:
	return "Create an arrangement track. kind is instrument, audio, folder, or group."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Track display name"},
			"kind": {
				"type": "string",
				"enum": ["instrument", "audio", "folder", "group"],
				"description": "Track kind (maps to TrackCreateCommand)",
			},
		},
		"required": ["name", "kind"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var kind := str(args.get("kind", "instrument")).to_lower()
	if kind not in ["instrument", "audio", "folder", "group"]:
		return fail("kind must be instrument, audio, folder, or group")
	var track_name := str(args.get("name", "Track")).strip_edges()
	if track_name.is_empty():
		track_name = "Track"
	var cmd := TrackCreateCommand.new(project, kind, track_name)
	HistoryUtil.execute(cmd)
	if cmd.track == null:
		return fail("Failed to create track")
	var data := compact_track(cmd.track)
	if cmd.channel:
		data["channel"] = compact_channel(cmd.channel)
	return ok(data)
