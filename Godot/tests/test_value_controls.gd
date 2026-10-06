# test_value_controls.gd
# Headless tests for the shared value-control helpers: FineDrag (Shift precision without
# jumps), Volumeter (range, handle drag, clip line hold, tooltip) and LabeledKnob (full
# caption overlay when the caption is trimmed).
#
# Scripts are loaded with load() inside run_tests() because some reference autoloads.
# Run: godot --headless --path Godot -s tests/test_value_controls.gd -- --test
extends TestBase

var _fine_drag_script: GDScript
var _volumeter_script: GDScript
var _labeled_knob_script: GDScript
var _hslider_script: GDScript


func suite_name() -> String:
	return "Value control tests"


func run_tests() -> void:
	_fine_drag_script = load("res://components/FineDrag.gd")
	_volumeter_script = load("res://components/Volumeter.gd")
	_labeled_knob_script = load("res://components/LabeledKnob.gd")
	_hslider_script = load("res://components/HSlider.gd")
	_test_fine_drag_scales_and_never_jumps()
	_test_fine_drag_clamps_to_bounds()
	_test_hslider_shift_drag_is_fine()
	await _test_volumeter_drag_and_range()
	await _test_volumeter_clip_hold()
	await _test_labeled_knob_overlay()


func _motion(pos: Vector2, shift: bool) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.shift_pressed = shift
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	return ev


