# DeleteTrackTool.gd
class_name DeleteTrackTool extends AiTool


func get_name() -> String:
	return "delete_track"


func get_description() -> String:
	return "Delete a track by id. Undoable. Does not delete the linked mixer channel."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"track_id": {"type": "integer", "description": "Track id to delete"},
		},
		"required": ["track_id"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var track = resolve_track(project, args)
	if track is Dictionary:
		return track
	var snapshot := compact_track(track)
	var name: String = snapshot.name
	HistoryUtil.execute(TrackDeleteCommand.new(project, track))
	return ok_text("Deleted track \"%s\"" % name, snapshot)
