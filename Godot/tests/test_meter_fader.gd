# Mixer meter fader: grabbing the cap handle never jumps, a press on the column jumps to the
# pointer, Ctrl-click resets, and the value tooltip shows while hovering or dragging.
# Run: godot --headless --path Godot -s tests/test_meter_fader.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Meter fader"


func run_tests() -> void:
	await _test_fader()


func _button(pos: Vector2, pressed: bool, ctrl := false) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.ctrl_pressed = ctrl
	return ev


func _motion(pos: Vector2, relative: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = relative
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	return ev


func _test_fader() -> void:
	var meter := Meter.new()
	meter.show_fader = true
	meter.bars_spacing = 6
	meter.size = Vector2(60, 200)
	root.add_child(meter)
	await process_frame
	meter.volume_db = -6.0
	var x := meter._get_fader_offset_x() + 3.0
	var handle_y: float = meter._db_to_y(-6.0)

	# Grab the handle off-centre: no jump.
	var received: Array[float] = []
	meter.volume_changed.connect(func(v: float) -> void: received.append(v))
	meter._gui_input(_button(Vector2(x, handle_y + 3.0), true))
	_assert(received.is_empty() and is_equal_approx(meter.volume_db, -6.0), "grabbing the handle does not move the value")
	_assert(meter._tooltip != null and meter._tooltip.visible, "the tooltip shows while dragging")
	meter._gui_input(_motion(Vector2(x, handle_y - 17.0), Vector2(0, -20)))
	_assert(meter.volume_db > -6.0, "dragging up raises the value (%s)" % meter.volume_db)
	meter._gui_input(_button(Vector2(x, handle_y), false))
	_assert(meter._tooltip.visible, "the tooltip stays while the pointer is over the fader")
	meter._gui_input(_motion(Vector2(1.0, handle_y), Vector2.ZERO))
	_assert(not meter._tooltip.visible, "and hides once the pointer leaves it")

	# A press on the column away from the handle jumps there.
	meter.volume_db = -6.0
	var target_y: float = meter._db_to_y(-40.0)
	meter._gui_input(_button(Vector2(x, target_y), true))
	_assert(absf(meter.volume_db + 40.0) < 1.0, "a press on the column jumps to the pointer (%s)" % meter.volume_db)
	meter._gui_input(_button(Vector2(x, target_y), false))

	# Ctrl-click resets.
	meter._gui_input(_button(Vector2(x, target_y), true, true))
	_assert(is_equal_approx(meter.volume_db, meter.volume_default_db), "Ctrl-click resets to the default")
	meter.queue_free()
	await process_frame
