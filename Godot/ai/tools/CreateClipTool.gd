# CreateClipTool.gd
class_name CreateClipTool extends AiTool


func get_name() -> String:
	return "create_clip"


func get_description() -> String:
	return (
		"Create a named MIDI clip and place it on a track. Names must be unique — use place_clip to duplicate an existing clip on the timeline. "
		+ "Optional text writes the first notes, either as a grid (drum hits 1-9 or x, rests `.` — e.g. KICK |9 . . .|9 . . .|9 . . .|9 . . .|) "
		+ "or as event lines, one per note or chord: %s — e.g.\n%s\nadd 1.3.000 D3,F3,A3 1/4 v80\n" % [ClipTextEvents.ADD_SYNTAX, ClipTextEvents.ADD_EXAMPLE]
		+ "Durations: %s. If the text fails, no clip is created." % ClipTextTime.DURATION_FORMS
	)


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Unique clip name (the handle for later reads/writes)"},
			"track": {"type": "string", "description": "Track to place the first instance on"},
			"start": {"type": "string", "description": "bar.beat.tick or bar number. Default: range start, else 1.1.000 on an empty track, else the playhead's bar"},
			"bars": {"type": "integer", "description": "Clip length in bars (default: 1, or the range length)"},
			"overwrite": {"type": "boolean", "description": "Replace clips in the way instead of refusing (default false)"},
			"format": {
				"type": "string",
				"enum": ["auto", "drums", "pitched", "events"],
				"description": "Format of text: drums step grid, pitched grid, or event lines. auto (default) detects it",
			},
			"key": {"type": "string", "description": "Key for pitched clips, e.g. Cmin"},
			"text": {"type": "string", "description": "Optional initial notes: a grid or event lines (add ...)"},
		},
		"required": ["name", "track"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project_v = require_project()
	if project_v is Dictionary:
		return project_v
	var project: Project = project_v
	var track_v = resolve_track(project, args)
	if track_v is Dictionary:
		return track_v
	var track: Track = track_v
	if track.type != Track.TrackType.INSTRUMENT:
		return fail("MIDI clips go on instrument tracks")
	var clip_name := name_arg(args, "name")
	if clip_name.is_empty():
		return fail("name is required")
	for existing in project.clips.values():
		if existing is Clip and NameStyle.same(existing.name, clip_name):
			return fail("Clip '%s' already exists; use place_clip to add another instance" % existing.name)
	var tpb := ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)
	var requested_length := -1
	if args.has("bars"):
		requested_length = maxi(1, int(args.bars)) * tpb
	var placement := resolve_placement(project, track, args, requested_length)
	if placement.has("error"):
		return placement
	var start: int = placement.start
	var length: int = placement.length
	var bars := length / tpb
	var opts := clip_text_opts(project, args, track)
	opts["bars"] = bars
	if not opts.has("kind") and track_prefers_drums(project, track):
		opts["kind"] = "drums"
	var text := str(args.get("text", "")).strip_edges()
	if not text.is_empty():
		# Dry run on an unpooled scratch clip so bad text never leaves an empty clip behind.
		var scratch := project.create_clip(clip_name)
		scratch.content_length_ticks = length
		var trial := ClipText.apply(scratch, null, text, opts)
		if not trial.get("ok", false):
			return fail("%s. No clip was created." % str(trial.get("error", "initial text failed")))
	if bool(args.get("overwrite", false)):
		HistoryUtil.record_many("Clear Clips", ClipRangeActions.clear(track, start, start + length))
	var instance := ClipActions.create_clip(project, track, start, length, clip_name)
	if instance == null or instance.clip == null or not project.clips.has(instance.clip.id):
		return fail("Failed to create clip")
	var clip: Clip = instance.clip
	if not text.is_empty():
		var written := ClipText.apply(clip, project, text, opts)
		if not written.get("ok", false):
			return fail(str(written.get("error", "initial text failed")))
	if clip.midi_notes.is_empty() and int(clip.content_length_ticks) > length:
		clip.content_length_ticks = length
	var ser := ClipText.serialize(clip, opts)
	var data := compact_clip(project, clip)
	if ser.get("ok", false):
		data["text"] = ser.text
		data["format"] = ser.kind
	var result_text := "Created clip \"%s\" on \"%s\" %s (%d bars)" % [clip_name, track.name, placement.reason, bars]
	return ok_text(result_text, data)
