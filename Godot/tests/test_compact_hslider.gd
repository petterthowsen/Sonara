# CompactSlider (CompactHSlider spec 035): formatting, drag/fine-drag, reset, typed entry,
# step/log mapping, bidirectional fill and the modulation surface.
extends TestBase

var _changes: Array = []
var _resets := 0
var _mod_amounts: Array = []


func suite_name() -> String:
	return "CompactHSlider"


func run_tests() -> void:
	_test_formatting()
	_test_drag_and_fine()
	_test_ctrl_reset()
	await _test_double_click_editor()
	_test_step_snapping()
	_test_log_mapping()
	_test_bidirectional_fill()
	_test_minimum_size()
	_test_mod_surface()


func _make() -> CompactSlider:
	var s := CompactSlider.new()
	s.size = Vector2(80, 20)
	s.min_value = 0.0
	s.max_value = 1.0
	s.value = 0.5
	_changes.clear()
	_resets = 0
	_mod_amounts.clear()
	s.value_changed.connect(func(v): _changes.append(v))
	s.reset_requested.connect(func(): _resets += 1)
	s.mod_amount_changed.connect(func(a): _mod_amounts.append(a))
	return s


func _press(s: CompactSlider, double_click := false, ctrl := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.double_click = double_click
	e.ctrl_pressed = ctrl
	e.position = Vector2(40, 10)
	s._gui_input(e)


func _move(s: CompactSlider, dy: float, shift := false) -> void:
	var e := InputEventMouseMotion.new()
	e.position = Vector2(40, 10 + dy)
	e.relative = Vector2(0, dy)
	e.shift_pressed = shift
	s._gui_input(e)


func _release(s: CompactSlider) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = false
	s._gui_input(e)


func _test_formatting() -> void:
	var s := _make()
	s.min_value = 20.0
	s.max_value = 20000.0
	# A freq formatter overrides the fallback entirely.
	s.value_text_callback = func(v): return "%.1f kHz" % [v / 1000.0]
	s.value = 2400.0
	_assert(s.get_value_text() == "2.4 kHz", "freq formatter renders 2.4 kHz")
	# Fallback: "%g" plus the unit suffix.
	var t := _make()
	t.min_value = 20.0
	t.max_value = 20000.0
	t.value_format = "%g"
	t.unit = "Hz"
	t.value = 2400.0
	_assert(t.get_value_text() == "2400 Hz", "fallback %%g + unit renders '2400 Hz'")


func _test_drag_and_fine() -> void:
	var s := _make()
	_press(s)
	_move(s, 60)  # dragging down (positive y) lowers the value
	_release(s)
	_assert(is_equal_approx(s.value, 0.2), "drag of +60 px lowers the value by 0.3")
	_assert(_changes.back() == s.value, "value_changed fired with the new value")

	var f := _make()
	_press(f)
	_move(f, 60, true)  # the same distance with Shift moves much less
	_release(f)
	_assert(s.value < f.value, "Shift fine drag is slower than a normal drag")
	_assert(is_equal_approx(f.value, 0.5 - 60.0 * 0.005 * FineDrag.DEFAULT_SCALE),
		"fine drag applies the FineDrag scale")


func _test_ctrl_reset() -> void:
	var s := _make()
	s.default_value = 0.5
	s.value = 0.8
	_press(s, false, true)
	_assert(_resets == 1, "Ctrl+click emits reset_requested")
	_assert(is_equal_approx(s.value, 0.5), "Ctrl+click restores default_value")
	_release(s)


func _test_double_click_editor() -> void:
	var s := _make()
	s.min_value = 20.0
	s.max_value = 20000.0
	s.value_text_callback = func(v): return "%.1f kHz" % [v / 1000.0]
	s.value = 2400.0
	root.add_child(s)
	await process_frame
	_press(s, true)
	var editors: Array = []
	for child in s.get_children():
		if child is FloatingValueEditor:
			editors.append(child)
	_assert(editors.size() == 1, "double-click spawns a FloatingValueEditor")
	_assert(not editors.is_empty() and editors[0].text == "2.4 kHz",
		"editor is prefilled with the current value text")
	# Committing a typed value applies it.
	var editor: FloatingValueEditor = editors[0]
	editor.text_submitted.emit("1000")
	_assert(is_equal_approx(s.value, 1000.0), "typed commit applies the parsed value")
	s.free()
	await process_frame


func _test_step_snapping() -> void:
	var s := _make()
	s.max_value = 10.0
	s.step = 1.0
	s.set_value_no_signal(5.0)
	_press(s)
	_move(s, -40)  # +0.2 of the range; snaps to the next whole step
	_release(s)
	_assert(is_equal_approx(s.value, 7.0), "drag snaps to the next step")
	# Snapping also applies to direct assignment.
	var t := _make()
	t.max_value = 10.0
	t.step = 1.0
	t.value = 2.34
	_assert(is_equal_approx(t.value, 2.0), "value setter snaps to step")


func _test_log_mapping() -> void:
	var s := _make()
	s.min_value = 20.0
	s.max_value = 20000.0
	s.logarithmic = true
	var mid := sqrt(20.0 * 20000.0)  # geometric mean: the middle of the log range
	s.set_value_no_signal(mid)
	_assert(is_equal_approx(s._value_to_normalized(mid), 0.5),
		"the geometric mean sits at the middle of a 20 Hz-20 kHz log range")
	_assert(is_equal_approx(s._normalized_to_value(0.5), mid),
		"the inverse log map returns the geometric mean")
	# A drag through the log map reaches the same value.
	var d := _make()
	d.min_value = 20.0
	d.max_value = 20000.0
	d.logarithmic = true
	_press(d)
	_move(d, -100)  # +0.5 of the normalized range
	_release(d)
	_assert(is_equal_approx(d.value, mid), "drag maps through the log curve")


func _test_bidirectional_fill() -> void:
	var s := _make()
	s.min_value = -24.0
	s.max_value = 24.0
	s.set_value_no_signal(0.0)
	_assert(s._bidirectional(), "a range spanning zero is bidirectional")
	_assert(is_equal_approx(s._norm_value(), 0.5), "value 0 sits at the centre")
	_assert(is_equal_approx(s._value_to_norm(12.0), 0.75), "value +12 maps to the right half")
	s.set_value_no_signal(-12.0)
	_assert(is_equal_approx(s._norm_value(), 0.25), "value -12 maps to the left half")


func _test_minimum_size() -> void:
	# A bare Control in a container gets its minimum size; without this the control lays out
	# 0 px tall and never receives mouse input (the EQ footer bug).
	var s := _make()
	_assert(s.get_minimum_size().y >= 16.0, "intrinsic height covers the text line and the bar")


func _test_mod_surface() -> void:
	var s := _make()
	s.min_value = -24.0
	s.max_value = 24.0
	s.set_value_no_signal(4.0)
	var before := s.value
	s.mod_ranges = [{"amount": 0.5, "color": Color.RED, "bipolar": false} as Dictionary]
	_assert(s.mod_ranges.size() == 1, "mod_ranges accepts a route")
	# Assign drag: the amount changes, the value does not.
	s.mod_assign_active = true
	_press(s)
	_move(s, -60)  # up
	_release(s)
	_assert(not _mod_amounts.is_empty(), "assign drag emits mod_amount_changed")
	_assert(_mod_amounts[0] > 0.0, "dragging up raises the routed amount")
	_assert(is_equal_approx(s.value, before), "the value itself is unchanged during assign drag")
	_assert(s.mod_assign_amount == _mod_amounts[0], "mod_assign_amount follows the drag")
	# Double-click in assign mode asks for 0.
	_press(s, true)
	_release(s)
	_assert(_mod_amounts.back() == 0.0, "assign double-click resets the amount to 0")
	s.mod_assign_active = false
