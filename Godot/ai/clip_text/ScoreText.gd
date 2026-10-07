# ScoreText.gd
# Score text for the section tools (spec 025): one line per track, read left to right, positions
# coming from durations, `|` barlines checked against each bar's length. Pure text: it knows bars
# (a plan from the signature map) and notes in section-local ticks, never clips or tracks.
#
#   section bars 1-2   7/8
#   Bass:   ks:Sus_Alt D1/8 D1 F1 D1 G1 G#1 D1 | D1/4. r/8 F1/8 G1/4 |
#   Lead:   r/2 r/8 A3/4~ | A3/2 G3/4. |
#   Drums:
#     |1 . 2 . …|            (indented drum grid, applied by the project layer)
class_name ScoreText extends RefCounted


## Onsets and ends within this many ticks of the 1/32 (straight or triplet) grid are shown rounded.
const SNAP_TICKS := 20
## Bars per system (block of lines) in rendered text.
const SYSTEM_BARS := 4
const DEFAULT_VELOCITY := 100
const _DENOMS: Array[int] = [1, 2, 4, 8, 16, 32, 64]

const NOTE_FORM := "a note is <pitch>/<value>[@velocity][~], e.g. D1/8, F#2/4.@90, A3/2~ (the value goes right after the pitch; dotted `.`, triplet `t`); a rest is r/8; a chord is [D2 A2]/8; a keyswitch is ks:Name"

static var _re_note: RegEx
static var _re_rest: RegEx
static var _re_chord: RegEx
static var _re_pitch: RegEx


# --- Bar plan ---------------------------------------------------------------------------------

## One entry per bar: {bar (song bar number), start (section-local tick), length, numerator,
## denominator}. `meters` is one [numerator, denominator] per bar.
static func make_plan(first_bar: int, meters: Array, ppq: int) -> Array:
	var plan: Array = []
	var start := 0
	for i in meters.size():
		var m: Array = meters[i]
		var length := GridHelper.bar_ticks(ppq, int(m[0]), int(m[1]))
		plan.append({"bar": first_bar + i, "start": start, "length": length, "numerator": int(m[0]), "denominator": int(m[1])})
		start += length
	return plan


static func plan_length(plan: Array) -> int:
	if plan.is_empty():
		return 0
	var last: Dictionary = plan[plan.size() - 1]
	return int(last.start) + int(last.length)


## Index of the bar containing section tick `t` (the last bar for t at or past the end).
static func bar_index_at(plan: Array, t: int) -> int:
	for i in range(plan.size() - 1, -1, -1):
		if t >= int(plan[i].start):
			return i
	return 0


# --- Note values ------------------------------------------------------------------------------

## Note values the reader writes, longest first: {ticks, text, align}. A value may start on a
## multiple of `align` within its bar: half its length for straight values (a quarter on an
## off-beat eighth is fine), the undotted half for dotted ones, its own length for triplets.
static func values(ppq: int) -> Array:
	var p := maxi(1, ppq)
	var out: Array = []
	for d in [1, 2, 4, 8, 16, 32]:
		var straight := int(p * 4 / d)
		out.append({"ticks": straight, "text": "/%d" % d, "align": maxi(1, straight / 2)})
		if d >= 2 and d <= 16:
			out.append({"ticks": straight * 3 / 2, "text": "/%d." % d, "align": maxi(1, straight / 2)})
		if d >= 2:
			var trip := straight * 2 / 3
			out.append({"ticks": trip, "text": "/%dt" % d, "align": trip})
	out.sort_custom(func(a, b): return int(a.ticks) > int(b.ticks))
	return out


## Value texts that fill `length` ticks starting `pos` ticks into a bar, fewest first found by a
## longest-first search. Empty when no combination fits (off the 1/32 grid).
static func split_span(pos: int, length: int, ppq: int) -> PackedStringArray:
	var out := PackedStringArray()
	if length <= 0:
		return out
	if _split(pos, length, values(ppq), out, 0):
		return out
	return PackedStringArray()


