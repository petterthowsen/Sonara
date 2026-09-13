# CreateClipTool.gd
class_name CreateClipTool extends AiTool


func get_name() -> String:
	return "create_clip"


func get_description() -> String:
	return "Create a named MIDI clip and place it on a track. Names must be unique — use place_clip to duplicate an existing clip on the timeline. Optional text writes the first notes. Drum hits are 1-9 or x, rests are `.` — e.g. KICK |9 . . .|9 . . .|9 . . .|9 . . .|"


func is_read_only() -> bool:
	return false


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Unique clip name (the handle for later reads/writes)"},
			"track_id": {"type": "integer", "description": "Track to place the first instance on"},
			"start": {"type": "string", "description": "bar.beat.tick or bar number (default: playhead)"},
			"bars": {"type": "integer", "description": "Clip length in bars (default 2)"},
			"kind": {
				"type": "string",
				"enum": ["drums", "pitched"],
				"description": "drums = step grid; pitched = pitch grid / events",
			},
			"key": {"type": "string", "description": "Key for pitched clips, e.g. Cmin"},
			"text": {"type": "string", "description": "Optional initial grid or event list"},
		},
		"required": ["name", "track_id"],
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
	var clip_name := str(args.get("name", "")).strip_edges()
	if clip_name.is_empty():
		return fail("name is required")
	for existing in project.clips.values():
		if existing is Clip and existing.name.to_lower() == clip_name.to_lower():
			return fail("Clip '%s' already exists; use place_clip to add another instance" % existing.name)
	var bars := maxi(1, int(args.get("bars", 2)))
	var start := resolve_start_ticks(project, args)
	var clip: Clip = project.create_clip(clip_name, Clip.ClipType.MIDI)
	clip.color = track.get_color()
	clip.content_length_ticks = bars * ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator)
	HistoryUtil.execute(ClipInstanceCreateCommand.new(
		track, clip, start, clip.content_length_ticks, project, true
	))
	if clip.id.is_empty() or not project.clips.has(clip.id):
		return fail("Failed to create clip")
	var opts := clip_text_opts(project, args, track)
	opts["bars"] = bars
	var kind := str(args.get("kind", "")).to_lower()
	if kind.is_empty() and track_prefers_drums(project, track):
		kind = "drums"
	if not kind.is_empty():
		opts["kind"] = kind
	var text := str(args.get("text", "")).strip_edges()
	if not text.is_empty():
		var written := ClipText.apply(clip, project, text, opts)
		if not written.get("ok", false):
			return fail(str(written.get("error", "initial text failed")))
	var tpb := ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator)
	if clip.midi_notes.is_empty() and int(clip.content_length_ticks) > bars * tpb:
		clip.content_length_ticks = bars * tpb
	var ser := ClipText.serialize(clip, opts)
	var data := compact_clip(project, clip)
	if ser.get("ok", false):
		data["text"] = ser.text
		data["format"] = ser.kind
	return ok(data)
