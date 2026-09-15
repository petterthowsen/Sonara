# ClipTextGrid.gd
# Drum and pitched ASCII grids: serialize, parse, and diff-apply.
class_name ClipTextGrid extends RefCounted


const MAX_STEPS_PER_LINE := 32


## Typed notes from a clip-like object.
static func notes_of(clip: Object) -> Array[MidiNoteData]:
	var out: Array[MidiNoteData] = []
	if clip == null:
		return out
	for n in clip.midi_notes:
		if n is MidiNoteData:
			out.append(n)
	return out


## True when every note is close enough to the grid for a safe grid write.
static func is_grid_eligible(clip: Object, step_ticks: int) -> bool:
	var notes := notes_of(clip)
	if notes.is_empty():
		return true
	var slop := maxi(1, step_ticks / 8)
	var by_pitch: Dictionary = {}
	for n in notes:
		if absi(ClipTextTime.step_offset(n.start_tick, step_ticks)) >= slop:
			return false
		var arr: Array = by_pitch.get(n.note, [])
		arr.append(n)
		by_pitch[n.note] = arr
	for pitch in by_pitch:
		var lane: Array = by_pitch[pitch]
		lane.sort_custom(func(a, b): return a.start_tick < b.start_tick)
		for i in range(lane.size() - 1):
			if lane[i].get_end_tick() > lane[i + 1].start_tick:
				return false
	return true


## Pitch span in semitones (0 if empty).
static func pitch_span(clip: Object) -> int:
	var notes := notes_of(clip)
	if notes.is_empty():
		return 0
	var lo := 127
	var hi := 0
	for n in notes:
		lo = mini(lo, n.note)
		hi = maxi(hi, n.note)
	return hi - lo


## Render a drum or pitched grid (no header).
static func serialize(clip: Object, opts: Dictionary) -> String:
	var ppq: int = int(opts.get("ppq", 960))
	var numerator: int = int(opts.get("numerator", 4))
	var denominator: int = int(opts.get("denominator", 4))
	var res_denom: int = int(opts.get("res_denom", 16))
	var bars: int = int(opts.get("bars", 1))
	var drums: bool = bool(opts.get("drums", false))
	var key: Dictionary = opts.get("key", {})
	var drum_names: Dictionary = opts.get("drum_names", {})
	var step_ticks := ClipTextTime.ticks_per_step(ppq, res_denom)
	var steps_beat := ClipTextTime.steps_per_beat(ppq, res_denom, denominator)
	@warning_ignore("integer_division")
	var steps := maxi(steps_beat, bars * ClipTextTime.ticks_per_bar(ppq, numerator, denominator) / ClipTextTime.ticks_per_step(ppq, res_denom))
	var lanes: Array[int] = _lane_pitches(clip, drums, drum_names)
	var cells: Dictionary = _cells_from_clip(clip, lanes, steps, step_ticks)
	return _render_blocks(lanes, cells, steps, steps_beat, maxi(1, numerator), drums, key, drum_names)


