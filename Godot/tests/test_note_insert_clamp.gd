# Run: godot --headless --path Godot -s tests/test_note_insert_clamp.gd -- --test
# A note drawn before another note on the same pitch is shortened to end where that note
# starts (issue #86); other pitches are unaffected.
extends TestBase

const Rig := preload("res://tests/value_lane_rig.gd")


func suite_name() -> String:
	return "Note insert clamp"


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
	await rig.build([960], [0.5], [], [60])
	var ne = rig.midi_editor.note_editor
	ne.last_note_length = 960
	var drawn = _draw_note(rig, 720, 60)
	_assert(drawn != null, "the note is still inserted")
	if drawn != null:
		_assert(drawn.start_tick + drawn.duration_ticks == 960, "it ends where the next note starts (%d)" % (drawn.start_tick + drawn.duration_ticks))
	_assert(rig.note(0).start_tick == 960 and rig.note(0).duration_ticks == 240, "the following note is untouched")
	var other = _draw_note(rig, 720, 62)
	_assert(other != null and other.duration_ticks == 960, "another pitch keeps the full length")
	await rig.cleanup()
