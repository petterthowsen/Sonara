# test_harmony_generators.gd
# Spec 048 REQ-003/030/031/032/035 plus the non-functional performance bound: Harmonize, Insert
# Chords and Insert Bassline note generation, and timing of the tools on 2,000 notes.
#
# Run: godot --headless --path Godot -s tests/test_harmony_generators.gd -- --test
extends TestBase

const BAR := 3840


func suite_name() -> String:
	return "Harmony generators"


func run_tests() -> void:
	_test_harmonize()
	_test_harmonize_out_of_scale()
	_test_harmonize_duplicates()
	_test_harmonize_key_change()
	_test_chords_fill()
	_test_chords_key_change()
	_test_chords_options()
	_test_bassline()
	_test_performance()


func _note(pitch: int, start: int, dur: int = 960) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	return n


func _in(root: int, type_id: String) -> Callable:
	return func(_tick: int) -> MusicalScale: return MusicalScale.make(root, type_id)


func _pitches(notes: Array) -> Array:
	var out := []
	for n: MidiNoteData in notes:
		out.append(n.note)
	return out


## Pitches of the notes starting at `tick`, sorted.
func _at(notes: Array, tick: int) -> Array:
	var out := []
	for n: MidiNoteData in notes:
		if n.start_tick == tick:
			out.append(n.note)
	out.sort()
	return out


func _melody() -> Array[MidiNoteData]:
	return [_note(60, 0), _note(62, 960), _note(64, 1920)]


func _test_harmonize() -> void:
	var c_major := _in(0, "major")
	var third := HarmonyGenerators.harmonize(_melody(), [HarmonyGenerators.THIRD] as Array[int], c_major)
	_assert(_pitches(third) == [64, 65, 67], "C D E a 3rd above adds E F G")
	_assert(third[0].start_tick == 0 and third[1].start_tick == 960 and third[0].duration_ticks == 960,
			"copies keep start and length")
	var sixth_below := HarmonyGenerators.harmonize(_melody(), [-HarmonyGenerators.SIXTH] as Array[int], c_major)
	_assert(_pitches(sixth_below) == [52, 53, 55], "a 6th below adds E2 F2 G2")
	var both := HarmonyGenerators.harmonize(_melody(), [HarmonyGenerators.THIRD, -HarmonyGenerators.SIXTH] as Array[int], c_major)
	_assert(both.size() == 6 and _at(both, 0) == [52, 64], "two intervals at once add two copies per note")
	var octave := HarmonyGenerators.harmonize(_melody(), [HarmonyGenerators.OCTAVE] as Array[int], c_major)
	_assert(_pitches(octave) == [72, 74, 76], "an octave above in a seven-note scale is +12")
	var pent := HarmonyGenerators.harmonize([_note(60, 0)] as Array[MidiNoteData], [HarmonyGenerators.OCTAVE] as Array[int], _in(0, "major_pentatonic"))
	_assert(_pitches(pent) == [72], "an octave in a five-note scale is five steps, still +12")
	var loud := _melody()
	loud[0].velocity = 0.5
	var shifted := HarmonyGenerators.harmonize(loud, [HarmonyGenerators.THIRD] as Array[int], c_major, 0.25)
	_assert(is_equal_approx(shifted[0].velocity, 0.75), "the velocity offset is added")
	var clamped := HarmonyGenerators.harmonize(loud, [HarmonyGenerators.THIRD] as Array[int], c_major, 5.0)
	_assert(clamped[0].velocity == 1.0, "velocity clamps at 1")
	_assert(third[0].id == -1, "new notes carry no id")
	_assert(HarmonyGenerators.harmonize(_melody(), [2] as Array[int], _in(0, "none")).is_empty(), "no scale, no copies")
	_assert(HarmonyGenerators.harmonize(_melody(), [2] as Array[int], Callable()).is_empty(), "no scale callable, no copies")


func _test_harmonize_out_of_scale() -> void:
	var r := HarmonyGenerators.harmonize([_note(61, 0)] as Array[MidiNoteData], [HarmonyGenerators.THIRD] as Array[int], _in(0, "major"))
	_assert(_pitches(r) == [65], "C#3 a 3rd above in C Major is F3 (C3 + 2 steps = E3, +1 semitone)")


func _test_harmonize_duplicates() -> void:
	# E already sounds with the C: harmonizing C D E a 3rd above must not stack a second E or G.
	var melody: Array[MidiNoteData] = [_note(60, 0), _note(64, 0)]
	var r := HarmonyGenerators.harmonize(melody, [HarmonyGenerators.THIRD] as Array[int], _in(0, "major"))
	_assert(_pitches(r) == [67], "the E copy of C is skipped because E is already there; E gets a G")
	var existing: Array[MidiNoteData] = [_note(67, 0)]
	var r2 := HarmonyGenerators.harmonize(melody, [HarmonyGenerators.THIRD] as Array[int], _in(0, "major"), 0.0, existing)
	_assert(r2.is_empty(), "notes of the clip outside the selection count as existing too")
	var twice := HarmonyGenerators.harmonize([_note(60, 0)] as Array[MidiNoteData], [2, 2] as Array[int], _in(0, "major"))
	_assert(twice.size() == 1, "the same interval twice yields one copy")
	var lowest := HarmonyGenerators.harmonize([_note(0, 0)] as Array[MidiNoteData], [-2] as Array[int], _in(0, "major"))
	_assert(lowest.is_empty(), "a copy that lands on the original (saturated at the bottom) is skipped")