## Parse grid body into `{lanes: {pitch: PackedStringArray}, error}`.
static func parse(text: String, opts: Dictionary) -> Dictionary:
	var ppq: int = int(opts.get("ppq", 960))
	var numerator: int = int(opts.get("numerator", 4))
	var denominator: int = int(opts.get("denominator", 4))
	var res_denom: int = int(opts.get("res_denom", 16))
	var bars: int = int(opts.get("bars", 1))
	var drums: bool = bool(opts.get("drums", false))
	var key: Dictionary = opts.get("key", {})
	var drum_names: Dictionary = opts.get("drum_names", {})
	var steps_beat := ClipTextTime.steps_per_beat(ppq, res_denom, denominator)
	@warning_ignore("integer_division")
	var expected := maxi(steps_beat, bars * ClipTextTime.ticks_per_bar(ppq, numerator, denominator) / ClipTextTime.ticks_per_step(ppq, res_denom))
	var inv_drums := _invert_drum_names(drum_names)
	var hint_oct := 3
	var by_pitch: Dictionary = {}
	var order: Array[int] = []
	var block_offset := 0
	var saw_header := false
	for raw in text.split("\n"):
		var line := raw.rstrip("\r")
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#") or trimmed.begins_with("clip "):
			continue
		if _is_beat_header(trimmed):
			if saw_header:
				block_offset += _header_step_count(trimmed)
			saw_header = true
			continue
		if not trimmed.contains("|"):
			continue
		var parsed := _parse_lane_line(line, drums, key, hint_oct, inv_drums)
		if parsed.has("error"):
			return parsed
		if parsed.is_empty():
			return {"error": "Could not parse grid lane: %s" % trimmed}
		var pitch: int = parsed.pitch
		if pitch < 0:
			if order.is_empty():
				return {"error": "Grid lane needs a name (KICK, C1, …). Example: KICK |9 . . .|9 . . .|9 . . .|9 . . .|"}
			pitch = order[order.size() - 1]
		hint_oct = Midi.get_octave(pitch)
		var cells: PackedStringArray = parsed.cells
		if not by_pitch.has(pitch):
			by_pitch[pitch] = PackedStringArray()
			order.append(pitch)
		var acc: PackedStringArray = by_pitch[pitch]
		# Pad this lane up to the current block start if a prior block omitted it.
		while acc.size() < block_offset:
			acc.append(".")
		for c in cells:
			acc.append(c)
		by_pitch[pitch] = acc
	if by_pitch.is_empty():
		return {"error": "Grid has no lanes"}
	var max_len := 0
	for p in by_pitch:
		max_len = maxi(max_len, (by_pitch[p] as PackedStringArray).size())
	var target := maxi(expected, max_len)
	for p in by_pitch:
		var acc: PackedStringArray = by_pitch[p]
		while acc.size() < target:
			acc.append(".")
		by_pitch[p] = acc
	return {"lanes": by_pitch, "order": order, "steps": target}


## Diff incoming grid against the live clip and mutate notes. Returns change rows.
static func apply(clip: Object, project: Object, parsed: Dictionary, opts: Dictionary) -> Array:
	var ppq: int = int(opts.get("ppq", 960))
	var res_denom: int = int(opts.get("res_denom", 16))
	var step_ticks := ClipTextTime.ticks_per_step(ppq, res_denom)
	var incoming: Dictionary = parsed.get("lanes", {})
	var steps: int = int(parsed.get("steps", 0))
	if incoming.is_empty() or steps <= 0:
		return []
	var changes: Array = []
	var keep_ids: Dictionary = {}
	for pitch in incoming:
		var new_row: PackedStringArray = incoming[pitch]
		var intended := _notes_from_row(int(pitch), new_row, step_ticks)
		var existing := _on_grid_notes(clip, int(pitch), step_ticks)
		for spec in intended:
			var old: MidiNoteData = existing.get(spec.step, null)
			if old != null:
				keep_ids[old.id] = true
				var old_char := _tier_char(old.velocity)
				if spec.char != old_char:
					old.velocity = ClipTextKey.tier_to_velocity(spec.tier)
					_touch_note(clip, old)
					changes.append("vel %s → %d" % [ClipTextKey.pitch_name(old.note), old.velocity])
				var new_dur: int = spec.steps * step_ticks
				if old.duration_ticks != new_dur:
					old.duration_ticks = new_dur
					_touch_note(clip, old)
					changes.append("len %s" % ClipTextKey.pitch_name(old.note))
			else:
				var note := _add_note(clip, project, int(pitch), spec.start, spec.steps * step_ticks, spec.tier)
				if note:
					keep_ids[note.id] = true
					changes.append("add %s" % ClipTextKey.pitch_name(int(pitch)))
		for step in existing:
			var leftover: MidiNoteData = existing[step]
			if leftover and not keep_ids.has(leftover.id):
				_remove_note(clip, leftover)
				changes.append("del %s" % ClipTextKey.pitch_name(int(pitch)))
	return changes


