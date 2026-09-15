# WriteClipTool.gd
class_name WriteClipTool extends AiTool


func get_name() -> String:
	return "write_clip"


func get_description() -> String:
	return (
		"Write notes into a named MIDI clip. All instances of this clip update together. The whole write is rolled back if any line fails.\n"
		+ "Grids: drum hits are 1-9 or x, rests are `.` — e.g. KICK |9 . . .|9 . . .|9 . . .|9 . . .|. Grids are diffed cell-by-cell (unchanged cells keep velocity and microtiming).\n"
		+ "Event ops, one per line (never a rewritten list):\n"
		+ "  %s — e.g. %s\n" % [ClipTextEvents.ADD_SYNTAX, ClipTextEvents.ADD_EXAMPLE]
		+ "  del n12 | move n12 2.1.000 | move n12 +1/16 | vel n12 88 | len n12 1/2  (ids from read_clip)\n"
		+ "Durations: %s. Middle C = C3." % ClipTextTime.DURATION_FORMS
	)


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"clip": {"type": "string", "description": "Clip name"},
			"text": {"type": "string", "description": "Grid body (with clip header) or event op lines"},
			"key": {"type": "string", "description": "Key if not in the header"},
			"format": {
				"type": "string",
				"enum": ["auto", "drums", "pitched", "events"],
			},
		},
		"required": ["clip", "text"],
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
	if clip.type != Clip.ClipType.MIDI:
		return fail("Audio clips have no MIDI text format")
	var text := str(args.get("text", ""))
	var track := _first_track(project, clip)
	var opts := clip_text_opts(project, args, track)
	var before: Array = ClipNotesStateCommand.capture_clip_notes(clip)
	var result := ClipText.apply(clip, project, text, opts)
	if not result.get("ok", false):
		_restore(clip, before)
		return fail(str(result.get("error", "write failed")))
	var after: Array = ClipNotesStateCommand.capture_clip_notes(clip)
	if not _same_notes(before, after):
		HistoryUtil.record(ClipNotesStateCommand.new("Write Clip", clip, before, after))
	var data := compact_clip(project, clip)
	data["format"] = result.get("kind", "")
	data["changes"] = result.get("changes", [])
	var ser := ClipText.serialize(clip, opts)
	if ser.get("ok", false):
		data["text"] = ser.text
	return ok(data)


func _first_track(project: Project, clip: Clip) -> Track:
	for inst in find_clip_instances(project, clip.id):
		if inst.track:
			return inst.track
	return null


func _same_notes(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		var x: Dictionary = a[i]
		var y: Dictionary = b[i]
		if x.get("id") != y.get("id") or x.get("note") != y.get("note"):
			return false
		if x.get("velocity") != y.get("velocity"):
			return false
		if x.get("start_tick") != y.get("start_tick") or x.get("duration_ticks") != y.get("duration_ticks"):
			return false
	return true


## Roll back a failed apply so a bad write is not left half-done.
func _restore(clip: Clip, before: Array) -> void:
	ClipNotesStateCommand.new("revert", clip, before, before)._restore(before)
