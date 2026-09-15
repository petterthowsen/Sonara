# ListTracksTool.gd
class_name ListTracksTool extends AiTool


func get_name() -> String:
	return "list_tracks"


func get_description() -> String:
	return "List arrangement tracks: name, type, channel (only if it differs from the track name), clip_count, color."


func execute(_args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var tracks: Array = []
	for t in project.tracks:
		tracks.append(compact_track(t))
	return ok({"tracks": tracks})
