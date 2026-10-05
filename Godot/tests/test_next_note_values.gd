# Run: godot --headless --path Godot -s tests/test_next_note_values.gd -- --test
# New notes start with the last touched note's velocity and release; the toolbar readout shows
# and edits that velocity (REQ-028).
extends TestBase

const Rig := preload("res://tests/value_lane_rig.gd")


func suite_name() -> String:
	return "Next note values"


func _near(a: float, b: float) -> bool:
	return absf(a - b) < 0.001


func _draw_note(rig, tick: int, pitch: int):
	var ne = rig.midi_editor.note_editor
	var x: float = ne.ticks_to_pixels(tick) + 2.0
	var y: float = rig.midi_editor.lane_layout.pitch_to_y(pitch) + 2.0
	var before: int = rig.clip.midi_notes.size()
	ne.place_note_at_position(Vector2(x, y))
	return rig.clip.midi_notes[rig.clip.midi_notes.size() - 1] if rig.clip.midi_notes.size() > before else null


func run_tests() -> void:
	root.get_node("Sonara").set_config("clip_editor/value_lanes", {})
	var rig = Rig.new(self)
	await rig.build([0, 960], [0.3, 0.7], [0.8, 0.1])
	var nv = rig.midi_editor.next_note_values
	_assert(_near(nv.velocity, 100.0 / 127.0) and _near(nv.release, 0.5), "defaults are 100/127 and 0.5")

	# Select a note on its own: it is the last touched note.
	rig.select([0])
	_assert(_near(nv.velocity, 0.3) and _near(nv.release, 0.8), "touching a note copies its values")
	var drawn = _draw_note(rig, 3840, 70)
	_assert(drawn != null and _near(drawn.velocity, 0.3) and _near(drawn.release, 0.8), "a drawn note takes 0.3 / 0.8")

	# Editing in a lane touches the note too.
	rig.midi_editor.note_editor.selection_manager.clear_selection()
	var a = rig.area()
	a.apply_values([rig.note(1)] as Array[MidiNoteData], [0.7])
	_assert(_near(nv.velocity, 0.7) and _near(nv.release, 0.1), "a lane edit makes that note the last touched")
	drawn = _draw_note(rig, 4800, 72)
	_assert(drawn != null and _near(drawn.velocity, 0.7) and _near(drawn.release, 0.1), "the next drawn note takes 0.7 / 0.1")

	# The toolbar readout shows it and edits it without changing any note.
	var spin: SpinBox = rig.editor.next_value_spin
	_assert(is_equal_approx(spin.value, roundf(0.7 * 127.0)), "the readout shows the next velocity (%s)" % spin.value)
	var note_before: float = rig.note(0).velocity
	spin.value = 40
	_assert(_near(nv.velocity, 40.0 / 127.0), "changing the readout changes the next velocity")
	_assert(_near(rig.note(0).velocity, note_before), "and no existing note")
	drawn = _draw_note(rig, 5760, 74)
	_assert(drawn != null and _near(drawn.velocity, 40.0 / 127.0), "the next drawn note uses it")
	await rig.cleanup()
