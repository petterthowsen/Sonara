# ListProjectTool.gd
class_name ListProjectTool extends AiTool


func get_name() -> String:
	return "list_project"


func get_description() -> String:
	return "List the open project: name, tempo, time signature, PPQ, markers, tracks, and mixer channels (compact)."


func execute(_args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var tracks: Array = []
	for t in project.tracks:
		tracks.append(compact_track(t))
	var channels: Array = []
	for c in project.channels:
		channels.append(compact_channel(project, c))
	var markers: Array = []
	for m in ListMarkersTool.sorted_markers(project):
		markers.append(ListMarkersTool.describe_marker(project, m))
	return ok({
		"name": project.project_name,
		"tempo": project.tempo,
		"time_signature": "%d/%d" % [project.time_numerator, project.time_denominator],
		"ppq": project.ppq,
		"markers": markers,
		"tracks": tracks,
		"channels": channels,
	})