func _button(pos: Vector2, pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.position = pos
	ev.pressed = pressed
	return ev


func _test_fine_drag_scales_and_never_jumps() -> void:
	var drag = _fine_drag_script.new()
	_assert(drag.begin(Vector2(50, 50)) == Vector2(50, 50), "begin returns the press point")
	_assert(drag.update(Vector2(60, 50), false) == Vector2(60, 50), "normal motion is 1:1")
	var fine: Vector2 = drag.update(Vector2(80, 50), true)
	_assert(is_equal_approx(fine.x, 63.0), "shift motion is scaled by 0.15 (got %s)" % fine.x)
	var after: Vector2 = drag.update(Vector2(80, 50), false)
	_assert(is_equal_approx(after.x, 63.0), "releasing shift does not snap back to the pointer")
	after = drag.update(Vector2(90, 50), false)
	_assert(is_equal_approx(after.x, 73.0), "then continues 1:1 from the tracked point")


func _test_fine_drag_clamps_to_bounds() -> void:
	var drag = _fine_drag_script.new()
	var bounds := Rect2(0, 0, 100, 20)
	drag.begin(Vector2(90, 10))
	var p: Vector2 = drag.update(Vector2(200, 10), false, bounds)
	_assert(p.x == 100.0, "tracked point clamps to the bounds")
	p = drag.update(Vector2(190, 10), false, bounds)
	_assert(p.x == 90.0, "moving back responds right away after clamping")


func _test_hslider_shift_drag_is_fine() -> void:
	var slider: Control = _hslider_script.new()
	slider.bidirectional = false
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.size = Vector2(100, 10)
	slider._gui_input(_button(Vector2(50, 5), true))
	_assert(is_equal_approx(slider.value, 50.0), "press jumps to the pointer")
	slider._gui_input(_motion(Vector2(70, 5), true))
	_assert(is_equal_approx(slider.value, 53.0), "shift drag moves by 15%% of the motion (got %s)" % slider.value)
	_assert(slider.is_handle_visible(), "handle shows while dragging")
	slider._gui_input(_button(Vector2(70, 5), false))
	_assert(not slider.is_handle_visible(), "handle hides after the drag when not hovered (default)")
	slider._set_hovered(true)
	_assert(slider.is_handle_visible(), "handle shows on hover")
	slider._set_hovered(false)
	slider.handle_on_hover_only = false
	_assert(slider.is_handle_visible(), "handle_on_hover_only = false always shows it")
	slider.free()


func _test_volumeter_drag_and_range() -> void:
	var meter: Control = _volumeter_script.new()
	# Keep it away from the headless pointer at (0, 0) so it isn't hovered.
	meter.position = Vector2(400, 300)
	meter.size = Vector2(12, 132)
	root.add_child(meter)
	await process_frame
	meter.size = Vector2(12, 132)
	var emitted: Array[float] = []
	meter.volume_changed.connect(func(db: float) -> void: emitted.append(db))

	meter.set_volume_no_signal(12.0)
	_assert(meter.volume_db == 6.0, "volume clamps to db_top (6 dB) everywhere")

	# Relative drag: pressing grabs the handle (at 6 dB, the top) without moving the value.
	meter._gui_input(_button(Vector2(6, 0), true))
	_assert(is_equal_approx(meter.volume_db, 6.0), "press grabs the handle without jumping (got %s)" % meter.volume_db)
	meter._gui_input(_motion(Vector2(6, 66), false))
	_assert(is_equal_approx(meter.volume_db, -27.0), "dragging to mid height maps to the middle of -60..6 (got %s)" % meter.volume_db)
	_assert(meter._tooltip != null and meter._tooltip.visible, "tooltip shows while adjusting")
	_assert(meter._tooltip._label.text == "-27.0 dB", "tooltip shows the volume in dB")
	meter._gui_input(_motion(Vector2(6, 0), true))
	_assert(meter.volume_db > -27.0 and meter.volume_db < -20.0, "shift drag moves the volume finely (got %s)" % meter.volume_db)
	meter._gui_input(_button(Vector2(6, 0), false))
	_assert(not meter.is_adjusting, "release stops adjusting")
	_assert(not meter._tooltip.visible, "tooltip hides when neither hovered nor adjusting")
	_assert(emitted.size() == 2, "volume_changed emitted once per change (got %d)" % emitted.size())
	meter.queue_free()
	await process_frame


func _test_volumeter_clip_hold() -> void:
	var meter: Control = _volumeter_script.new()
	meter.clip_hold_time = 0.2
	root.add_child(meter)
	meter.set_levels(0.5, 0.3)
	_assert(not meter._is_clip_held(), "no clip line below 0 dB")
	meter.set_levels(1.2, 0.5)
	_assert(meter._is_clip_held(), "clip line lights at 0 dB")
	await create_timer(0.1).timeout
	meter.set_levels(1.0, 0.5)
	await create_timer(0.15).timeout
	_assert(meter._is_clip_held(), "a new clip extends the hold")
	await create_timer(0.15).timeout
	_assert(not meter._is_clip_held(), "clip line clears after the hold time")
	meter.queue_free()
	await process_frame


func _test_labeled_knob_overlay() -> void:
	var knob: Control = _labeled_knob_script.new()
	knob.position = Vector2(400, 300)
	knob.label_width = 30.0
	knob.text = "Very Long Bus Name"
	root.add_child(knob)
	await process_frame
	var overlay: Control = knob.overlay
	_assert(overlay.is_truncated(), "long caption is trimmed")
	knob.knob.mouse_entered.emit()
	_assert(overlay.visible, "hovering the knob shows the full caption overlay")
	_assert(overlay._text_label.text == "Very Long Bus Name", "overlay has the full caption")
	_assert(knob.label.size.x < 40.0, "the caption keeps its width (got %s)" % knob.label.size.x)
	knob.knob.mouse_exited.emit()
	_assert(not overlay.visible, "overlay hides on exit")
	knob.label.mouse_entered.emit()
	_assert(overlay.visible, "hovering the caption itself shows it too")
	knob.label.mouse_exited.emit()

	_assert(knob.get_child(1) == knob.label and knob.knob.tooltip_side == 0, "default: caption below, value tooltip above")
	knob.label_position = 0  # TOP
	_assert(knob.get_child(0) == knob.label and knob.knob.tooltip_side == 1, "caption on top moves the value tooltip below")

	knob.text = "Rev"
	await process_frame
	knob.knob.mouse_entered.emit()
	_assert(not overlay.visible, "no overlay when the caption fits")
	knob.queue_free()
	await process_frame
