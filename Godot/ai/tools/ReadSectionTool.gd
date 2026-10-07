# ReadSectionTool.gd
# read_section: score text for a span of bars across tracks (spec 025).
class_name ReadSectionTool extends AiTool

## Bars read per call.
const MAX_BARS := 16


func get_name() -> String:
	return "read_section"


func get_description() -> String:
	return (
		"Read bars of the song as score text, all tracks lined up on the same barlines. One line per track, "
		+ "`|` between bars: notes `D1/8` (pitch/value, dotted /8. , triplet /8t), chords `[D2 A2]/8`, rests `r/8`, ties `A3/4~`, "
		+ "velocity `@90` when it changes, keyswitches `ks:Name`; a token without a value repeats the previous one on that line. "
		+ "Drum tracks are an indented grid. Bars follow the signature map (7/8 bars are 3360 ticks). "
		+ "Up to %d bars per call. Edit with write_section." % MAX_BARS
	)


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"bars": {"type": "string", "description": "Bars to read, e.g. \"5-8\" or \"3\". Default: the selected range"},
			"tracks": {"type": "array", "items": {"type": "string"}, "description": "Track names. Default: every instrument track with notes in the bars"},
			"key": {"type": "string", "description": "Key for flat spelling, e.g. Dmin"},
		},
	}


func execute(args: Dictionary) -> Dictionary:
	var project_v = require_project()
	if project_v is Dictionary:
		return project_v
	var project: Project = project_v
	var range_v := _bar_range(project, args)
	if range_v.has("error"):
		return fail(str(range_v.error))
	var first := int(range_v.first)
	var last := int(range_v.last)
	var requested := last - first + 1
	var notes := PackedStringArray()
	if requested > MAX_BARS:
		last = first + MAX_BARS - 1
		notes.append("# showing bars %d-%d of the %d requested (limit %d bars per call)" % [first, last, requested, MAX_BARS])

	var named := _names(args)
	var tracks: Array[Track] = []
	var skipped := PackedStringArray()
	if named.is_empty():
		for t in project.tracks:
			_sort_track(t, tracks, skipped)
	else:
		for n in named:
			var t = resolve_track(project, {"track": n})
			if t is Dictionary:
				return t
			_sort_track(t, tracks, skipped)

	var span := ScoreSection.bar_plan(project, first, last)
	var plan: Array = span.plan
	var key_label := str(args.get("key", "")).strip_edges()
	var ctx := {"ppq": project.ppq, "key": ClipTextKey.parse_key(key_label), "tempo": project.tempo, "key_label": key_label}
	var rows: Array = []
	var empty := PackedStringArray()
	var shown := 0
	for t in tracks:
		var r := ScoreSection.read_track(project, t, span.start, span.end, plan, ctx)
		if not r.has_notes and named.is_empty():
			empty.append(t.name)
			continue
		rows.append_array(r.rows)
		shown += 1
	var text := ScoreText.layout(rows, plan, ctx)
	for n in notes:
		text += "\n" + n
	if not empty.is_empty():
		text += "\n# empty: %s" % ", ".join(empty)
	if not skipped.is_empty():
		text += "\n# skipped (audio): %s" % ", ".join(skipped)
	return ok_text(text, {"first_bar": first, "last_bar": last, "tracks": shown})


## Instrument tracks go to `tracks`; audio tracks are listed as skipped. Folders and groups hold
## no notes and are ignored.
func _sort_track(t: Track, tracks: Array[Track], skipped: PackedStringArray) -> void:
	match t.type:
		Track.TrackType.INSTRUMENT:
			if not tracks.has(t):
				tracks.append(t)
		Track.TrackType.AUDIO:
			skipped.append(t.name)


func _names(args: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var raw = args.get("tracks", [])
	if raw is String:
		raw = Array(raw.split(",", false))
	if raw is Array:
		for n in raw:
			var s := str(n).strip_edges()
			if not s.is_empty():
				out.append(s)
	return out


## {first, last} from `bars`, else the selected range, or {error}.
func _bar_range(project: Project, args: Dictionary) -> Dictionary:
	if args.has("bars") and not str(args.bars).strip_edges().is_empty():
		var r := ScoreSection.parse_bar_range(args.bars)
		if r.is_empty():
			return {"error": "bars must look like \"5-8\" or \"3\" (bar numbers start at 1)"}
		return r
	var time_range: Dictionary = Sonara.editor.get_time_range() if Sonara and Sonara.editor else {}
	if time_range.get("has", false) and time_range.get("has_end", false):
		var map := project.time_signature_map
		var num := project.time_numerator
		var den := project.time_denominator
		return {
			"first": map.bar_at_tick(int(time_range.start), num, den, project.ppq),
			"last": map.bar_at_tick(maxi(int(time_range.start), int(time_range.end) - 1), num, den, project.ppq),
		}
	return {"error": "bars is required (no range is selected), e.g. \"1-8\""}
