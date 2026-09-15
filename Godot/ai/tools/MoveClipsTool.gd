# MoveClipsTool.gd
class_name MoveClipsTool extends AiTool


const MAX_LISTED := 8


func get_name() -> String:
	return "move_clips"


func get_description() -> String:
	return (
		"Move or copy everything in a time span (end exclusive) so it starts at `to`, keeping each clip on its track. "
		+ "Clips crossing an edge are cut there; only the part inside moves. Copies share notes with the originals. "
		+ "Refuses if the destination is occupied unless overwrite is true. Undoable."
	)


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"start": {"type": "string", "description": "bar.beat.tick or bar number. Default: selected range"},
			"end": {"type": "string", "description": "Exclusive end, e.g. start 1 end 5 = bars 1–4"},
			"bars": {"type": "number", "description": "Length in bars when end is omitted"},
			"to": {"type": "string", "description": "Destination start, bar.beat.tick or bar number"},
			"tracks": {"type": "array", "items": {"type": "string"}, "description": "Track names (default: all tracks)"},
			"clip": {"type": "string", "description": "Only placements of this clip"},
			"copy": {"type": "boolean", "description": "Leave the originals in place (default false)"},
			"overwrite": {"type": "boolean", "description": "Replace clips under the destination (default false)"},
		},
		"required": ["to"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project_v = require_project()
	if project_v is Dictionary:
		return project_v
	var project: Project = project_v
	if not args.has("to"):
		return fail("to is required")
	var clip_id := ""
	if args.has("clip"):
		var clip_v = resolve_clip(project, args)
		if clip_v is Dictionary:
			return clip_v
		clip_id = clip_v.id
	var span := resolve_time_span(project, args)
	if span.has("error"):
		return span
	var tracks_v = resolve_track_filter(project, args)
	if tracks_v is Dictionary:
		return tracks_v
	var tracks: Array[Track] = tracks_v
	var to := resolve_start_ticks(project, args, "to")
	var copy := bool(args.get("copy", false))
	if to == span.start and not copy:
		return fail("to is the same as start; nothing to move")
	var result := ClipRangeActions.move_range(
		tracks, span.start, span.end, to, copy, bool(args.get("overwrite", false)), clip_id
	)
	var where := "%s–%s" % [_bbt(project, span.start), _bbt(project, span.end)]
	if result.has("error"):
		var conflicts: Array = result.conflicts
		if conflicts.is_empty():
			return fail("No clips in %s" % where)
		return fail("Destination is occupied by %s. Nothing was moved; pass overwrite: true to replace them." % _list(project, conflicts))
	var pieces: Array = result.pieces
	var placements: Array = []
	for p in pieces:
		placements.append(compact_instance(project, p))
	var verb := "Copied" if copy else "Moved"
	var text := "%s %d clip(s) from %s to %s: %s" % [verb, pieces.size(), where, _bbt(project, to), _list(project, pieces)]
	return ok_text(text, {"placements": placements})


func _list(project: Project, instances: Array) -> String:
	var parts: PackedStringArray = []
	for inst in instances:
		if parts.size() >= MAX_LISTED:
			parts.append("and %d more" % (instances.size() - MAX_LISTED))
			break
		parts.append(describe_instance(project, inst))
	return ", ".join(parts)


static func _bbt(project: Project, ticks: int) -> String:
	return ClipTextTime.format_bbt(ticks, project.ppq, project.time_numerator, project.time_denominator)