static func _lane_pitches(clip: Object, drums: bool, drum_names: Dictionary) -> Array[int]:
	var used: Dictionary = {}
	for n in notes_of(clip):
		used[n.note] = true
	var lanes: Array[int] = []
	if drums:
		if drum_names.is_empty():
			for p in ClipTextKey.default_drum_pitches():
				if not lanes.has(p):
					lanes.append(p)
		else:
			var keys: Array = drum_names.keys()
			keys.sort()
			for p in keys:
				lanes.append(int(p))
		for p in used:
			if not lanes.has(int(p)):
				lanes.append(int(p))
	else:
		for p in used:
			lanes.append(int(p))
		lanes.sort()
		lanes.reverse()
	return lanes


static func _cells_from_clip(clip: Object, lanes: Array, steps: int, step_ticks: int) -> Dictionary:
	var cells := {}
	for p in lanes:
		var row := PackedStringArray()
		for _i in range(steps):
			row.append(".")
		cells[int(p)] = row
	if clip == null:
		return cells
	for n in notes_of(clip):
		var p: int = n.note
		if not cells.has(p):
			continue
		var step := ClipTextTime.quantize_step(n.start_tick, step_ticks)
		if step < 0 or step >= steps:
			continue
		var row: PackedStringArray = cells[p]
		row[step] = _tier_char(n.velocity)
		var hold := maxi(1, int(round(float(n.duration_ticks) / float(step_ticks)))) - 1
		for h in range(1, hold + 1):
			if step + h >= steps:
				break
			if row[step + h] == ".":
				row[step + h] = "-"
		cells[p] = row
	return cells


static func _render_blocks(
	lanes: Array[int],
	cells: Dictionary,
	steps: int,
	steps_beat: int,
	beats_per_bar: int,
	drums: bool,
	key: Dictionary,
	drum_names: Dictionary
) -> String:
	var steps_bar := maxi(1, steps_beat * beats_per_bar)
	var block := mini(steps, _block_steps(steps, steps_bar))
	var lines: PackedStringArray = []
	var label_w := _label_width(lanes, drums, key, drum_names)
	var offset := 0
	while offset < steps:
		var count := mini(block, steps - offset)
		if offset > 0:
			lines.append("")
		if steps > block:
			@warning_ignore("integer_division")
			var bar_i := offset / steps_bar + 1
			if offset % steps_bar == 0:
				lines.append("# bar %d" % bar_i)
			else:
				@warning_ignore("integer_division")
				lines.append("# bar %d, from beat %d" % [bar_i, (offset % steps_bar) / steps_beat + 1])
		lines.append(_header_row(label_w, count, steps_beat, offset % steps_bar, steps_bar))
		for p in lanes:
			var row: PackedStringArray = cells.get(p, PackedStringArray())
			var slice := PackedStringArray()
			for i in range(count):
				var idx := offset + i
				slice.append(row[idx] if idx < row.size() else ".")
			lines.append(_lane_row(p, slice, label_w, steps_beat, drums, key, drum_names))
		offset += count
	return "\n".join(lines)


## Steps per rendered block: one bar, split further only when a bar is wider than a line.
static func _block_steps(steps: int, steps_bar: int) -> int:
	if steps <= steps_bar and steps <= MAX_STEPS_PER_LINE:
		return steps
	return mini(steps_bar, MAX_STEPS_PER_LINE)


static func _label_width(lanes: Array[int], drums: bool, key: Dictionary, drum_names: Dictionary) -> int:
	var w := 8
	for p in lanes:
		w = maxi(w, _lane_label(p, drums, key, drum_names).length())
	return w


static func _lane_label(pitch: int, drums: bool, key: Dictionary, drum_names: Dictionary) -> String:
	if drums:
		return ClipTextKey.drum_label(pitch, drum_names)
	var name := ClipTextKey.pitch_name(pitch, key)
	if key.is_empty():
		return name
	var deg := ClipTextKey.degree_label(pitch, key)
	return "%s  %s" % [name, deg]


