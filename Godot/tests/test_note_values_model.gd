# Run: godot --headless --path Godot -s tests/test_note_values_model.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Note values: model"


func run_tests() -> void:
	_test_defaults()
	_test_clamping()
	_test_helpers()
	_test_midi_conversion()


func _test_defaults() -> void:
	var n := MidiNoteData.new()
	_assert(is_equal_approx(n.velocity, 100.0 / 127.0), "default velocity is 100/127")
	_assert(n.release == 0.5, "default release is 0.5")


func _test_clamping() -> void:
	var n := MidiNoteData.new()
	n.velocity = 0.0
	_assert(is_equal_approx(n.velocity, MidiNoteData.MIN_VELOCITY), "velocity 0 clamps up to 1/127")
	n.velocity = 1.5
	_assert(n.velocity == 1.0, "velocity clamps to 1")
	n.release = -1.0
	_assert(n.release == 0.0, "release clamps to 0")
	n.release = 4.0
	_assert(n.release == 1.0, "release clamps to 1")


func _test_helpers() -> void:
	var a := MidiNoteData.new()
	a.id = 9
	a.note = 64
	a.velocity = 0.3
	a.release = 0.8
	a.start_tick = 120
	a.duration_ticks = 240
	var b := a.duplicate_note()
	_assert(b.id == -1, "duplicate_note clears the id")
	_assert(MidiNoteData.values_equal(a.values(), b.values()), "duplicate has equal values")
	_assert(b.velocity == 0.3 and b.release == 0.8 and b.note == 64 and b.start_tick == 120 and b.duration_ticks == 240, "all value fields copied")
	var c := MidiNoteData.new()
	c.id = 4
	c.copy_values_from(a)
	_assert(c.id == 4 and c.release == 0.8, "copy_values_from keeps the target's id")
	b.release = 0.1
	_assert(not MidiNoteData.values_equal(a.values(), b.values()), "values_equal sees a release change")
	var snap := a.values()
	a.velocity = 0.9
	a.apply_values(snap)
	_assert(a.velocity == 0.3, "apply_values restores a snapshot")


func _test_midi_conversion() -> void:
	_assert(MidiNoteData.to_midi_velocity(MidiNoteData.from_midi_velocity(100)) == 100, "100 round-trips")
	for v in range(1, 128):
		if MidiNoteData.to_midi_velocity(MidiNoteData.from_midi_velocity(v)) != v:
			_assert(false, "7-bit value %d round-trips" % v)
			return
	_assert(MidiNoteData.from_midi_velocity(127) == 1.0, "127 is 1.0")
	_assert(MidiNoteData.to_midi_velocity(0.0) == 1, "to_midi_velocity never returns 0")
