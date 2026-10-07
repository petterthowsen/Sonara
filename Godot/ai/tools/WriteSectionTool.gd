# WriteSectionTool.gd
# write_section: replace the notes of the tracks named in score text, in one undo step (spec 025).
class_name WriteSectionTool extends AiTool

## Bars written per call.
const MAX_BARS := 64


func get_name() -> String:
	return "write_section"


func get_description() -> String:
	return (
		"Write score text for bars of the song: one line per track (read_section shows the format). "
		+ "Replaces the notes of each track named, inside those bars only; other tracks and bars are untouched, "
		+ "and notes you leave unchanged keep their velocity and timing. Every bar must add up to the bar's length "
		+ "(the error says what it added up to). Clips are found or created. One undo step."
	)


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"text": {"type": "string", "description": "Score text, e.g. `Bass: D1/8 D1 F1 D1 G1 G#1 D1 | D1/4. r/8 F1/8 G1/4 |`"},
			"bars": {"type": "string", "description": "Bars the text covers, e.g. \"5-8\". Optional when the text starts with `section bars 5-8`"},
			"shared_clips": {
				"type": "string",
				"enum": ["unique", "all"],
				"description": "When a clip is also placed elsewhere: unique gives these bars their own copy, all changes every placement. Without it the write is refused",
			},
		},
		"required": ["text"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project_v = require_project()
	if project_v is Dictionary:
		return project_v
	var project: Project = project_v
	var text := str(args.get("text", ""))
	if text.strip_edges().is_empty():
		return fail("text is required")
	var shared := str(args.get("shared_clips", "")).strip_edges().to_lower()
	if not shared in ["", "unique", "all"]:
		return fail("shared_clips must be \"unique\" or \"all\"")

	var range_v := _bar_range(args, text)
	if range_v.has("error"):
		return fail(str(range_v.error))
	var first := int(range_v.first)
	var last := int(range_v.last)
	if last - first + 1 > MAX_BARS:
		return fail("A section write covers at most %d bars; split it" % MAX_BARS)
	var span := ScoreSection.bar_plan(project, first, last)
	var plan: Array = span.plan

	# Label -> track, and each track's keyswitch names, before anything is parsed.
	var label_tracks := {}  # label_key -> Track
	var ks_maps := {}  # label_key -> {normalized name: {key, name}}
	for label in ScoreText.labels(text):
		var t = _track_for_label(project, label)
		if t is Dictionary:
			return t
		label_tracks[ScoreText.label_key(label)] = t
		ks_maps[ScoreText.label_key(label)] = ScoreSection.instrument_info(project, t).ks_map
	var parsed := ScoreText.parse(text, plan, {"ppq": project.ppq, "keyswitch_maps": ks_maps})
	if not parsed.ok:
		var err := str(parsed.error)
		if err.ends_with("Available: "):
			err += "(none: that track's instrument reports no keyswitches)"
		return fail(err)

	# Merge voices (`Piano.1`, `Piano.2`) into one note set per track.
	var order: Array[Track] = []
	var lines := {}  # Track -> {kind, notes, keyswitches, text}
	for l in parsed.lines:
		var t: Track = label_tracks[ScoreText.label_key(str(l.label))]
		if not lines.has(t):
			lines[t] = {"kind": l.kind, "notes": [], "keyswitches": [], "text": ""}
			order.append(t)
		var entry: Dictionary = lines[t]
		if str(l.kind) != str(entry.kind):
			return fail("%s has both note lines and a drum block; use one or the other" % t.name)
		if l.kind == "grid":
			if not entry.text.is_empty():
				return fail("%s has more than one drum block" % t.name)
			entry.text = l.text
		else:
			entry.notes.append_array(l.notes)
			entry.keyswitches.append_array(l.keyswitches)
	for t in order:
		if lines[t].kind == "grid":
			var meter_err := ScoreSection.drum_meter_error(plan)
			if not meter_err.is_empty():
				return fail("%s has a drum block, but %s" % [t.name, meter_err])

	# Refuse shared clips for every track before touching any.
	if shared.is_empty():
		for t in order:
			var sh := ScoreSection.shared_placements(project, t, span.start, span.end)
			if not sh.is_empty():
				return fail(ScoreSection.shared_error(project, t, sh, plan))

	var cmds: Array[Command] = []
	var results: Array = []
	for t in order:
		var r := ScoreSection.write(project, t, span.start, span.end, lines[t], {"plan": plan, "shared": shared})
		cmds.append_array(r.cmds)
		if not r.ok:
			_roll_back(cmds)
			return fail(str(r.error))
		results.append({"track": t, "r": r})
	HistoryUtil.record_many("Write Section", cmds)
	return _summary(first, last, results)


func _summary(first: int, last: int, results: Array) -> Dictionary:
	var out := PackedStringArray(["Wrote bars %d-%d on %d track%s." % [first, last, results.size(), "" if results.size() == 1 else "s"]])
	var warnings := PackedStringArray()
	var added := 0
	var changed := 0
	var removed := 0
	for item in results:
		var r: Dictionary = item.r
		added += int(r.added)
		changed += int(r.changed)
		removed += int(r.removed)
		var bits := PackedStringArray()
		if int(r.added) > 0:
			bits.append("+%d notes" % int(r.added))
		if int(r.changed) > 0:
			bits.append("%d changed" % int(r.changed))
		if int(r.removed) > 0:
			bits.append("%d removed" % int(r.removed))
		out.append("%s: %s" % [item.track.name, ", ".join(bits) if not bits.is_empty() else "no changes"])
		for c in r.created:
			out.append("Created clip \"%s\" on %s." % [c.name, item.track.name])
		for c in r.copied:
			out.append("Copied clip \"%s\" to \"%s\" for the placement at %s." % [c.from, c.to, c.at])
		warnings.append_array(r.warnings)
	if not warnings.is_empty():
		out.append("Warnings:")
		for w in warnings:
			out.append("- " + w)
	return ok_text("\n".join(out), {"tracks": results.size(), "added": added, "changed": changed, "removed": removed})


func _roll_back(cmds: Array[Command]) -> void:
	for i in range(cmds.size() - 1, -1, -1):
		cmds[i].undo()


## {first, last} from `bars` and the header, which must agree when both are given.
func _bar_range(args: Dictionary, text: String) -> Dictionary:
	var header := ScoreText.parse_header(text)
	var given := {}
	if args.has("bars") and not str(args.bars).strip_edges().is_empty():
		given = ScoreSection.parse_bar_range(args.bars)
		if given.is_empty():
			return {"error": "bars must look like \"5-8\" or \"3\" (bar numbers start at 1)"}
	if not header.is_empty() and not given.is_empty() and (int(header.first) != int(given.first) or int(header.last) != int(given.last)):
		return {"error": "The header says bars %d-%d but bars is %d-%d; make them agree" % [header.first, header.last, given.first, given.last]}
	if not given.is_empty():
		return given
	if not header.is_empty():
		return header
	return {"error": "bars is required, or start the text with `section bars 5-8`"}


## The track a score line label names. The whole label wins, then `Name.N` as voice N of `Name`.
func _track_for_label(project: Project, label: String) -> Variant:
	var found: Dictionary = project.find_by_name(label)
	var track = found.get("track")
	if track == null:
		var dot := label.rfind(".")
		if dot > 0 and label.substr(dot + 1).strip_edges().is_valid_int():
			track = project.find_by_name(label.substr(0, dot).strip_edges()).get("track")
	if track == null:
		var first = resolve_track(project, {"track": label})
		return first if first is Dictionary else fail("No track named '%s'" % label)
	if track.type != Track.TrackType.INSTRUMENT:
		return fail("\"%s\" is not an instrument track; section tools write MIDI notes only" % track.name)
	return track
