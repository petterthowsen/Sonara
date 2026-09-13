# ClipText.gd
# Compact MIDI clip serialization for the assistant (drums / pitched grid / events).
class_name ClipText extends RefCounted


const MAX_BARS := 32
const MAX_EMPTY_SERIALIZE_BARS := 8


## Choose drums / pitched grid / event list and emit header + body.
static func serialize(clip: Object, opts: Dictionary = {}) -> Dictionary:
	if clip == null:
		return _fail("No clip")
	if int(clip.get("type")) == 0:
		return _fail("Audio clips have no MIDI text format")
	var o := _normalize_opts(clip, opts)
	var kind: String = o.kind
	var reason := ""
	if kind.is_empty():
		var pick := _select_kind(clip, o)
		kind = pick.kind
		reason = str(pick.get("reason", ""))
	o.kind = kind
	if ClipTextGrid.notes_of(clip).is_empty() and int(o.bars) > MAX_EMPTY_SERIALIZE_BARS:
		if reason.is_empty():
			reason = "%d empty bars, showing first %d" % [o.bars, MAX_EMPTY_SERIALIZE_BARS]
		o.bars = MAX_EMPTY_SERIALIZE_BARS
	elif int(o.bars) > MAX_BARS:
		if reason.is_empty():
			reason = "showing first %d of %d bars" % [MAX_BARS, o.bars]
		o.bars = MAX_BARS
	var header := _format_header(clip, o)
	var body := ""
	if kind == "events":
		body = ClipTextEvents.serialize(clip, o)
	else:
		o.drums = kind == "drums"
		body = ClipTextGrid.serialize(clip, o)
	var text := header
	if not reason.is_empty():
		text += "\n# %s" % reason
	if not body.is_empty():
		text += "\n" + body
	return {
		"ok": true,
		"text": text,
		"kind": kind,
		"reason": reason,
		"bars": o.bars,
		"res": ClipTextTime.format_res(o.res_denom),
	}


## Apply a grid (diff-safe) or event ops to `clip`. Mutates notes; caller records history.
static func apply(clip: Object, project: Object, text: String, opts: Dictionary = {}) -> Dictionary:
	if clip == null:
		return _fail("No clip")
	if int(clip.get("type")) == 0:
		return _fail("Audio clips have no MIDI text format")
	if text.strip_edges().is_empty():
		return _fail("text is empty")
	var header := parse_header(text)
	if header.has("error"):
		return _fail(str(header.error))
	var o := _normalize_opts(clip, opts)
	if header.has("res_denom"):
		o.res_denom = header.res_denom
	if header.has("key") and not header.key.is_empty():
		o.key = header.key
		o.key_label = str(header.get("key_label", ""))
	var header_bars := 0
	if header.has("bars"):
		header_bars = clampi(int(header.bars), 1, MAX_BARS)
		o.bars = header_bars
	var kind := str(header.get("kind", ""))
	if kind.is_empty():
		kind = str(o.kind)
	if kind.is_empty():
		if ClipTextEvents.looks_like_ops(text) or ClipTextEvents.looks_like_list(text):
			kind = "events"
		elif _looks_like_grid(text):
			kind = "drums" if bool(o.prefer_drums) else "pitched"
		else:
			return _fail("Could not tell if this is a grid or event ops")
	if kind == "events":
		var ev := ClipTextEvents.apply(clip, project, text, o)
		if ev.has("error"):
			return _fail(str(ev.error), ev.get("changes", []))
		_apply_header_length(clip, o, header_bars)
		return {"ok": true, "kind": "events", "changes": ev.get("changes", [])}
	o.drums = kind == "drums"
	var parsed := ClipTextGrid.parse(text, o)
	if parsed.has("error"):
		return _fail(str(parsed.error))
	_apply_header_length(clip, o, header_bars)
	var changes: Array = ClipTextGrid.apply(clip, project, parsed, o)
	return {"ok": true, "kind": kind, "changes": changes}


## Parse the `clip ...` header line. Unknown tokens are ignored; `1/16` is res, not bars.
static func parse_header(text: String) -> Dictionary:
	var out := {}
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if not line.begins_with("clip "):
			break
		var tokens := _header_tokens(line.substr(5).strip_edges())
		var name_parts: PackedStringArray = []
		var i := 0
		while i < tokens.size():
			var tok := tokens[i]
			var t := tok.to_lower()
			if t == "harmonic" or (t == "type" and i + 1 < tokens.size() and tokens[i + 1].to_lower() == "harmonic"):
				return {"error": "harmonic clips are not supported; use drums or pitched MIDI"}
			if t in ["type", "res", "bars", "key", "tempo"]:
				if i + 1 >= tokens.size():
					break
				var field_err := _apply_header_field(out, t, tokens[i + 1])
				if not field_err.is_empty():
					return {"error": field_err}
				i += 2
			elif t in ["drums", "pitched", "events"]:
				out["kind"] = t
				i += 1
			elif t.begins_with("1/") and t.substr(2).is_valid_int():
				out["res_denom"] = ClipTextTime.parse_res(tok)
				i += 1
			elif t.is_valid_int() and not name_parts.is_empty() and not out.has("bars"):
				var n := t.to_int()
				if n > MAX_BARS:
					return {"error": "bars %d is too long (max %d)" % [n, MAX_BARS]}
				if n >= 1:
					out["bars"] = n
					out["bar_start"] = 1
					out["bar_end"] = n
				i += 1
			else:
				name_parts.append(tok)
				i += 1
		out["name"] = " ".join(name_parts).strip_edges()
		break
	return out