func _test_harmonize_key_change() -> void:
	var scale_at := func(tick: int) -> MusicalScale:
		return MusicalScale.make(7, "major") if tick >= BAR else MusicalScale.make(0, "major")
	var notes: Array[MidiNoteData] = [_note(66, 0), _note(66, BAR)]
	var r := HarmonyGenerators.harmonize(notes, [2] as Array[int], scale_at)
	_assert(_at(r, 0) == [70] and _at(r, BAR) == [69],
			"F#3 a 3rd above: A#3 in C Major (out of scale, offset kept), A3 in G Major (in scale): each note follows the key at its own start")


func _test_chords_fill() -> void:
	var opts := {"progression": "I V vi IV", "length_ticks": BAR, "range": Vector2i(48, 72)}
	var four := HarmonyGenerators.chords(opts, _in(0, "major"), 0, 4 * BAR)
	_assert(four.error == "" and four.notes.size() == 12, "4-bar range -> 4 triads")
	_assert(_at(four.notes, 0) == [48, 52, 55], "bar 1: C major")
	_assert(_at(four.notes, BAR) == [55, 59, 62], "bar 2: G major")
	_assert(_at(four.notes, 2 * BAR) == [57, 60, 64], "bar 3: A minor")
	_assert(_at(four.notes, 3 * BAR) == [53, 57, 60], "bar 4: F major")
	_assert(four.notes[0].duration_ticks == BAR, "each chord lasts the chord length")
	var six := HarmonyGenerators.chords(opts, _in(0, "major"), 0, 6 * BAR)
	_assert(_at(six.notes, 4 * BAR) == [48, 52, 55] and _at(six.notes, 5 * BAR) == [55, 59, 62],
			"a 6-bar range repeats the progression: I V vi IV I V")
	var cut := HarmonyGenerators.chords(opts, _in(0, "major"), 0, BAR + 1000)
	_assert(cut.notes[cut.notes.size() - 1].duration_ticks == 1000, "the last chord is cut at the range end")
	var counted := HarmonyGenerators.chords({"progression": "I IV", "length_ticks": 960, "count": 3}, _in(0, "major"), 2000)
	_assert(counted.notes.size() == 9 and _at(counted.notes, 2000) != [] and _at(counted.notes, 2000 + 2 * 960) != [],
			"without a range, Count chords start at the given tick")
	var bad := HarmonyGenerators.chords({"progression": "I X", "length_ticks": BAR}, _in(0, "major"), 0, BAR)
	_assert(bad.error != "" and bad.notes.is_empty(), "an unparsable progression yields an error and no notes")
	_assert(HarmonyGenerators.chords(opts, _in(0, "none"), 0, BAR).notes.is_empty(), "no scale, no chords")


func _test_chords_key_change() -> void:
	var scale_at := func(tick: int) -> MusicalScale:
		return MusicalScale.make(9, "natural_minor") if tick >= 2 * BAR else MusicalScale.make(0, "major")
	var r := HarmonyGenerators.chords({"progression": "I", "length_ticks": BAR}, scale_at, 0, 4 * BAR)
	var pcs := func(tick: int) -> Array:
		var out := []
		for p: int in _at(r.notes, tick):
			out.append(p % 12)
		out.sort()
		return out
	_assert(pcs.call(0) == [0, 4, 7] and pcs.call(BAR) == [0, 4, 7], "bars 1-2: C E G")
	_assert(pcs.call(2 * BAR) == [0, 4, 9] and pcs.call(3 * BAR) == [0, 4, 9], "bars 3-4: A C E")


func _test_chords_options() -> void:
	var c_major := _in(0, "major")
	var failures := 0
	for range in [Vector2i(48, 72), Vector2i(36, 60), Vector2i(60, 96)]:
		for voicing in [ChordTheory.Voicing.CLOSE, ChordTheory.Voicing.SPREAD]:
			for inversion in ["root", "smooth"]:
				var r := HarmonyGenerators.chords({"progression": "I V vi IV7 ii7", "length_ticks": 960, "range": range,
						"voicing": voicing, "inversion": inversion}, c_major, 0, 5 * 960)
				for n: MidiNoteData in r.notes:
					if n.note < range.x or n.note > range.y:
						failures += 1
	_assert(failures == 0, "every generated note is inside the range for all voicing/inversion combinations (%d outside)" % failures)

	var movement := func(inversion: String) -> float:
		var r := HarmonyGenerators.chords({"progression": "I IV V I", "length_ticks": BAR, "range": Vector2i(48, 72),
				"inversion": inversion}, c_major, 0, 4 * BAR)
		var chords := []
		for i in 4:
			chords.append(PackedInt32Array(_at(r.notes, i * BAR)))
		return ChordTheory.total_movement(chords)
	_assert(movement.call("smooth") < movement.call("root"), "Smooth moves less than Root position over I IV V I")
	var narrow := HarmonyGenerators.chords({"progression": "I", "length_ticks": BAR, "range": Vector2i(60, 63)}, c_major, 0, BAR)
	_assert(narrow.clamped, "a range too narrow for the chord is reported as clamped")
	var fits := HarmonyGenerators.chords({"progression": "I", "length_ticks": BAR}, c_major, 0, BAR)
	_assert(not fits.clamped, "a chord that fits is not reported as clamped")


