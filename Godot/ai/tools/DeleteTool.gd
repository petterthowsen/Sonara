# DeleteTool.gd
class_name DeleteTool extends AiTool


func get_name() -> String:
	return "delete"


func get_description() -> String:
	return "Delete a track, bus, or folder by name, with its linked mixer channel or track (if any) and child tracks. Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Track, bus, or folder name (see list_project)"},
		},
		"required": ["name"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var name := str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return fail("name is required")
	var found: Dictionary = project.find_by_name(name)
	var track: Track = found.get("track")
	var channel: Channel = found.get("channel")
	if track == null and channel == null:
		return _not_found(project, "track or channel", name)
	if track:
		var cmd := TrackDeleteCommand.new(project, track)
		HistoryUtil.execute(cmd)
		return _result(name, [track.name], _names(cmd.removed_channels()))
	# Bus-only name (no linked track): delete the channel.
	var cmd2 := ChannelDeleteCommand.new(project, channel)
	HistoryUtil.execute(cmd2)
	return _result(name, _names(cmd2.removed_tracks()), [channel.name])


func _names(items: Array) -> Array[String]:
	var out: Array[String] = []
	for item in items:
		out.append(item.name)
	return out


## `Deleted track "Drums"`, `Deleted channel "Bus"`, or `Deleted track and channel "Drums"`
## when both a track and a linked channel (or several linked tracks) were removed.
func _result(name: String, tracks: Array[String], channels: Array[String]) -> Dictionary:
	var parts: Array[String] = []
	if not tracks.is_empty():
		parts.append("track" if tracks.size() == 1 else "tracks")
	if not channels.is_empty():
		parts.append("channel" if channels.size() == 1 else "channels")
	var removed: Array[String] = []
	removed.append_array(tracks)
	for c in channels:
		if not removed.has(c):
			removed.append(c)
	var noun := " and ".join(parts) if not parts.is_empty() else "track"
	var quoted: Array[String] = []
	for r in removed:
		quoted.append("\"%s\"" % r)
	var text := "Deleted %s %s" % [noun, ", ".join(quoted)] if not quoted.is_empty() else "Deleted \"%s\"" % name
	return ok_text(text, {"removed_tracks": tracks, "removed_channels": channels})
