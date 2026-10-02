# test_fader.gd
# Headless tests for Fader, ScaleMarks and SegmentedControl: grab without a jump, track click
# jumps, Shift fine drag, Ctrl-click reset, typed entry, skewed taper round trip, fill origin,
# no signal on a no-op.
# Run: godot --headless --path Godot -s tests/test_fader.gd -- --test
extends TestBase

var _changes: Array[float] = []
var _resets := 0


func suite_name() -> String:
	return "Fader tests"


func run_tests() -> void:
	_test_taper_round_trip()
	_test_scale_marks_layout()
	_test_grab_does_not_jump()
	_test_track_click_jumps()
	_test_shift_drag_is_fine()
	_test_ctrl_click_resets()
	_test_typed_entry()
	_test_no_signal_on_noop()
	_test_fill_origin()
	_test_segmented_control()


func _fader() -> Fader:
	var f := Fader.new()
	f.min_value = 0.0
	f.max_value = 100.0
	f.value = 50.0
	f.value_default = 25.0
	f.position = Vector2(100, 100)
	root.add_child(f)
	f.size = Vector2(30, 208) # 8 px of handle padding leave a 200 px track at y 4..204
	_changes.clear()
	_resets = 0
	f.value_changed.connect(func(v): _changes.append(v))
	f.reset_requested.connect(func(): _resets += 1)
	return f


func _press(f: Fader, pos: Vector2, ctrl := false, double := false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	ev.ctrl_pressed = ctrl
	ev.double_click = double
	f._gui_input(ev)


func _release(f: Fader, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	ev.position = pos
	f._gui_input(ev)


func _drag_to(f: Fader, from: Vector2, to: Vector2, shift := false) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = to
	ev.relative = to - from
	ev.shift_pressed = shift
	f._gui_input(ev)


func _test_taper_round_trip() -> void:
	var f := _fader()
	f.min_value = 1.0
	f.max_value = 30.0
	f.to_position = func(v): return pow((v - 1.0) / 29.0, 0.5)
	f.from_position = func(n): return 1.0 + 29.0 * n * n
	for v in [1.0, 2.0, 8.0, 30.0]:
		var back := f.position_to_value(f.value_to_position(v))
		_assert(absf(back - v) < 0.001, "skewed taper round-trips %s (got %s)" % [v, back])
	var g := _fader()
	g.min_value = 20.0
	g.max_value = 20000.0
	g.logarithmic = true
	_assert(absf(g.value_to_position(632.455) - 0.5) < 0.01, "logarithmic puts the geometric mean halfway")
	f.free()
	g.free()


func _test_scale_marks_layout() -> void:
	var items := ScaleMarks.layout([{"value": 0.0}, {"value": 50.0, "label": "half"}, {"value": 200.0}],
		func(v): return v / 100.0, 200.0, -200.0)
	_assert(items.size() == 2, "marks outside the range are dropped")
	_assert(is_equal_approx(items[0]["pos"], 200.0) and items[0]["label"] == "0", "bottom mark sits at the origin")
	_assert(is_equal_approx(items[1]["pos"], 100.0) and items[1]["label"] == "half", "custom label, mid position")


func _test_grab_does_not_jump() -> void:
	var f := _fader()
	var handle_y := f.position_y(0.5)
	var grab := Vector2(15, handle_y + 3.0) # off-centre on the handle
	_press(f, grab)
	_assert(f.value == 50.0 and _changes.is_empty(), "grabbing the handle leaves the value alone")
	_drag_to(f, grab, grab + Vector2(0, -20))
	_assert(is_equal_approx(f.value, 60.0), "dragging up 20 px of a 200 px track adds 10 (got %s)" % f.value)
	_release(f, grab)
	f.free()


func _test_track_click_jumps() -> void:
	var f := _fader()
	_press(f, Vector2(15, f.position_y(0.9)))
	_assert(absf(f.value - 90.0) < 0.001, "a click on the track jumps to the pointer (got %s)" % f.value)
	_release(f, Vector2(15, 0))
	f.free()


func _test_shift_drag_is_fine() -> void:
	var f := _fader()
	var grab := Vector2(15, f.position_y(0.5))
	_press(f, grab)
	_drag_to(f, grab, grab + Vector2(0, -20), true)
	_assert(is_equal_approx(f.value, 51.5), "Shift moves at 0.15x (got %s)" % f.value)
	_drag_to(f, grab + Vector2(0, -20), grab + Vector2(0, -40), false)
	_assert(is_equal_approx(f.value, 61.5), "releasing Shift continues 1:1 without a jump (got %s)" % f.value)
	_release(f, grab)
	f.free()


func _test_ctrl_click_resets() -> void:
	var f := _fader()
	_press(f, Vector2(15, 100), true)
	_assert(f.value == 25.0, "Ctrl-click resets to the default")
	_assert(f.last_edit_kind == ValueEditKind.Kind.DRAG, "edit kind is back to DRAG afterwards")
	_press(f, Vector2(15, 100), true)
	_assert(_resets == 2, "reset_requested fires even when already at the default")
	f.free()


func _test_typed_entry() -> void:
	var f := _fader()
	var kinds: Array[int] = []
	f.value_changed.connect(func(_v): kinds.append(f.last_edit_kind))
	f._on_edit_committed(" 77.5 ")
	_assert(f.value == 77.5 and kinds == [ValueEditKind.Kind.TYPED], "typed entry sets the value as TYPED")
	f._on_edit_committed("abc")
	_assert(f.value == 77.5, "garbage text is ignored")
	f._on_edit_committed("500")
	_assert(f.value == 100.0, "typed values clamp to the range")
	f.free()


func _test_no_signal_on_noop() -> void:
	var f := _fader()
	f.value = 50.0
	f.set_value_no_signal(30.0)
	_assert(_changes.is_empty(), "no signal for the same value or set_value_no_signal")
	f.value = 31.0
	_assert(_changes == [31.0], "a real change emits once")
	f.free()


func _test_fill_origin() -> void:
	var f := _fader()
	f.min_value = -12.0
	f.max_value = 24.0
	f.fill_origin = 0.0
	_assert(is_equal_approx(f.value_to_position(0.0), 1.0 / 3.0), "0 dB sits a third up a -12..24 track")
	f.free()


func _test_segmented_control() -> void:
	var seg := SegmentedControl.new()
	root.add_child(seg)
	seg.set_items(PackedStringArray(["Clean", "Glue", "Punch", "Opto"]))
	var picked: Array[int] = []
	seg.selected_changed.connect(func(i): picked.append(i))
	seg.set_selected_no_signal(2)
	_assert(seg.selected == 2 and picked.is_empty(), "set_selected_no_signal does not emit")
	seg._buttons[1].pressed.emit()
	_assert(seg.selected == 1 and picked == [1], "pressing a segment selects it and emits once")
	seg._buttons[1].pressed.emit()
	_assert(picked == [1], "pressing the selected segment again does nothing")
	seg.selected = 3
	_assert(picked == [1, 3], "setting selected emits")
	seg.free()