static func _header_tokens(line: String) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	while i < line.length():
		while i < line.length() and line[i] == " ":
			i += 1
		if i >= line.length():
			break
		if line[i] == "\"" or line[i] == "'":
			var q := line[i]
			i += 1
			var s := ""
			while i < line.length() and line[i] != q:
				s += line[i]
				i += 1
			if i < line.length():
				i += 1
			out.append(s)
		else:
			var s := ""
			while i < line.length() and line[i] != " ":
				s += line[i]
				i += 1
			out.append(s)
	return out


static func _apply_header_field(out: Dictionary, key: String, value: String) -> String:
	match key:
		"type":
			var t := value.to_lower()
			if t in ["drums", "pitched", "events"]:
				out["kind"] = t
		"res":
			out["res_denom"] = ClipTextTime.parse_res(value)
		"bars":
			if value.contains("/"):
				out["res_denom"] = ClipTextTime.parse_res(value)
				return ""
			var br := ClipTextTime.parse_bars(value)
			if br.is_empty():
				return ""
			if int(br.bars) > MAX_BARS:
				return "bars %d is too long (max %d)" % [br.bars, MAX_BARS]
			out["bars"] = br.bars
			out["bar_start"] = br.start
			out["bar_end"] = br.end
		"key":
			var parsed := ClipTextKey.parse_key(value)
			if not parsed.is_empty():
				out["key"] = parsed
				out["key_label"] = value
		"tempo":
			out["tempo"] = value.to_float()
	return ""


static func _select_kind(clip: Object, o: Dictionary) -> Dictionary:
	if bool(o.prefer_drums):
		return {"kind": "drums"}
	var step_ticks: int = ClipTextTime.ticks_per_step(o.ppq, o.res_denom)
	var count: int = ClipTextGrid.notes_of(clip).size()
	if count == 0:
		return {"kind": "pitched"}
	var span := ClipTextGrid.pitch_span(clip)
	if span > 16:
		return {"kind": "events", "reason": "%d-semitone span, serving event list" % span}
	if count > 64:
		return {"kind": "events", "reason": "%d notes, serving event list" % count}
	if not ClipTextGrid.is_grid_eligible(clip, step_ticks):
		return {"kind": "events", "reason": "unquantized or overlapping, serving event list"}
	return {"kind": "pitched"}


static func _format_header(clip: Object, o: Dictionary) -> String:
	var bits: PackedStringArray = [
		"clip %s" % clip.name,
		"type %s" % o.kind,
		"res %s" % ClipTextTime.format_res(o.res_denom),
		"bars %s" % ClipTextTime.format_bars(o.bars),
	]
	var key_label := str(o.get("key_label", ""))
	if not key_label.is_empty():
		bits.append("key %s" % key_label)
	var tempo := float(o.get("tempo", 0.0))
	if tempo > 0.0:
		bits.append("tempo %d" % int(tempo))
	return "   ".join(bits)


static func _normalize_opts(clip: Object, opts: Dictionary) -> Dictionary:
	var o := opts.duplicate()
	o.ppq = int(o.get("ppq", 960))
	o.numerator = int(o.get("numerator", 4))
	o.tempo = float(o.get("tempo", 0.0))
	o.res_denom = int(o.get("res_denom", ClipTextTime.parse_res(str(o.get("res", "1/16")))))
	var key_val = o.get("key", {})
	if key_val is String:
		o.key_label = key_val
		o.key = ClipTextKey.parse_key(key_val)
	elif key_val is Dictionary:
		o.key = key_val
		if not o.has("key_label"):
			o.key_label = ""
	else:
		o.key = {}
		o.key_label = str(o.get("key_label", ""))
	var kind := str(o.get("kind", "")).to_lower()
	if kind == "auto":
		kind = ""
	o.kind = kind
	o.prefer_drums = bool(o.get("prefer_drums", kind == "drums"))
	if not o.has("drum_names"):
		o.drum_names = {}
	if not o.has("bars"):
		var ticks: int = int(clip.content_length_ticks) if clip else 0
		if ticks <= 0 and clip and clip.has_method("get_content_length"):
			ticks = int(clip.get_content_length())
		o.bars = ClipTextTime.bars_from_ticks(ticks, o.ppq, o.numerator)
	return o


static func _apply_header_length(clip: Object, o: Dictionary, header_bars: int) -> void:
	if clip == null or header_bars <= 0:
		return
	clip.content_length_ticks = header_bars * ClipTextTime.ticks_per_bar(o.ppq, o.numerator)


static func _looks_like_grid(text: String) -> bool:
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.contains("|") and (line.contains(".") or line.contains("-") or line.contains("x") or line.contains("X")):
			return true
	return false


static func _fail(message: String, changes: Array = []) -> Dictionary:
	var d := {"ok": false, "error": message}
	if not changes.is_empty():
		d["changes"] = changes
	return d
