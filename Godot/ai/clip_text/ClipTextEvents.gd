# ClipTextEvents.gd
# Event-list serialization and diff-safe note operations.
class_name ClipTextEvents extends RefCounted


const ADD_SYNTAX := "add <bar.beat.tick> <pitch[,pitch…]> <duration> [v<velocity>]"
const ADD_EXAMPLE := "add 1.1.000 C3,E3,G3 1/2 v90"


## Serialize clip notes as an event list (`n12  1.1.000  C2  1/4  v104`).
static func serialize(clip: Object, opts: Dictionary) -> String:
	var ppq: int = int(opts.get("ppq", 960))
	var numerator: int = int(opts.get("numerator", 4))
	var denominator: int = int(opts.get("denominator", 4))
	var notes: Array[MidiNoteData] = ClipTextGrid.notes_of(clip)
	if notes.is_empty():
		return "# empty — write with: %s" % ADD_EXAMPLE
	notes.sort_custom(func(a, b): return a.start_tick < b.start_tick or (a.start_tick == b.start_tick and a.note > b.note))
	var width := 1
	for n in notes:
		width = maxi(width, str(n.id).length())
	var lines: PackedStringArray = []
	for n in notes:
		var nid := "n" + str(n.id).pad_zeros(width)
		var at := ClipTextTime.format_bbt(n.start_tick, ppq, numerator, denominator)
		var pitch := ClipTextKey.pitch_name(n.note, opts.get("key", {}))
		var dur := ClipTextTime.format_duration(n.duration_ticks, ppq)
		lines.append("%s  %s  %s  %s  v%d" % [nid, at, pitch, dur, n.velocity])
	return "\n".join(lines)


## True when `text` looks like ops (`add`/`del`/`move`/`vel`/`len`) rather than a full list.
static func looks_like_ops(text: String) -> bool:
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("clip "):
			continue
		var verb := _first_token(line).to_lower()
		if verb in ["add", "del", "move", "vel", "len"]:
			return true
		if verb.begins_with("n") and verb.substr(1).is_valid_int():
			return false
	return false


## True when the body is a rewritten `n01 ...` list.
static func looks_like_list(text: String) -> bool:
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("clip "):
			continue
		var verb := _first_token(line).to_lower()
		return verb.begins_with("n") and verb.substr(1).is_valid_int()
	return false


## Apply ops, or treat a full list as adds when the clip is empty.
static func apply(clip: Object, project: Object, text: String, opts: Dictionary) -> Dictionary:
	if looks_like_list(text):
		if clip.midi_notes.is_empty():
			return _apply_list_as_adds(clip, project, text, opts)
		return {
			"error": "Event lists are not rewritten whole. Use add / del / move / vel / len (ids from the last read_clip)."
		}
	return _apply_ops(clip, project, text, opts)


static func _apply_ops(clip: Object, project: Object, text: String, opts: Dictionary) -> Dictionary:
	var ppq: int = int(opts.get("ppq", 960))
	var numerator: int = int(opts.get("numerator", 4))
	var denominator: int = int(opts.get("denominator", 4))
	var key: Dictionary = opts.get("key", {})
	var changes: Array = []
	var lines := text.split("\n")
	for i in range(lines.size()):
		var line := lines[i].strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("clip "):
			continue
		var err := _apply_one(clip, project, line, ppq, numerator, denominator, key, changes)
		if not err.is_empty():
			return {"error": "Line %d `%s`: %s" % [i + 1, line, err], "changes": changes}
	return {"changes": changes}


static func _apply_list_as_adds(clip: Object, project: Object, text: String, opts: Dictionary) -> Dictionary:
	var ppq: int = int(opts.get("ppq", 960))
	var numerator: int = int(opts.get("numerator", 4))
	var denominator: int = int(opts.get("denominator", 4))
	var key: Dictionary = opts.get("key", {})
	var changes: Array = []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("clip "):
			continue
		var toks := _tokens(line)
		if toks.size() < 5:
			return {"error": "Event line needs id start pitch duration velocity: %s" % line}
		# n01  5.1.000  C2  1/4  v104
		var add_line := "add %s %s %s %s" % [toks[1], toks[2], toks[3], toks[4]]
		var err := _apply_one(clip, project, add_line, ppq, numerator, denominator, key, changes)
		if not err.is_empty():
			return {"error": err, "changes": changes}
	return {"changes": changes}


static func _apply_one(
	clip: Object,
	project: Object,
	line: String,
	ppq: int,
	numerator: int,
	denominator: int,
	key: Dictionary,
	changes: Array
) -> String:
	var toks := _tokens(_join_chord_commas(line))
	if toks.is_empty():
		return ""
	var verb := toks[0].to_lower()
	match verb:
		"add":
			return _op_add(clip, project, toks, ppq, numerator, denominator, key, changes)
		"del":
			return _op_del(clip, toks, changes)
		"move":
			return _op_move(clip, toks, ppq, numerator, denominator, changes)
		"vel":
			return _op_vel(clip, toks, changes)
		"len":
			return _op_len(clip, toks, ppq, changes)
		_:
			return "Unknown event op '%s' (use add/del/move/vel/len)" % toks[0]