static func _split(pos: int, remaining: int, vals: Array, out: PackedStringArray, depth: int) -> bool:
	if remaining == 0:
		return true
	if depth >= 12:
		return false
	for v in vals:
		var t: int = v.ticks
		if t > remaining or pos % int(v.align) != 0:
			continue
		out.append(str(v.text))
		if _split(pos + t, remaining - t, vals, out, depth + 1):
			return true
		out.remove_at(out.size() - 1)
	return false


## Parse `/8`, `/4.`, `/8t` into ticks. -1 if it isn't one of those.
static func parse_value(text: String, ppq: int) -> int:
	if not text.begins_with("/"):
		return -1
	var body := text.substr(1)
	var digits := body.rstrip(".t")
	if not digits.is_valid_int() or not (digits.to_int() in _DENOMS):
		return -1
	return ClipTextTime.parse_duration("1/" + body, ppq)


## `8/8` (in the bar's own beats) or `N ticks` when it isn't a whole number of beats.
static func describe_length(ticks: int, denominator: int, ppq: int) -> String:
	var beat := GridHelper.beat_ticks(ppq, denominator)
	if ticks % beat == 0:
		return "%d/%d (%d ticks)" % [ticks / beat, denominator, ticks]
	return "%d ticks" % ticks


# --- Pitches ----------------------------------------------------------------------------------

## `C3` = 60, `C-2` = 0, `Bb1`, `F#4`. -1 if not a pitch name, -2 if a pitch name out of range.
static func parse_pitch(text: String) -> int:
	_init_regex()
	var m := _re_pitch.search(text)
	if m == null:
		return -1
	var semi := Midi._note_name_to_semitone(m.get_string(1))
	if semi < 0:
		return -1
	var midi := (m.get_string(2).to_int() + 2) * 12 + semi
	return midi if midi >= 0 and midi <= 127 else -2


static func pitch_text(note: int, key: Dictionary) -> String:
	return ClipTextKey.pitch_name(note, key)


## Keyswitch name key: lowercase, `_`, `-` and runs of spaces as one space.
static func normalize_name(name: String) -> String:
	var s := name.strip_edges().to_lower().replace("_", " ").replace("-", " ")
	while s.contains("  "):
		s = s.replace("  ", " ")
	return s


## Line label key (case- and space-insensitive).
static func label_key(label: String) -> String:
	var s := label.strip_edges().to_lower()
	while s.contains("  "):
		s = s.replace("  ", " ")
	return s


# --- Parsing ----------------------------------------------------------------------------------