static func _header_row(label_w: int, steps: int, steps_beat: int, bar_offset: int = 0, steps_bar: int = 0) -> String:
	var left := " ".repeat(label_w)
	return left + " " + _cells_string(_beat_labels(steps, steps_beat, bar_offset, steps_bar), steps_beat)


static func _lane_row(
	pitch: int,
	cells: PackedStringArray,
	label_w: int,
	steps_beat: int,
	drums: bool,
	key: Dictionary,
	drum_names: Dictionary
) -> String:
	var label := _lane_label(pitch, drums, key, drum_names)
	while label.length() < label_w:
		label += " "
	return label + " " + _cells_string(cells, steps_beat)


static func _cells_string(cells: PackedStringArray, steps_beat: int) -> String:
	var out := "|"
	var beat := maxi(1, steps_beat)
	for i in range(cells.size()):
		if i > 0 and i % beat == 0:
			out += "|"
		out += cells[i]
		if i < cells.size() - 1 and (i + 1) % beat != 0:
			out += " "
	out += "|"
	return out


## Ruler cells; beat numbers restart every bar (`steps_bar`), starting `bar_offset` steps into it.
static func _beat_labels(steps: int, steps_beat: int, bar_offset: int = 0, steps_bar: int = 0) -> PackedStringArray:
	var beat := maxi(1, steps_beat)
	var cells := PackedStringArray()
	for j in range(steps):
		var i := j + bar_offset
		if steps_bar > 0:
			i %= steps_bar
		var pos := i % beat
		@warning_ignore("integer_division")
		var beat_n: int = i / beat + 1
		if pos == 0:
			cells.append(str(beat_n))
		elif beat == 4:
			cells.append(["e", "&", "a"][pos - 1])
		elif beat == 3:
			cells.append(["+", "a"][pos - 1])
		else:
			cells.append(".")
	return cells


static func _is_beat_header(line: String) -> bool:
	var t := line.strip_edges()
	if not t.begins_with("|") and not t.contains("|1"):
		# "        |1 e & a|..." after strip may start with |
		pass
	if not t.contains("|"):
		return false
	# Header cells are beat numbers / e & a, never 1-9 velocity + holds mixed with a name.
	var before := t.substr(0, t.find("|")).strip_edges()
	if not before.is_empty() and not before.is_valid_int():
		return false
	return t.contains("e") or t.contains("&") or t.contains("|1") or t.contains("|2")


static func _header_step_count(line: String) -> int:
	var n := 0
	for part in line.split("|"):
		for tok in part.strip_edges().split(" ", false):
			if not tok.is_empty():
				n += 1
	return n


static func _parse_lane_line(
	line: String,
	drums: bool,
	key: Dictionary,
	hint_oct: int,
	inv_drums: Dictionary
) -> Dictionary:
	var bar := line.find("|")
	if bar < 0:
		return {}
	var label := line.substr(0, bar).strip_edges()
	var grid := line.substr(bar)
	var pitch := -1
	if not label.is_empty():
		pitch = _parse_lane_label(label, drums, key, hint_oct, inv_drums)
		if pitch < 0:
			return {}
	var cells := PackedStringArray()
	var unknown := ""
	for ch in grid:
		if ch == "|" or ch == " " or ch == "\t":
			continue
		if (ch >= "1" and ch <= "9") or ch == "." or ch == "-":
			cells.append(ch)
		elif ch == "x" or ch == "X" or ch == "*":
			cells.append("7")
		elif _is_latin_letter(ch):
			unknown += ch
	if not unknown.is_empty():
		return {"error": "Unknown hit '%s' — use 1-9 or x (rest is .). Example: KICK |9 . . .|9 . . .|9 . . .|9 . . .|" % unknown[0]}
	if cells.is_empty():
		return {}
	return {"pitch": pitch, "cells": cells}


