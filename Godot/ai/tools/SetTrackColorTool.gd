# SetTrackColorTool.gd
class_name SetTrackColorTool extends AiTool


func get_name() -> String:
	return "set_track_color"


func get_description() -> String:
	return "Set a track color from a hex string such as #4a90d9."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"track_id": {"type": "integer", "description": "Track id"},
			"hex": {"type": "string", "description": "CSS hex color, e.g. #ff8800"},
		},
		"required": ["track_id", "hex"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var track = resolve_track(project, args)
	if track is Dictionary:
		return track
	var hex := str(args.get("hex", "")).strip_edges()
	var color := Color.from_string(hex, Color.TRANSPARENT)
	if color.a <= 0.0 and not hex.to_lower().ends_with("00"):
		return fail("Invalid hex color: %s" % hex)
	HistoryUtil.execute_property("Set Track Color", track, "set_color", track.get_color(), color)
	return ok(compact_track(track))
