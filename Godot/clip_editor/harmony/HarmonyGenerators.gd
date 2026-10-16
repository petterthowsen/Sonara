## Note generators for the harmony tools (spec 048): Harmonize, Insert Chords and Insert Bassline.
## Pure static functions that return NEW MidiNoteData (id -1, not in any clip); the caller adds
## them to the owning clip. Ticks are clip ticks. `scale_at` is a Callable(clip_tick: int) ->
## MusicalScale supplied by the caller, which maps clip ticks to song ticks (REQ-003), so every
## generated note follows the key in effect at its own start tick. An unset Callable, or a
## "no scale" result, means no scale.
class_name HarmonyGenerators extends RefCounted

## Harmonize interval step counts (scale steps; a 3rd is two steps up). Negative is below.
const THIRD := 2
const FOURTH := 3
const FIFTH := 4
const SIXTH := 5
## An octave is 7 steps in a seven-note scale, otherwise as many steps as the scale has notes.
## It is passed as +/-OCTAVE so the right count is looked up per note.
const OCTAVE := 1000

enum Pattern { SUSTAINED, PULSE, ROOT_FIFTH }


static func _scale_for(scale_at: Callable, tick: int) -> MusicalScale:
	if scale_at.is_valid():
		var s = scale_at.call(tick)
		if s is MusicalScale:
			return s
	return MusicalScale.make(0, MusicalScale.NONE_ID)


# --- Harmonize (REQ-030, REQ-031) -------------------------------------------------------------

## One copy of every note in `notes` per entry of `steps` (signed scale-step counts, see THIRD ..
## OCTAVE): `NoteTransforms.step_in_scale` from the scale at the note's start, so an out-of-scale
## note keeps its chromatic offset. A copy keeps start, length and release, and gets the velocity
## plus `velocity_offset` (normalized, clamped). A copy is skipped when a note with the same start
## and pitch exists in `notes` or `existing`, or was already generated. With no scale at a note
## it gets no copies. `existing` is for notes of the clip that aren't in `notes`.
static func harmonize(notes: Array[MidiNoteData], steps: Array[int], scale_at: Callable,
		velocity_offset: float = 0.0, existing: Array[MidiNoteData] = []) -> Array[MidiNoteData]:
	var out: Array[MidiNoteData] = []
	var taken := {}
	for n in notes:
		taken[Vector2i(n.start_tick, n.note)] = true
	for n in existing:
		taken[Vector2i(n.start_tick, n.note)] = true
	var pcs_cache := {}
	for n in notes:
		var scale := _scale_for(scale_at, n.start_tick)
		if scale.is_none():
			continue
		var key := "%d:%s" % [scale.root, scale.type_id]
		if not pcs_cache.has(key):
			pcs_cache[key] = [scale.pitch_classes(), MusicalScale.intervals_for(scale.type_id).size()]
		var pcs: PackedInt32Array = pcs_cache[key][0]
		var size: int = pcs_cache[key][1]
		for s in steps:
			var count := s
			if absi(s) == OCTAVE:
				count = size if s > 0 else -size
			var pitch := NoteTransforms.step_in_scale(n.note, count, pcs)
			var taken_key := Vector2i(n.start_tick, pitch)
			if taken.has(taken_key):
				continue
			taken[taken_key] = true
			var copy := n.duplicate_note()
			copy.note = pitch
			copy.velocity = clampf(n.velocity + velocity_offset, MidiNoteData.MIN_VELOCITY, 1.0)
			out.append(copy)
	return out


# --- Insert Chords (REQ-032..034) -------------------------------------------------------------

