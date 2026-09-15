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
			"clip": {"type": "string", "description": "Clip name"},
			"track": {"type": "string", "description": "Track to place on (default: first existing placement's track)"},
			"start": {"type": "string", "description": "bar.beat.tick or bar number. Default: range start, else 1.1.000 on an empty track, else the playhead's bar"},
			"bars": {"type": "integer", "description": "Instance length in bars (default: clip length)"},
			"overwrite": {"type": "boolean", "description": "Replace clips in the way instead of refusing (default false)"},
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
	if args.has("track"):
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
		return fail("track is required (this clip has no placements yet)")
	if clip.type == Clip.ClipType.MIDI and track.type != Track.TrackType.INSTRUMENT:
		return fail("MIDI clips go on instrument tracks")
	if clip.type == Clip.ClipType.AUDIO and track.type != Track.TrackType.AUDIO:
		return fail("Audio clips go on audio tracks")
	var tpb := ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)
	var length: int = clip.content_length_ticks
	if args.has("bars"):
		length = maxi(1, int(args.bars)) * tpb
	var placement := resolve_placement(project, track, args, length)
	if placement.has("error"):
		return placement
	var start: int = placement.start
	var duration: int = placement.length
	if bool(args.get("overwrite", false)):
		HistoryUtil.record_many("Clear Clips", ClipRangeActions.clear(track, start, start + duration))
	HistoryUtil.execute(ClipInstanceCreateCommand.new(
		track, clip, start, duration, project, false
	))
	var text := "Placed \"%s\" on %s %s" % [clip.name, track.name, placement.reason]
	return ok_text(text, compact_clip(project, clip))
