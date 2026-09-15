# RenameTrackTool.gd
class_name RenameTrackTool extends AiTool


func get_name() -> String:
	return "rename_track"


func get_description() -> String:
	return "Rename a track by name. If the track syncs name from its channel, the channel is renamed too."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"track": {"type": "string", "description": "Track name"},
			"new_name": {"type": "string", "description": "New display name"},
		},
		"required": ["track", "new_name"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var track = resolve_track(project, args)
	if track is Dictionary:
		return track
	var new_name := name_arg(args, "new_name")
	if new_name.is_empty():
		return fail("new_name is required")
	var old_name: String = track.name
	# Record the final (possibly suffixed) name so redo reapplies exactly that.
	var final_name: String = track.unique_name_for(new_name)
	HistoryUtil.execute_property("Rename Track", track, "set_name", track.name, final_name)
	var text := "Renamed \"%s\" to \"%s\"" % [old_name, track.name]
	if track.name != new_name:
		text += " (\"%s\" is taken or reserved)" % new_name
	return ok_text(text, compact_track(track))
