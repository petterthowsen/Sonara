# test_note_voices.gd
# Spec 048 REQ-020/021: voice ranks, Select Voices and chord inversion (pure NoteVoices math).
#
# Run: godot --headless --path Godot -s tests/test_note_voices.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Note voices"


func run_tests() -> void:
	_test_ranks()
	_test_select()
	_test_invert_sequence()
	_test_up_then_down_restores()
	_test_single_notes_untouched()
	_test_range_edge()
	_test_equal_pitches()


func _note(pitch: int, start: int, dur: int = 960) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	return n


## REQ-020's two chords: C3-E3-G3 at tick 0 and D3-F3-A3-C4 at tick 960 (fed out of pitch order).
func _two_chords() -> Array[MidiNoteData]:
	return [_note(67, 0), _note(60, 0), _note(64, 0),
			_note(72, 960), _note(62, 960), _note(69, 960), _note(65, 960)]


func _pitches(notes: Array[MidiNoteData]) -> Array:
	var out := []
	for n in notes:
		out.append(n.note)
	out.sort()
	return out


func _test_ranks() -> void:
	var notes := _two_chords()
	var r := NoteVoices.ranks(notes)
	_assert(r[notes[0]] == Vector2i(1, 3), "G3 is voice 1 and 3rd from the bottom of its chord")
	_assert(r[notes[1]] == Vector2i(3, 1), "C3 is the bottom of its chord")
	_assert(r[notes[3]] == Vector2i(1, 4), "C4 tops the four-note chord")
	var lone: Array[MidiNoteData] = [_note(60, 0)]
	_assert(NoteVoices.ranks(lone)[lone[0]] == Vector2i(1, 1), "a one-note chord is both voice 1 and bottom")


func _test_select() -> void:
	var notes := _two_chords()
	_assert(_pitches(NoteVoices.select(notes, NoteVoices.TOP)) == [67, 72], "Top selects G3 and C4")
	_assert(_pitches(NoteVoices.select(notes, NoteVoices.BOTTOM)) == [60, 62], "Bottom selects C3 and D3")
	_assert(_pitches(NoteVoices.select(notes, 2)) == [64, 69], "Voice 2 selects E3 and A3")
	_assert(_pitches(NoteVoices.select(notes, 4)) == [62], "Voice 4 selects only D3")
	_assert(NoteVoices.select(notes, 5).is_empty(), "Voice 5 selects nothing")
	var near: Array[MidiNoteData] = [_note(60, 0), _note(64, 50), _note(67, 61)]
	_assert(NoteVoices.select(near, NoteVoices.BOTTOM).size() == 2,
			"starts within the strum tolerance of the first note join the chord; a later start does not")


func _test_invert_sequence() -> void:
	var chord: Array[MidiNoteData] = [_note(60, 0), _note(64, 0), _note(67, 0)]
	_assert(NoteVoices.invert(chord, true) == 1, "Up moves one note")
	_assert(_pitches(chord) == [64, 67, 72], "C3 E3 G3 -> Up -> E3 G3 C4")
	NoteVoices.invert(chord, true)
	_assert(_pitches(chord) == [67, 72, 76], "-> Up -> G3 C4 E4")
	NoteVoices.invert(chord, false)
	_assert(_pitches(chord) == [64, 67, 72], "-> Down -> E3 G3 C4")


func _test_up_then_down_restores() -> void:
	var chord: Array[MidiNoteData] = [_note(48, 0), _note(55, 0), _note(64, 0), _note(70, 0)]
	var before := _pitches(chord)
	NoteVoices.invert(chord, true)
	NoteVoices.invert(chord, false)
	_assert(_pitches(chord) == before, "Up then Down restores the chord")
	# A wide chord: the bottom note needs two octaves.
	var wide: Array[MidiNoteData] = [_note(36, 0), _note(72, 0)]
	NoteVoices.invert(wide, true)
	_assert(_pitches(wide) == [72, 84], "the lowest note climbs by octaves until strictly above the top")


func _test_single_notes_untouched() -> void:
	var lone: Array[MidiNoteData] = [_note(60, 0), _note(62, 960)]
	_assert(NoteVoices.invert(lone, true) == 0 and NoteVoices.invert(lone, false) == 0,
			"one-note chords are left alone")
	_assert(_pitches(lone) == [60, 62], "single notes keep their pitch")


func _test_range_edge() -> void:
	var high: Array[MidiNoteData] = [_note(120, 0), _note(127, 0)]
	_assert(NoteVoices.invert(high, true) == 0 and _pitches(high) == [120, 127],
			"Up that would pass 127 leaves the chord unchanged")
	var low: Array[MidiNoteData] = [_note(0, 0), _note(5, 0)]
	_assert(NoteVoices.invert(low, false) == 0 and _pitches(low) == [0, 5],
			"Down that would pass 0 leaves the chord unchanged")
	var ok: Array[MidiNoteData] = [_note(115, 0), _note(120, 0)]
	_assert(NoteVoices.invert(ok, true) == 1 and _pitches(ok) == [120, 127], "Up landing on exactly 127 works")


func _test_equal_pitches() -> void:
	var twins: Array[MidiNoteData] = [_note(60, 0), _note(60, 0)]
	NoteVoices.invert(twins, true)
	_assert(_pitches(twins) == [60, 72], "equal pitches: the moved note ends strictly above")
