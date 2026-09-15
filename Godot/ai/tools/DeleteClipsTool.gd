# DeleteClipsTool.gd
class_name DeleteClipsTool extends AiTool


func get_name() -> String:
	return "delete_clips"


func get_description() -> String:
	return "Remove clips from the timeline within a time span (end exclusive). Clips crossing an edge are cut there; only the part inside is removed. Named clips stay in the project. Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"start": {"type": "string", "description": "bar.beat.tick or bar number. Default: selected range"},
			"end": {"type": "string", "description": "Exclusive end, e.g. start 5 end 9 = bars 5–8"},
			"bars": {"type": "number", "description": "Length in bars when end is omitted"},
			"tracks": {"type": "array", "items": {"type": "string"}, "description": "Track names (default: all tracks)"},
			"clip": {"type": "string", "description": "Only placements of this clip. Without a span or range, removes all of its placements"},
		},
	}


func execute(args: Dictionary) -> Dictionary:
	var project_v = require_project()
	if project_v is Dictionary:
		return project_v
	var project: Project = project_v
	var clip_id := ""
	var clip_name := ""
	if args.has("clip"):
		var clip_v = resolve_clip(project, args)
		if clip_v is Dictionary:
			return clip_v
		clip_id = clip_v.id
		clip_name = clip_v.name
	var span := resolve_time_span(project, args, not clip_id.is_empty())
	if span.has("error"):
		return span
	var tracks_v = resolve_track_filter(project, args)
	if tracks_v is Dictionary:
		return tracks_v
	var tracks: Array[Track] = tracks_v
	var count := ClipRangeActions.delete_range(tracks, span.start, span.end, clip_id)
	var what := "placement(s) of \"%s\"" % clip_name if not clip_id.is_empty() else "clip(s)"
	if span.all:
		return ok_text("Removed %d %s" % [count, what], {"count": count})
	var where := "%s–%s" % [_bbt(project, span.start), _bbt(project, span.end)]
	if count == 0:
		return ok_text("No %s in %s" % [what, where], {"count": 0})
	return ok_text("Removed %d %s in %s (clips crossing an edge were cut)" % [count, what, where], {"count": count})


static func _bbt(project: Project, ticks: int) -> String:
	return ClipTextTime.format_bbt(ticks, project.ppq, project.time_numerator, project.time_denominator)
