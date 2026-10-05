# Run: godot --headless --path Godot -s tests/test_row_selection.gd -- --test
# Clicking a Drum View row header selects that row's notes, Shift adds, and Ctrl+click on a
# piano key selects that pitch without auditioning (REQ-027).
extends TestBase

const Rig := preload("res://tests/value_lane_rig.gd")


func suite_name() -> String:
	return "Row selection"


func run_tests() -> void:
	root.get_node("Sonara").set_config("clip_editor/value_lanes", {})
	await _test_drum_rows()
	await _test_piano_ctrl_click()


func _selected(rig) -> Array:
	var out: Array = []
	for nd in rig.midi_editor.selected_note_data():
		out.append(rig.clip.midi_notes.find(nd))
	out.sort()
	return out


func _click_row(rig, row: int, shift := false) -> void:
	var header = rig.midi_editor.drum_row_header
	var y: float = rig.midi_editor.lane_layout.row_to_y(row) + 2.0
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = Vector2(10, y)
	e.shift_pressed = shift
	header._gui_input(e)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = e.position
	header._gui_input(up)


func _test_drum_rows() -> void:
	var rig = Rig.new(self)
	# kick (36) x2, snare (38) x1, hat (42) x2
	await rig.build([0, 480, 960, 1440, 1920], [0.5, 0.5, 0.5, 0.5, 0.5], [], [36, 42, 38, 36, 42])
	rig.midi_editor.drum_view = true
	for _i in 3:
		await process_frame
	_assert(rig.midi_editor.lane_layout.is_folded(), "Drum View folds the rows")
	var hat_row: int = rig.midi_editor.lane_layout.row_of_pitch(42)
	_click_row(rig, hat_row)
	_assert(_selected(rig) == [1, 4], "clicking the hat row selects both hats: %s" % [_selected(rig)])
	var kick_row: int = rig.midi_editor.lane_layout.row_of_pitch(36)
	_click_row(rig, kick_row)
	_assert(_selected(rig) == [0, 3], "clicking another row replaces the selection: %s" % [_selected(rig)])
	_click_row(rig, hat_row, true)
	_assert(_selected(rig) == [0, 1, 3, 4], "Shift adds the row: %s" % [_selected(rig)])
	await rig.cleanup()


func _test_piano_ctrl_click() -> void:
	var rig = Rig.new(self)
	await rig.build([0, 480, 960], [0.5, 0.5, 0.5], [], [60, 62, 60])
	var piano = rig.midi_editor.v_piano
	var pressed := [0]
	piano.key_pressed.connect(func(_n, _v): pressed[0] += 1)
	var y: float = rig.midi_editor.lane_layout.pitch_to_y(60) + 4.0
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.ctrl_pressed = true
	e.position = Vector2(piano.size.x * 0.25, y)
	piano._gui_input(e)
	_assert(_selected(rig) == [0, 2], "Ctrl+click on C3 selects both C3 notes: %s" % [_selected(rig)])
	_assert(pressed[0] == 0, "and does not audition")
	var plain := e.duplicate()
	plain.ctrl_pressed = false
	piano._gui_input(plain)
	_assert(pressed[0] == 1, "a plain click still auditions")
	await rig.cleanup()