static func _parse_lane_label(
	label: String,
	drums: bool,
	key: Dictionary,
	hint_oct: int,
	inv_drums: Dictionary
) -> int:
	var bits := label.split(" ", false)
	if bits.is_empty():
		return -1
	if drums:
		var up := bits[0].to_upper()
		if inv_drums.has(up):
			return int(inv_drums[up])
		if up in ["SAMPLER", "SFZ", "AUDIO", "DEVICE", "PLUGIN"]:
			if not inv_drums.is_empty():
				var pitches: Array = inv_drums.values()
				pitches.sort()
				return int(pitches[0])
			return 36
	# Prefer an explicit pitch token; fall back to a degree.
	for tok in bits:
		var p := ClipTextKey.parse_pitch(tok, key, hint_oct)
		if p >= 0 and (tok.length() >= 2 or tok.is_valid_int()):
			# Degree-only tokens like "5" are valid ints but mean the degree when keyed.
			if tok.is_valid_int() and int(tok) <= 9 and not key.is_empty() and not drums:
				continue
			return p
	return ClipTextKey.parse_pitch(bits[0], key, hint_oct)


static func _is_latin_letter(ch: String) -> bool:
	if ch.is_empty():
		return false
	var c := ch.unicode_at(0)
	return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


static func _invert_drum_names(drum_names: Dictionary) -> Dictionary:
	var inv := {}
	for midi in drum_names:
		inv[str(drum_names[midi]).to_upper()] = int(midi)
	return inv


static func _notes_from_row(pitch: int, row: PackedStringArray, step_ticks: int) -> Array:
	var out: Array = []
	var i := 0
	while i < row.size():
		var ch := row[i]
		if ch >= "1" and ch <= "9":
			var hold := 1
			var j := i + 1
			while j < row.size() and row[j] == "-":
				hold += 1
				j += 1
			out.append({
				"pitch": pitch,
				"step": i,
				"start": i * step_ticks,
				"steps": hold,
				"tier": ch.to_int(),
				"char": ch,
			})
			i = j
		else:
			i += 1
	return out


static func _on_grid_notes(clip: Object, pitch: int, step_ticks: int) -> Dictionary:
	var out := {}
	if clip == null:
		return out
	var slop := maxi(1, step_ticks / 8)
	for n in notes_of(clip):
		if n.note != pitch:
			continue
		if absi(ClipTextTime.step_offset(n.start_tick, step_ticks)) >= slop:
			continue
		out[ClipTextTime.quantize_step(n.start_tick, step_ticks)] = n
	return out


static func _tier_char(velocity: int) -> String:
	return str(ClipTextKey.velocity_to_tier(velocity))


static func _add_note(clip: Object, project: Object, pitch: int, start: int, dur: int, tier: int) -> MidiNoteData:
	var nid := _next_id(clip, project)
	var vel := ClipTextKey.tier_to_velocity(tier)
	if clip.is_synced_to_engine():
		return clip.add_midi_note(nid, pitch, vel, start, dur)
	var n := MidiNoteData.new()
	n.id = nid
	n.note = pitch
	n.velocity = vel
	n.start_tick = start
	n.duration_ticks = dur
	clip.midi_notes.append(n)
	clip.extend_content_length(start + dur)
	return n


static func _remove_note(clip: Object, note: MidiNoteData) -> void:
	if clip.is_synced_to_engine():
		clip.remove_midi_note(note)
		return
	clip.midi_notes.erase(note)


static func _touch_note(clip: Object, note: MidiNoteData) -> void:
	if clip.is_synced_to_engine():
		clip.update_midi_note(note)
	else:
		clip.extend_content_length(note.start_tick + note.duration_ticks)


static func _next_id(clip: Object, project: Object) -> int:
	if project:
		return project.allocate_note_id()
	var mx := 0
	for n in notes_of(clip):
		mx = maxi(mx, n.id)
	return mx + 1