static func _op_add(
	clip: Object,
	project: Object,
	toks: PackedStringArray,
	ppq: int,
	numerator: int,
	denominator: int,
	key: Dictionary,
	changes: Array
) -> String:
	# add  6.3.000  Ab2  1/8  v76   /   add  1.1.000  C3,E3,G3  1/2  v90
	if toks.size() < 4 or toks.size() > 5:
		return "expected %s, e.g. %s" % [ADD_SYNTAX, ADD_EXAMPLE]
	var start := ClipTextTime.parse_bbt(toks[1], ppq, numerator, denominator)
	if start < 0 or not _looks_like_bbt(toks[1]):
		return "bad start '%s' (bar.beat.tick, e.g. 3.2.240). Syntax: %s" % [toks[1], ADD_SYNTAX]
	var pitches: Array[int] = []
	for name in toks[2].split(",", false):
		var pitch := ClipTextKey.parse_pitch(name, key)
		if pitch < 0:
			return "bad pitch '%s' (e.g. C3, F#2, Bb4; middle C = C3). Syntax: %s" % [name, ADD_SYNTAX]
		pitches.append(pitch)
	if pitches.is_empty():
		return "bad pitch '%s'. Syntax: %s" % [toks[2], ADD_SYNTAX]
	var dur := ClipTextTime.parse_duration(toks[3], ppq, denominator)
	if dur < 0:
		return "bad duration '%s' (use %s). Syntax: %s" % [toks[3], ClipTextTime.DURATION_FORMS, ADD_SYNTAX]
	var vel := 100
	if toks.size() == 5:
		vel = _parse_vel(toks[4])
		if vel < 0:
			return "bad velocity '%s' (v1–v127)" % toks[4]
	for pitch in pitches:
		var note := ClipTextGrid._add_note(clip, project, pitch, start, dur, ClipTextKey.velocity_to_tier(vel))
		if note == null:
			return "could not add %s at %s (overlaps a note of the same pitch)" % [Midi.midi_to_note_name(pitch), toks[1]]
		# Preserve exact velocity (not the tier curve) for event-list writes.
		if note.velocity != vel:
			note.velocity = clampi(vel, 1, 127)
			ClipTextGrid._touch_note(clip, note)
		changes.append("add n%d %s" % [note.id, Midi.midi_to_note_name(pitch)])
	return ""


static func _op_del(clip: Object, toks: PackedStringArray, changes: Array) -> String:
	if toks.size() < 2:
		return "del needs a note id (n12)"
	var note := _find(clip, toks[1])
	if note == null:
		return "No note %s" % toks[1]
	ClipTextGrid._remove_note(clip, note)
	changes.append("del %s" % toks[1])
	return ""


static func _op_move(
	clip: Object,
	toks: PackedStringArray,
	ppq: int,
	numerator: int,
	denominator: int,
	changes: Array
) -> String:
	if toks.size() < 3:
		return "move needs: move n12 +1/16  or  move n12 2.1.000"
	var note := _find(clip, toks[1])
	if note == null:
		return "No note %s" % toks[1]
	var dest := toks[2]
	if dest.begins_with("+") or dest.begins_with("-"):
		if ClipTextTime.parse_duration(dest.substr(1), ppq) < 0:
			return "bad move delta '%s' (e.g. +1/16, -2b, +240t)" % dest
		note.start_tick = maxi(0, note.start_tick + ClipTextTime.parse_signed_delta(dest, ppq))
	else:
		var abs_t := ClipTextTime.parse_bbt(dest, ppq, numerator, denominator)
		if abs_t < 0:
			return "Bad move target: %s" % dest
		note.start_tick = abs_t
	ClipTextGrid._touch_note(clip, note)
	changes.append("move %s" % toks[1])
	return ""


static func _op_vel(clip: Object, toks: PackedStringArray, changes: Array) -> String:
	if toks.size() < 3:
		return "vel needs: vel n12 88"
	var note := _find(clip, toks[1])
	if note == null:
		return "No note %s" % toks[1]
	var vel := _parse_vel(toks[2])
	if vel < 0:
		return "Bad velocity: %s" % toks[2]
	note.velocity = clampi(vel, 1, 127)
	ClipTextGrid._touch_note(clip, note)
	changes.append("vel %s %d" % [toks[1], note.velocity])
	return ""


static func _op_len(clip: Object, toks: PackedStringArray, ppq: int, changes: Array) -> String:
	if toks.size() < 3:
		return "len needs: len n12 1/4"
	var note := _find(clip, toks[1])
	if note == null:
		return "No note %s" % toks[1]
	var dur := ClipTextTime.parse_duration(toks[2], ppq)
	if dur < 0:
		return "bad duration '%s' (use %s)" % [toks[2], ClipTextTime.DURATION_FORMS]
	note.duration_ticks = dur
	ClipTextGrid._touch_note(clip, note)
	changes.append("len %s %s" % [toks[1], toks[2]])
	return ""


static func _find(clip: Object, token: String) -> MidiNoteData:
	var id := _parse_id(token)
	if id < 0:
		return null
	for n in ClipTextGrid.notes_of(clip):
		if n.id == id:
			return n
	return null


static func _parse_id(token: String) -> int:
	var s := token.strip_edges().to_lower()
	if s.begins_with("n"):
		s = s.substr(1)
	if not s.is_valid_int():
		return -1
	return s.to_int()


static func _parse_vel(token: String) -> int:
	var s := token.strip_edges().to_lower()
	if s.begins_with("v"):
		s = s.substr(1)
	if not s.is_valid_int():
		return -1
	return clampi(s.to_int(), 1, 127)


## `C3, E3 ,G3` → `C3,E3,G3` so a chord stays one token.
static func _join_chord_commas(line: String) -> String:
	var re := RegEx.create_from_string("\\s*,\\s*")
	return re.sub(line, ",", true)


## `1.1.000` / `2.3` / `5` — not a duration like `1/4` that parse_bbt would half-read.
static func _looks_like_bbt(token: String) -> bool:
	var re := RegEx.create_from_string("^\\d+([.:]\\d+){0,2}$")
	return re.search(token) != null


static func _first_token(line: String) -> String:
	var toks := _tokens(line)
	return toks[0] if not toks.is_empty() else ""


static func _tokens(line: String) -> PackedStringArray:
	return line.strip_edges().split(" ", false)
