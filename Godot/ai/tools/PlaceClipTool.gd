# PlaceClipTool.gd
class_name PlaceClipTool extends AiTool


func get_name() -> String:
	return "place_clip"


func get_description() -> String:
	return "Place another instance of an existing named clip. All instances share the same notes — editing the clip updates every placement."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"clip": {"type": "string", "description": "Clip name (preferred) or clip_id"},
			"clip_id": {"type": "string", "description": "Clip id if the name is ambiguous"},
			"track_id": {"type": "integer", "description": "Track to place on (default: first existing placement's track)"},
			"start": {"type": "string", "description": "bar.beat.tick or bar number (default: playhead)"},
			"bars": {"type": "integer", "description": "Instance length in bars (default: clip length)"},
		},
		"required": ["clip"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project_v = require_project()
	if project_v is Dictionary:
		return project_v
	var project: Project = project_v
	var clip_v = resolve_clip(project, args)
	if clip_v is Dictionary:
		return clip_v
	var clip: Clip = clip_v
	var track: Track = null
	if args.has("track_id"):
		var t = resolve_track(project, args)
		if t is Dictionary:
			return t
		track = t
	else:
		for inst in find_clip_instances(project, clip.id):
			if inst.track:
				track = inst.track
				break
	if track == null:
		return fail("track_id is required (this clip has no placements yet)")
	if clip.type == Clip.ClipType.MIDI and track.type != Track.TrackType.INSTRUMENT:
		return fail("MIDI clips go on instrument tracks")
	if clip.type == Clip.ClipType.AUDIO and track.type != Track.TrackType.AUDIO:
		return fail("Audio clips go on audio tracks")
	var start := resolve_start_ticks(project, args)
	var duration: int = clip.content_length_ticks
	if args.has("bars"):
		duration = maxi(1, int(args.bars)) * ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)
	HistoryUtil.execute(ClipInstanceCreateCommand.new(
		track, clip, start, duration, project, false
	))
	var pos := ClipTextTime.format_bbt(start, project.ppq, project.time_numerator, project.time_denominator)
	var text := "Placed \"%s\" on %s at %s" % [clip.name, track.name, pos]
	return ok_text(text, compact_clip(project, clip))
