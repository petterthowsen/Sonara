# Mixer meter fader: grabbing the cap handle never jumps, a press on the column jumps to the
# pointer, Ctrl-click resets, and the value tooltip shows while hovering or dragging. Also the
# centered scale, the hover-only handle and the right-click options menu.
# Run: godot --headless --path Godot -s tests/test_meter_fader.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Meter fader"


func run_tests() -> void:
	await _test_fader()
	await _test_centered_ticks()
	await _test_handle_on_hover()
	await _test_settings_menu()


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


func _test_centered_ticks() -> void:
	var meter := Meter.new()
	meter.show_fader = true
	meter.bars_spacing = 6
	meter.tick_position = Meter.TickPosition.CENTER
	meter.size = Vector2(60, 200)
	root.add_child(meter)
	await process_frame
	_assert(meter._centered_ticks(), "a wide stereo meter uses the centered scale")
	var column_x: float = meter._center_bar_width()
	_assert(is_equal_approx(column_x, 20.0), "the bars share what the label column leaves (%s)" % column_x)
	var mid := column_x + meter.center_ticks_width * 0.5
	_assert(is_equal_approx(meter._get_fader_offset_x() + meter._fader_width() * 0.5, mid) and meter._fader_width() > meter.bars_spacing, "a wide fader runs down the middle of the column")
	_assert(meter._is_mouse_in_fader(Vector2(column_x + 1.0, 50.0)), "the whole label column is the fader")
	_assert(not meter._is_mouse_in_fader(Vector2(column_x - 2.0, 50.0)), "the bars are not")
	meter.mono = true
	_assert(not meter._centered_ticks(), "a mono meter keeps the side scale")
	meter.mono = false
	meter.size = Vector2(40, 200)
	_assert(not meter._centered_ticks(), "a meter too narrow for the column drops it")
	meter.queue_free()
	await process_frame


func _test_handle_on_hover() -> void:
	var meter := Meter.new()
	meter.show_fader = true
	meter.fader_handle_on_hover = true
	meter.size = Vector2(60, 200)
	root.add_child(meter)
	await process_frame
	var x := meter._get_fader_offset_x() + 1.0
	var handle_y: float = meter._db_to_y(meter.volume_db)
	# the hidden handle still grabs without a jump, since hovering shows it
	meter._gui_input(_button(Vector2(x, handle_y + 2.0), true))
	_assert(meter._is_dragging_fader and is_equal_approx(meter.volume_db, -6.0), "a press on the hidden handle grabs it")
	meter._gui_input(_button(Vector2(x, handle_y), false))
	meter.queue_free()
	await process_frame


func _right_click() -> InputEventMouseButton:
	var ev := _button(Vector2(5, 5), true)
	ev.button_index = MOUSE_BUTTON_RIGHT
	return ev


func _test_settings_menu() -> void:
	var key := "mixer/big_meter"
	var a := Meter.new()
	var b := Meter.new()
	var plain := Meter.new()
	for m in [a, b]:
		m.settings_key = key
	for m in [a, b, plain]:
		m.size = Vector2(60, 200)
		root.add_child(m)
	await process_frame
	_assert(not a.show_fader and a.tick_position == Meter.TickPosition.SIDE, "a keyed meter starts from the registered defaults")
	plain._gui_input(_right_click())
	_assert(plain._menu == null, "a meter without a settings key has no menu")
	a._gui_input(_right_click())
	_assert(a._menu != null and a._menu.visible, "right-click opens the options menu")
	var hover_index := a._menu.get_item_index(Meter.MenuItem.HANDLE_ON_HOVER)
	_assert(a._menu.is_item_disabled(hover_index), "the handle option is disabled while the fader is hidden")
	a._on_menu_id_pressed(Meter.MenuItem.SHOW_FADER)
	a._on_menu_id_pressed(Meter.MenuItem.CENTERED_TICKS)
	_assert(b.show_fader and b.tick_position == Meter.TickPosition.CENTER, "every meter sharing the key follows the change")
	_assert(not a._menu.is_item_disabled(hover_index), "the handle option enables with the fader")
	a._on_menu_id_pressed(Meter.MenuItem.HANDLE_ON_HOVER)
	_assert(b.fader_handle_on_hover and root.get_node("Settings").get_value(key + "/fader_handle_on_hover"), "the handle option is stored")
	var settings := root.get_node("Settings")
	for option in ["centered_ticks", "show_fader", "fader_handle_on_hover"]:
		settings.set_value(key + "/" + option, settings.get_setting(key + "/" + option).default)
	for m in [a, b, plain]:
		m.queue_free()
	await process_frame