func _chords_c_then_a() -> Array[MidiNoteData]:
	return [_note(60, 0, BAR), _note(64, 0, BAR), _note(67, 0, BAR),
			_note(69, BAR, BAR), _note(72, BAR, BAR), _note(76, BAR, BAR)]


func _test_bassline() -> void:
	var range := Vector2i(36, 48)
	var c_major := _in(0, "major")
	var s := HarmonyGenerators.bassline(_chords_c_then_a(), HarmonyGenerators.Pattern.SUSTAINED, range, 960, c_major)
	_assert(s.size() == 2 and s[0].note == 36 and s[0].start_tick == 0 and s[0].duration_ticks == BAR,
			"Sustained: C1 for one bar")
	_assert(s[1].note == 45 and s[1].start_tick == BAR and s[1].duration_ticks == BAR, "Sustained: A1 for one bar (last chord runs to its longest note)")
	var p := HarmonyGenerators.bassline(_chords_c_then_a(), HarmonyGenerators.Pattern.PULSE, range, 960, c_major)
	_assert(p.size() == 8 and _pitches(p.slice(0, 4)) == [36, 36, 36, 36] and _pitches(p.slice(4)) == [45, 45, 45, 45],
			"Pulse: the root on every grid step")
	_assert(p[1].start_tick == 960 and p[1].duration_ticks == 960, "Pulse notes last one grid step")
	var rf := HarmonyGenerators.bassline(_chords_c_then_a(), HarmonyGenerators.Pattern.ROOT_FIFTH, range, 960, c_major)
	_assert(_pitches(rf.slice(0, 4)) == [36, 43, 36, 43], "Root-Fifth: C and G alternate")
	_assert(_pitches(rf.slice(4)) == [45, 40, 45, 40], "Root-Fifth: A and its fifth E, folded into the range")
	var uneven := HarmonyGenerators.bassline(_chords_c_then_a(), HarmonyGenerators.Pattern.PULSE, range, 1500, c_major)
	_assert(uneven[2].duration_ticks == BAR - 3000, "the last pulse of a chord is cut at the chord end")
	var lone: Array[MidiNoteData] = [_note(60, 0), _note(62, 960)]
	_assert(HarmonyGenerators.bassline(lone, HarmonyGenerators.Pattern.SUSTAINED, range, 960).is_empty(), "single notes are not chords")
	var inverted: Array[MidiNoteData] = [_note(64, 0, BAR), _note(67, 0, BAR), _note(72, 0, BAR)]
	_assert(HarmonyGenerators.bassline(inverted, HarmonyGenerators.Pattern.SUSTAINED, range, 960)[0].note == 36,
			"the bass follows the chord's root, not its lowest note (E G C -> C)")
	var no_scale := HarmonyGenerators.bassline(_chords_c_then_a(), HarmonyGenerators.Pattern.ROOT_FIFTH, range, 960)
	_assert(_pitches(no_scale.slice(0, 4)) == [36, 43, 36, 43], "without a scale the fifth is seven semitones")


func _time(label: String, work: Callable) -> void:
	var start := Time.get_ticks_usec()
	work.call()
	var ms := (Time.get_ticks_usec() - start) / 1000.0
	_assert(ms < 100.0, "%s on 2000 notes took %.1f ms (< 100)" % [label, ms])


func _test_performance() -> void:
	var notes: Array[MidiNoteData] = []
	for i in 2000:
		# 500 chords of 4 notes, a chord every 480 ticks.
		notes.append(_note(48 + (i % 4) * 4 + (i / 4) % 5, (i / 4) * 480, 480))
	var scale_at := _in(0, "major")
	_time("harmonize (2 intervals)", func(): HarmonyGenerators.harmonize(notes, [2, -5] as Array[int], scale_at))
	_time("invert up", func(): NoteVoices.invert(notes.duplicate(), true))
	_time("select voices", func(): NoteVoices.select(notes, NoteVoices.TOP))
	_time("ranks", func(): NoteVoices.ranks(notes))
	_time("bassline", func(): HarmonyGenerators.bassline(notes, HarmonyGenerators.Pattern.ROOT_FIFTH, Vector2i(36, 48), 120, scale_at))
	var opts := {"progression": "I V vi IV7", "length_ticks": 480, "inversion": "smooth", "voicing": ChordTheory.Voicing.SPREAD}
	_time("2000 chord notes (Smooth, 500 chords)", func(): HarmonyGenerators.chords(opts, scale_at, 0, 500 * 480))
