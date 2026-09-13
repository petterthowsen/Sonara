# ReadClipTool.gd
class_name ReadClipTool extends AiTool


func get_name() -> String:
	return "read_clip"


func get_description() -> String:
	return "Read one MIDI clip as compact text (drums grid, pitched grid, or event list). Refer to the clip by name. Times are clip-local (bar 1 = clip start). Note ids in event lists are stable (n<id>)."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"clip": {"type": "string", "description": "Clip name (preferred) or clip_id"},
			"clip_id": {"type": "string", "description": "Clip id if the name is ambiguous"},
			"format": {
				"type": "string",
				"enum": ["auto", "drums", "pitched", "events"],
				"description": "Force a representation; auto picks from the notes",
			},
			"key": {"type": "string", "description": "Key for scale degrees, e.g. Cmin or Gmaj"},
			"res": {"type": "string", "description": "Grid resolution 1/16, 1/12, or 1/24"},
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
	if clip.type != Clip.ClipType.MIDI:
		return fail("Audio clips have no MIDI text format")
	var track := _first_track(project, clip)
	var opts := clip_text_opts(project, args, track)
	var ser := ClipText.serialize(clip, opts)
	if not ser.get("ok", false):
		return fail(str(ser.get("error", "serialize failed")))
	var data := compact_clip(project, clip)
	data["text"] = ser.text
	data["format"] = ser.kind
	if str(ser.get("reason", "")) != "":
		data["reason"] = ser.reason
	return ok(data)


func _first_track(project: Project, clip: Clip) -> Track:
	for inst in find_clip_instances(project, clip.id):
		if inst.track:
			return inst.track
	return null