## Build a chord progression. `opts`:
##   progression: String, Roman numerals (ChordTheory.parse_progression)   [required]
##   length_ticks: int, the length of each chord                            [required]
##   range: Vector2i(lo, hi), the note range (default C2..C4 = 48..72)
##   voicing: ChordTheory.Voicing (default CLOSE)
##   inversion: "root" (default) or "smooth"
##   count: int, number of chords when `end_tick` < 0 (default 4)
##   velocity: float, normalized (default MidiNoteData.DEFAULT_VELOCITY)
## With `end_tick` >= 0 the chords fill [start_tick, end_tick): ceil(span / length) chords and the
## last is cut at `end_tick`. The progression repeats as needed. A chord built where there is no
## scale is skipped. Returns `{notes: Array[MidiNoteData], clamped: bool, error: String}`;
## `clamped` is true when any note had to be moved by octaves into the range.
static func chords(opts: Dictionary, scale_at: Callable, start_tick: int, end_tick: int = -1) -> Dictionary:
	var result := {"notes": [] as Array[MidiNoteData], "clamped": false, "error": ""}
	var parsed := ChordTheory.parse_progression(str(opts.get("progression", "")))
	if parsed.error != "":
		result.error = parsed.error
		return result
	var steps: Array = parsed.steps
	var length := maxi(1, int(opts.get("length_ticks", 3840)))
	var range: Vector2i = opts.get("range", Vector2i(48, 72))
	var voicing: ChordTheory.Voicing = opts.get("voicing", ChordTheory.Voicing.CLOSE)
	var smooth := str(opts.get("inversion", "root")) == "smooth"
	var velocity := float(opts.get("velocity", MidiNoteData.DEFAULT_VELOCITY))
	var total := int(opts.get("count", 4))
	if end_tick >= 0:
		total = ceili(float(end_tick - start_tick) / float(length))
	var notes: Array[MidiNoteData] = result.notes
	var prev := PackedInt32Array()
	for i in maxi(0, total):
		var tick := start_tick + i * length
		var scale := _scale_for(scale_at, tick)
		if scale.is_none():
			continue
		var step: Dictionary = steps[i % steps.size()]
		var tones := ChordTheory.chord_tones(scale, step.degree, step.seventh)
		var voiced: Dictionary
		if smooth:
			voiced = ChordTheory.smooth_next_ex(prev, tones, range, voicing)
		else:
			voiced = ChordTheory.voice_ex(tones, 0, range, voicing)
		prev = voiced.pitches
		result.clamped = result.clamped or voiced.clamped
		var duration := length
		if end_tick >= 0:
			duration = mini(length, end_tick - tick)
		for pitch in voiced.pitches:
			var n := MidiNoteData.new()
			n.note = pitch
			n.start_tick = tick
			n.duration_ticks = duration
			n.velocity = velocity
			notes.append(n)
	return result


# --- Insert Bassline (REQ-035, REQ-036) -------------------------------------------------------

## Bass notes under every chord (2+ notes) of `notes`. A chord runs from its start to the next
## chord's start, or to its longest note when it is the last. The bass pitch is the chord's root
## (ChordTheory.detect_root) at the lowest octave inside `range` (Vector2i(lo, hi)). SUSTAINED is
## one note for the chord's length, PULSE repeats the root every `grid_ticks`, ROOT_FIFTH
## alternates root and fifth every `grid_ticks` (the fifth is four scale steps up when the root is
## in the scale at the chord's start, otherwise seven semitones; folded into the range).
static func bassline(notes: Array[MidiNoteData], pattern: Pattern, range: Vector2i, grid_ticks: int,
		scale_at: Callable = Callable()) -> Array[MidiNoteData]:
	var out: Array[MidiNoteData] = []
	var chord_groups: Array = []
	for group: Array in NoteTransforms.group_by_start(notes, NoteTransforms.STRUM_TOLERANCE_TICKS):
		if group.size() >= 2:
			chord_groups.append(group)
	var grid := maxi(1, grid_ticks)
	for gi in chord_groups.size():
		var group: Array = chord_groups[gi]
		var start: int = group[0].start_tick
		var end := start
		if gi + 1 < chord_groups.size():
			end = chord_groups[gi + 1][0].start_tick
		else:
			for n: MidiNoteData in group:
				end = maxi(end, n.start_tick + n.duration_ticks)
		if end <= start:
			continue
		var pitches := PackedInt32Array()
		var velocity := 0.0
		for n: MidiNoteData in group:
			pitches.append(n.note)
			velocity = maxf(velocity, n.velocity)
		var root_pc := ChordTheory.detect_root(pitches)
		var root := _fold_pc_into_range(root_pc, range)
		var fifth := root
		if pattern == Pattern.ROOT_FIFTH:
			var scale := _scale_for(scale_at, start)
			if not scale.is_none() and scale.contains(root):
				fifth = NoteTransforms.step_in_scale(root, 4, scale.pitch_classes())
			else:
				fifth = root + 7
			while fifth > range.y and fifth - 12 >= range.x:
				fifth -= 12
			while fifth < range.x and fifth + 12 <= range.y:
				fifth += 12
			fifth = clampi(fifth, range.x, range.y)
		if pattern == Pattern.SUSTAINED:
			out.append(_bass_note(root, start, end - start, velocity))
			continue
		var t := start
		var index := 0
		while t < end:
			var pitch := fifth if (pattern == Pattern.ROOT_FIFTH and index % 2 == 1) else root
			out.append(_bass_note(pitch, t, mini(grid, end - t), velocity))
			t += grid
			index += 1
	return out


## Lowest pitch in `range` with pitch class `pc`; when the range is too narrow to hold it, the
## nearest edge.
static func _fold_pc_into_range(pc: int, range: Vector2i) -> int:
	var pitch := range.x + posmod(pc - range.x, 12)
	return clampi(pitch, range.x, range.y)


static func _bass_note(pitch: int, start: int, duration: int, velocity: float) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = maxi(1, duration)
	n.velocity = clampf(velocity, MidiNoteData.MIN_VELOCITY, 1.0)
	return n