## Labels in order of first appearance (so callers can build keyswitch maps before parse).
static func labels(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var seen := {}
	for raw in text.split("\n"):
		var line := raw.rstrip("\r")
		if line.is_empty() or line[0] == " " or line[0] == "\t":
			continue
		var t := line.strip_edges()
		if t.begins_with("#") or t.begins_with("section ") or not t.contains(":"):
			continue
		var label := t.substr(0, t.find(":")).strip_edges()
		if not label.is_empty() and not seen.has(label_key(label)):
			seen[label_key(label)] = true
			out.append(label)
	return out


## `section bars 5-8 …` → {first, last}, else {}.
static func parse_header(text: String) -> Dictionary:
	for raw in text.split("\n"):
		var t := raw.strip_edges()
		if not t.begins_with("section "):
			continue
		var bits := t.split(" ", false)
		for i in range(bits.size() - 1):
			if bits[i] == "bars":
				var r := ClipTextTime.parse_bars(bits[i + 1])
				if not r.is_empty() and bits[i + 1].contains("-"):
					return {"first": int(r.start), "last": int(r.end)}
		return {}
	return {}


## Parse score text against `plan`. ctx: {ppq, keyswitch_maps: {label_key: {normalized name:
## {key, name}}}} (see SfzKeyInfoUtil.keyswitch_map; a bare int key also works).
## Returns {ok: true, header, lines: [{label, kind: "notes", notes: [{pitch, start, length,
## velocity, held?}], keyswitches: [{name, key, at, bar}]} | {label, kind: "grid", text}]} or
## {ok: false, error}. Note starts are section-local ticks. `held` marks a note tied out of the
## last bar (it continues past the section; its length is cut at the end). A keyswitch's `key` is
## -1 when no map was given for its line.
static func parse(text: String, plan: Array, ctx: Dictionary = {}) -> Dictionary:
	_init_regex()
	var ppq := int(ctx.get("ppq", 960))
	var ks_maps: Dictionary = ctx.get("keyswitch_maps", {})
	var states := {}  # label_key -> state
	var order: Array = []
	var grid_label := ""  # label key of the drum block being captured
	var lines := text.split("\n")
	for li in lines.size():
		var raw := lines[li].rstrip("\r")
		var indented := not raw.is_empty() and (raw[0] == " " or raw[0] == "\t")
		var t := raw.strip_edges()
		if not grid_label.is_empty() and (indented or t.is_empty()):
			var gs: Dictionary = states[grid_label]
			gs.grid.append(t)
			continue
		grid_label = ""
		if t.is_empty() or t.begins_with("#") or t.begins_with("section "):
			continue
		if not t.contains(":"):
			return _fail("Line %d `%s`: expected `Track: notes …` (%s)" % [li + 1, t, NOTE_FORM])
		var label := t.substr(0, t.find(":")).strip_edges()
		var body := t.substr(t.find(":") + 1).strip_edges()
		if label.is_empty():
			return _fail("Line %d `%s`: a line starts with a track name, e.g. `Bass: D1/8 …`" % [li + 1, t])
		var lk := label_key(label)
		if not states.has(lk):
			states[lk] = _new_state(label)
			order.append(lk)
		var st: Dictionary = states[lk]
		if body.is_empty():
			if not st.notes.is_empty() or int(st.bar) > 0:
				return _fail("%s: a drum block can't follow note tokens on the same line" % label)
			st.kind = "grid"
			grid_label = lk
			continue
		if st.kind == "grid":
			return _fail("%s: note tokens can't follow a drum block on the same line" % label)
		var toks = _tokenize(body)
		if toks is String:
			return _fail("%s bar %d: %s" % [label, _bar_number(plan, int(st.bar)), toks])
		var err := _apply_tokens(st, toks, plan, ppq, ks_maps.get(lk, null))
		if not err.is_empty():
			return _fail(err)
	var out_lines: Array = []
	for lk in order:
		var st: Dictionary = states[lk]
		if st.kind == "grid":
			out_lines.append({"label": st.label, "kind": "grid", "text": "\n".join(st.grid)})
			continue
		var err := _finish(st, plan, ppq)
		if not err.is_empty():
			return _fail(err)
		out_lines.append({"label": st.label, "kind": "notes", "notes": st.notes, "keyswitches": st.ks})
	if out_lines.is_empty():
		return _fail("No track lines. Example: `Bass: D1/8 D1 F1 D1 | …|`")
	return {"ok": true, "header": parse_header(text), "lines": out_lines}


static func _new_state(label: String) -> Dictionary:
	return {
		"label": label, "kind": "notes", "grid": PackedStringArray(),
		"notes": [], "ks": [], "pending_ks": [],
		"bar": 0, "cursor": 0, "dur": -1, "vel": DEFAULT_VELOCITY,
		"tie": [],  # indices into notes held by a `~`
		"tie_pitches": [],
	}


static func _bar_number(plan: Array, index: int) -> int:
	if plan.is_empty():
		return index + 1
	if index < plan.size():
		return int(plan[index].bar)
	return int(plan[plan.size() - 1].bar) + (index - plan.size() + 1)


## Split a line body into raw tokens: `|`, `[…]…` chords, `ks:"…"`, and whitespace-separated
## words. Unquoted keyswitch names take following words that aren't tokens (`ks:sus alt D2/8`).
## Returns a PackedStringArray or an error String.
static func _tokenize(body: String) -> Variant:
	var words := PackedStringArray()
	var quoted: Array[bool] = []
	var i := 0
	var n := body.length()
	while i < n:
		var c := body[i]
		if c == " " or c == "\t":
			i += 1
			continue
		if c == "|":
			words.append("|")
			quoted.append(false)
			i += 1
			continue
		var j := i
		if c == "[":
			var close := body.find("]", i)
			if close < 0:
				return "`%s`: chord has no closing `]`" % body.substr(i)
			j = close + 1
		elif body.substr(i, 4).to_lower() == "ks:\"":
			var close := body.find("\"", i + 4)
			if close < 0:
				return "`%s`: keyswitch name has no closing quote" % body.substr(i)
			words.append("ks:" + body.substr(i + 4, close - i - 4))
			quoted.append(true)
			i = close + 1
			continue
		while j < n and body[j] != " " and body[j] != "\t" and body[j] != "|":
			j += 1
		words.append(body.substr(i, j - i))
		quoted.append(false)
		i = j
	# Join unquoted multi-word keyswitch names.
	var out := PackedStringArray()
	var k := 0
	while k < words.size():
		var w := words[k]
		if w.to_lower().begins_with("ks:") and not quoted[k]:
			var name := w.substr(3)
			while k + 1 < words.size() and not _is_token(words[k + 1]):
				k += 1
				name += " " + words[k]
			w = "ks:" + name
		out.append(w)
		k += 1
	return out


static func _is_token(w: String) -> bool:
	if w == "|" or w.to_lower().begins_with("ks:"):
		return true
	return _re_note.search(w) != null or _re_rest.search(w) != null or _re_chord.search(w) != null


static func _apply_tokens(st: Dictionary, toks: PackedStringArray, plan: Array, ppq: int, ks_map: Variant) -> String:
	var label: String = st.label
	for w in toks:
		var bar_no := _bar_number(plan, int(st.bar))
		if w == "|":
			var err := _close_bar(st, plan, ppq)
			if not err.is_empty():
				return err
			continue
		if int(st.bar) >= plan.size():
			return _bar_count_error(label, int(st.bar) + 1, plan, true)
		var where := "%s bar %d" % [label, bar_no]
		if w.to_lower().begins_with("ks:"):
			if not (st.tie as Array).is_empty():
				return "%s: `%s` comes after a tie `~`; a tie must be followed by the same note" % [where, w]
			var name := w.substr(3).strip_edges()
			var key := -1
			if ks_map is Dictionary:
				var nk := normalize_name(name)
				if not (ks_map as Dictionary).has(nk):
					return "%s: unknown keyswitch `%s`. Available: %s" % [where, name, ", ".join(_ks_names(ks_map))]
				var entry = ks_map[nk]
				key = int(entry.key) if entry is Dictionary else int(entry)
			st.ks.append({"name": name, "key": key, "at": -1, "bar": bar_no})
			st.pending_ks.append(st.ks.size() - 1)
			continue
		var parsed := _parse_event(w, ppq)
		if parsed.has("error"):
			return "%s: %s" % [where, parsed.error]
		var dur := int(parsed.dur)
		if dur < 0:
			dur = int(st.dur)
			if dur < 0:
				return "%s: `%s` needs a value — the first note or rest on a line sets it, e.g. %s/8" % [where, w, w.rstrip("~")]
		st.dur = dur
		if parsed.has("vel"):
			st.vel = int(parsed.vel)
		var at := int(plan[int(st.bar)].start) + int(st.cursor)
		var tie: Array = st.tie
		if parsed.kind == "rest":
			if not tie.is_empty():
				return "%s: a rest follows a tie `~`; a tie must be followed by the same note" % where
		else:
			var pitches: Array = parsed.pitches
			if not tie.is_empty():
				var want: Array = (st.tie_pitches as Array).duplicate()
				var got := pitches.duplicate()
				want.sort()
				got.sort()
				if want != got:
					return "%s: `%s` follows a tie `~` from %s; a tie joins the same pitch(es)" % [where, w, " ".join(_names(want))]
				for idx in tie:
					st.notes[idx].length = int(st.notes[idx].length) + dur
				if not parsed.tie:
					st.tie = []
					st.tie_pitches = []
			else:
				var added: Array = []
				for p in pitches:
					st.notes.append({"pitch": int(p), "start": at, "length": dur, "velocity": int(st.vel)})
					added.append(st.notes.size() - 1)
				for ki in st.pending_ks:
					st.ks[ki].at = at
				st.pending_ks = []
				if parsed.tie:
					st.tie = added
					st.tie_pitches = pitches
		st.cursor = int(st.cursor) + dur
	return ""


static func _close_bar(st: Dictionary, plan: Array, ppq: int) -> String:
	var bi := int(st.bar)
	if bi >= plan.size():
		return _bar_count_error(str(st.label), bi + 1, plan, true)
	var b: Dictionary = plan[bi]
	var cursor := int(st.cursor)
	if cursor != int(b.length):
		var den := int(b.denominator)
		return "%s bar %d adds up to %s; a %d/%d bar is %d ticks" % [
			st.label, int(b.bar), describe_length(cursor, den, ppq), int(b.numerator), den, int(b.length)]
	st.bar = bi + 1
	st.cursor = 0
	return ""


static func _finish(st: Dictionary, plan: Array, ppq: int) -> String:
	if int(st.cursor) > 0:
		var err := _close_bar(st, plan, ppq)
		if not err.is_empty():
			return err
	if not (st.tie as Array).is_empty():
		if int(st.bar) != plan.size():
			return "%s ends with a tie `~` but nothing follows it" % st.label
		# A tie out of the last bar: the note is held past the section end.
		for idx in st.tie:
			st.notes[idx].held = true
	if not (st.pending_ks as Array).is_empty():
		var ks: Dictionary = st.ks[st.pending_ks[0]]
		return "%s bar %d: `ks:%s` has no note after it" % [st.label, int(ks.bar), ks.name]
	if int(st.bar) != plan.size():
		return _bar_count_error(str(st.label), int(st.bar), plan, false)
	return ""


static func _bar_count_error(label: String, bars: int, plan: Array, too_many: bool) -> String:
	var span := "bars %d-%d" % [_bar_number(plan, 0), _bar_number(plan, plan.size() - 1)]
	if too_many:
		return "%s has more bars than the section (%d bars, %s)" % [label, plan.size(), span]
	return "%s has %d bars; the section has %d (%s)" % [label, bars, plan.size(), span]


## One note, chord or rest → {kind, pitches, dur (-1 = sticky), vel?, tie} or {error}.
static func _parse_event(w: String, ppq: int) -> Dictionary:
	var m := _re_rest.search(w)
	if m:
		return _with_value({"kind": "rest", "pitches": [], "tie": false}, m.get_string(1), "", w, ppq)
	m = _re_note.search(w)
	if m:
		var p := parse_pitch(m.get_string(1))
		if p == -2:
			return {"error": "pitch `%s` is out of range (C-2 to G8). %s" % [m.get_string(1), NOTE_FORM]}
		if p < 0:
			return {"error": "can't read `%s`: %s" % [w, NOTE_FORM]}
		return _with_value({"kind": "note", "pitches": [p], "tie": m.get_string(4) == "~"}, m.get_string(2), m.get_string(3), w, ppq)
	m = _re_chord.search(w)
	if m:
		var pitches: Array = []
		for name in m.get_string(1).split(" ", false):
			var p := parse_pitch(name)
			if p == -2:
				return {"error": "pitch `%s` in `%s` is out of range (C-2 to G8)" % [name, w]}
			if p < 0:
				return {"error": "can't read pitch `%s` in chord `%s`: %s" % [name, w, NOTE_FORM]}
			if not pitches.has(p):
				pitches.append(p)
		if pitches.is_empty():
			return {"error": "empty chord `%s`" % w}
		return _with_value({"kind": "chord", "pitches": pitches, "tie": m.get_string(4) == "~"}, m.get_string(2), m.get_string(3), w, ppq)
	return {"error": "can't read `%s`: %s" % [w, NOTE_FORM]}


static func _with_value(ev: Dictionary, value: String, vel: String, w: String, ppq: int) -> Dictionary:
	ev.dur = -1
	if not value.is_empty():
		var d := parse_value(value, ppq)
		if d <= 0:
			return {"error": "bad value `%s` in `%s` (use /1, /2, /4, /8, /16, /32, dotted /4., triplet /8t)" % [value, w]}
		ev.dur = d
	if not vel.is_empty():
		var v := vel.substr(1).to_int()
		if v < 1 or v > 127:
			return {"error": "velocity `%s` in `%s` is outside 1-127" % [vel, w]}
		ev.vel = v
	return ev


static func _ks_names(ks_map: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for k in ks_map.keys():
		var entry = ks_map[k]
		out.append(str(entry.name) if entry is Dictionary else str(k))
	return out


static func _names(pitches: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for p in pitches:
		out.append(Midi.midi_to_note_name(int(p)))
	return out


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


static func _init_regex() -> void:
	if _re_note != null:
		return
	const VALUE := "(/\\d+[.t]?)?"
	const VEL := "(@\\d+)?"
	_re_pitch = RegEx.create_from_string("^([A-Ga-g][#b]?)(-?\\d+)$")
	_re_note = RegEx.create_from_string("^([A-Ga-g][#b]?-?\\d+)" + VALUE + VEL + "(~)?$")
	_re_rest = RegEx.create_from_string("^[rR]" + VALUE + "$")
	_re_chord = RegEx.create_from_string("^\\[([^\\]]*)\\]" + VALUE + VEL + "(~)?$")


# --- Rendering --------------------------------------------------------------------------------

## Snap section tick `t` to the nearest 1/32 straight or triplet step within SNAP_TICKS; -1 if none.
static func snap(t: int, ppq: int) -> int:
	var best := -1
	var best_d := SNAP_TICKS + 1
	for step in [ppq / 8, ppq / 12]:
		var s: int = maxi(1, step)
		var c := int(round(float(t) / float(s))) * s
		var d := absi(c - t)
		if d < best_d:
			best_d = d
			best = c
	return best


## A note as the reader shows it: Vector2i(start, length) snapped to the grid, cut at `total`
## (section length), at least a 1/32 long. Vector2i(-1, -1) when it is off the grid. The project
## layer matches written notes against this, so a note read and written back is never changed.
static func snap_note(start: int, length: int, ppq: int, total: int) -> Vector2i:
	var s := snap(start, ppq)
	var e := snap(start + length, ppq)
	if s < 0:
		return Vector2i(-1, -1)
	if e > total or (e < 0 and start + length > total):
		e = total
	if e < 0:
		return Vector2i(-1, -1)
	if e <= s:
		e = mini(total, s + maxi(1, ppq / 8))
	return Vector2i(s, e - s)


## Render one track's notes (section-local ticks) into token bars per voice.
## notes: [{pitch, start, length, velocity}], keyswitches: [{name, at}].
## ctx: {ppq, key (parsed key Dictionary)}. Returns {off_grid: bool, reason, voices: [Array of
## PackedStringArray, one per bar]}.
static func render_track(notes: Array, keyswitches: Array, plan: Array, ctx: Dictionary = {}) -> Dictionary:
	var ppq := int(ctx.get("ppq", 960))
	var key: Dictionary = ctx.get("key", {})
	var total := plan_length(plan)
	# Snap and group into chords.
	var chords := {}  # "start:length" -> {start, length, pitches, velocity}
	for n in notes:
		var sn := snap_note(int(n.start), int(n.length), ppq, total)
		if sn.x < 0:
			return {"off_grid": true, "reason": "off-grid timing", "voices": []}
		var held := int(n.start) + int(n.length) > total
		var k := "%d:%d:%s" % [sn.x, sn.y, held]
		if not chords.has(k):
			chords[k] = {"start": sn.x, "length": sn.y, "pitches": [], "velocity": int(n.velocity), "held": held}
		if not chords[k].pitches.has(int(n.pitch)):
			chords[k].pitches.append(int(n.pitch))
	var list: Array = chords.values()
	for c in list:
		c.pitches.sort()
	list.sort_custom(func(a, b):
		if int(a.start) != int(b.start):
			return int(a.start) < int(b.start)
		return int(a.pitches[a.pitches.size() - 1]) > int(b.pitches[b.pitches.size() - 1]))
	# Voices: lowest voice whose last chord has ended.
	var voices: Array = []  # each: Array of chords
	var voice_end: Array[int] = []
	for c in list:
		var placed := false
		for vi in voices.size():
			if voice_end[vi] <= int(c.start):
				voices[vi].append(c)
				voice_end[vi] = int(c.start) + int(c.length)
				placed = true
				break
		if not placed:
			voices.append([c])
			voice_end.append(int(c.start) + int(c.length))
	if voices.is_empty():
		voices.append([])
	var ks_sorted := keyswitches.duplicate()
	ks_sorted.sort_custom(func(a, b): return int(a.at) < int(b.at))
	var out_voices: Array = []
	for vi in voices.size():
		var bars = _render_voice(voices[vi], ks_sorted if vi == 0 else [], plan, ppq, key)
		if bars == null:
			return {"off_grid": true, "reason": "durations that don't fit the 1/32 grid", "voices": []}
		out_voices.append(bars)
	return {"off_grid": false, "reason": "", "voices": out_voices}


## Token strings per bar for one voice, or null when a span can't be written as note values.
static func _render_voice(chords: Array, keyswitches: Array, plan: Array, ppq: int, key: Dictionary) -> Variant:
	var bars: Array = []
	for b in plan:
		bars.append(PackedStringArray())
	var state := {"dur": "", "vel": DEFAULT_VELOCITY}
	var cursor := 0
	var ki := 0
	var total := plan_length(plan)
	for c in chords:
		var s := int(c.start)
		if s > cursor and not _emit_span(bars, cursor, s - cursor, plan, ppq, "r", -1, state):
			return null
		while ki < keyswitches.size() and int(keyswitches[ki].at) <= s:
			var name := str(keyswitches[ki].name)
			var bi := bar_index_at(plan, s)
			bars[bi].append("ks:" + (name if not name.contains(" ") else "\"%s\"" % name))
			ki += 1
		var names := PackedStringArray()
		for p in c.pitches:
			names.append(pitch_text(int(p), key))
		var head := names[0] if names.size() == 1 else "[%s]" % " ".join(names)
		if not _emit_span(bars, s, int(c.length), plan, ppq, head, int(c.velocity), state, bool(c.get("held", false))):
			return null
		cursor = s + int(c.length)
	if cursor < total and not _emit_span(bars, cursor, total - cursor, plan, ppq, "r", -1, state):
		return null
	return bars


## Append tokens for [start, start+length): `head` is `r`, a pitch or `[chord]`. Notes cut by
## barlines or split into several values are tied with `~`; `held` adds a final `~` (the note
## continues past the section).
static func _emit_span(bars: Array, start: int, length: int, plan: Array, ppq: int, head: String, velocity: int, state: Dictionary, held: bool = false) -> bool:
	var pieces: Array = []  # [bar_index, value_text]
	var t := start
	var end := start + length
	while t < end:
		var bi := bar_index_at(plan, t)
		var b: Dictionary = plan[bi]
		var bar_end := int(b.start) + int(b.length)
		var piece_end := mini(end, bar_end)
		var vals := split_span(t - int(b.start), piece_end - t, ppq)
		if vals.is_empty():
			return false
		for v in vals:
			pieces.append([bi, v])
		t = piece_end
	var is_rest := head == "r"
	for i in pieces.size():
		var bi: int = pieces[i][0]
		var v: String = pieces[i][1]
		var tok := head
		var bar_tokens: PackedStringArray = bars[bi]
		var first_in_bar_line := bar_tokens.is_empty() and bi % SYSTEM_BARS == 0
		if v != str(state.dur) or first_in_bar_line:
			tok += v
			state.dur = v
		if not is_rest and i == 0 and velocity != int(state.vel):
			tok += "@%d" % velocity
			state.vel = velocity
		if not is_rest and (i < pieces.size() - 1 or held):
			tok += "~"
		bar_tokens.append(tok)
		bars[bi] = bar_tokens
	return true


## `section bars 5-8   7/8   tempo 105   key Dmin`; mixed meters list their bars.
static func header(plan: Array, ctx: Dictionary = {}) -> String:
	if plan.is_empty():
		return "section"
	var bits := PackedStringArray(["section bars %d-%d" % [int(plan[0].bar), int(plan[plan.size() - 1].bar)]])
	var runs: Array = []
	for b in plan:
		var sig := "%d/%d" % [int(b.numerator), int(b.denominator)]
		if runs.is_empty() or runs[runs.size() - 1].sig != sig:
			runs.append({"sig": sig, "first": int(b.bar), "last": int(b.bar)})
		else:
			runs[runs.size() - 1].last = int(b.bar)
	if runs.size() == 1:
		bits.append(runs[0].sig)
	else:
		var parts := PackedStringArray()
		for r in runs:
			parts.append("%s (bars %d-%d)" % [r.sig, r.first, r.last] if r.first != r.last else "%s (bar %d)" % [r.sig, r.first])
		bits.append(", ".join(parts))
	var tempo := float(ctx.get("tempo", 0.0))
	if tempo > 0.0:
		bits.append("tempo %d" % int(round(tempo)))
	var key_label := str(ctx.get("key_label", ""))
	if not key_label.is_empty():
		bits.append("key %s" % key_label)
	return "   ".join(bits)


## Lay rows out as systems of SYSTEM_BARS bars with aligned barlines. rows: [{label, bars:
## Array[PackedStringArray]}] for note lines, [{label, block: String}] for drum blocks (after the
## systems) and [{label, text: String}] for other preformatted parts (an event listing).
static func layout(rows: Array, plan: Array, ctx: Dictionary = {}) -> String:
	var out := PackedStringArray([header(plan, ctx)])
	var note_rows: Array = rows.filter(func(r): return r.has("bars"))
	if not note_rows.is_empty():
		var label_w := 0
		for r in note_rows:
			label_w = maxi(label_w, str(r.label).length() + 1)
		var first := 0
		while first < plan.size():
			var last := mini(plan.size(), first + SYSTEM_BARS) - 1
			if plan.size() > SYSTEM_BARS:
				out.append("# bars %d-%d" % [int(plan[first].bar), int(plan[last].bar)] if last > first else "# bar %d" % int(plan[first].bar))
			var widths: Array[int] = []
			for bi in range(first, last + 1):
				var w := 0
				for r in note_rows:
					w = maxi(w, " ".join(r.bars[bi]).length())
				widths.append(w)
			for r in note_rows:
				var line := (str(r.label) + ":").rpad(label_w + 1)
				for bi in range(first, last + 1):
					line += " " + " ".join(r.bars[bi]).rpad(widths[bi - first]) + " |"
				out.append(line.rstrip(" "))
			first = last + 1
	for r in rows:
		if r.has("block"):
			out.append("%s:" % r.label)
			for l in str(r.block).split("\n"):
				out.append(("  " + l) if not l.is_empty() else "")
		elif r.has("text"):
			out.append(str(r.text))
	return "\n".join(out)
