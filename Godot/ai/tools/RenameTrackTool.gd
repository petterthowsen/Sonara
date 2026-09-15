# RenameTrackTool.gd
class_name RenameTrackTool extends AiTool


func get_name() -> String:
	return "rename_track"


func get_description() -> String:
	return "Rename a track by id. If the track syncs name from its channel, the channel is renamed too."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"track_id": {"type": "integer", "description": "Track id"},
			"name": {"type": "string", "description": "New display name"},
		},
		"required": ["track_id", "name"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var track = resolve_track(project, args)
	if track is Dictionary:
		return track
	var new_name := str(args.get("name", "")).strip_edges()
	if new_name.is_empty():
		return fail("name is required")
	HistoryUtil.execute_property("Rename Track", track, "set_name", track.name, new_name)
	return ok(compact_track(track))
