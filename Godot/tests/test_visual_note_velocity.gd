# test_visual_note_velocity.gd
# Velocity is drawn as a bar over the bottom half of a note; the body colour no longer
# depends on it.
# Run: godot --headless --path Godot -s tests/test_visual_note_velocity.gd -- --test
extends TestBase


func suite_name() -> String:
	return "VisualNote velocity bar tests"


func run_tests() -> void:
	await _test_body_colour_ignores_velocity()
	await _test_bar_follows_velocity()
	await _test_selection_changes_body()


func _make_note(velocity: float) -> VisualNote:
	var vn: VisualNote = load("res://clip_editor/VisualNote.tscn").instantiate()
	root.add_child(vn)
	var nd := MidiNoteData.new()
	nd.velocity = velocity
	vn.bind_to_note(nd)
	vn.size = Vector2(100, 20)
	return vn


func _test_body_colour_ignores_velocity() -> void:
	var soft := _make_note(0.2)
	var loud := _make_note(1.0)
	await process_frame
	_assert(soft._applied_style.bg_color == loud._applied_style.bg_color,
		"note body colour is the same for soft and loud notes")
	soft.queue_free()
	loud.queue_free()


func _test_bar_follows_velocity() -> void:
	var vn := _make_note(0.25)
	await process_frame
	_assert(is_equal_approx(vn._bar_velocity, 0.25), "bar velocity is 0.25")
	vn.midi_note_data.velocity = 1.0
	vn._update_visual()
	_assert(is_equal_approx(vn._bar_velocity, 1.0), "bar follows a velocity edit")
	_assert(vn._bar_fill_color != vn._bar_track_color, "fill is distinguishable from the track")
	vn.queue_free()


func _test_selection_changes_body() -> void:
	var vn := _make_note(0.5)
	await process_frame
	var before := vn._applied_style.bg_color
	vn.set_selected(true)
	_assert(vn._applied_style.bg_color != before, "selecting brightens the body")
	vn.queue_free()
