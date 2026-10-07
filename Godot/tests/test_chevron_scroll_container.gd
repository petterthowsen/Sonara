extends TestBase


func suite_name() -> String:
	return "ChevronScrollContainer tests"


func run_tests() -> void:
	var sc := ChevronScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	sc.custom_minimum_size = Vector2(100, 100)
	sc.size = Vector2(100, 100)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)  # pinned: the theme's separation is the spacing unit
	for i in 5:
		var item := Control.new()
		item.custom_minimum_size = Vector2(100, 60)
		box.add_child(item)
	sc.add_child(box)
	root.add_child(sc)
	sc.size = Vector2(100, 100)
	await root.get_tree().process_frame
	await root.get_tree().process_frame

	_assert(sc.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_SHOW_NEVER, "scrollbar hidden")
	_assert(sc.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "disabled axis stays disabled")
	_assert(sc.scroll_vertical == 0, "starts at top")
	_assert(sc._button_down.visible and sc._button_down.size == Vector2(100, 16) and sc._button_down.position == Vector2(0, 84), "down button shown on the bottom edge")
	_assert(not sc._button_up.visible, "up button hidden at the top")

	# Items are 60 tall in a 100 view: the second is cut off, so a step ends on its bottom edge.
	_assert(is_equal_approx(sc._step_target(true, 1), 24.0), "down snaps to next item end")
	sc.scroll_vertical = 24
	_assert(is_equal_approx(sc._step_target(true, -1), 0.0), "up snaps to item start")
	sc.scroll_vertical = 1000
	_assert(is_equal_approx(sc._step_target(true, 1), sc._max_scroll(true)), "down clamps at the end")

	# Rows are 60 + 4 separation: a 150 view snaps to two rows (124), an 80 view to one (60).
	_assert(is_equal_approx(sc.snap_length(true, 150.0), 124.0), "snap_length rounds to two rows")
	_assert(is_equal_approx(sc.snap_length(true, 80.0), 60.0), "snap_length rounds to one row")
	_assert(is_equal_approx(sc.snap_length(true, 400.0), 400.0), "snap_length leaves a fitting length alone")

	sc.scroll_vertical = 70
	sc.snap_scroll(true)
	await root.get_tree().create_timer(sc.animation_duration + 0.1).timeout
	_assert(sc.scroll_vertical == 64, "snap_scroll lands on the nearest row start (got %d)" % sc.scroll_vertical)

	# Reserving: buttons get their own strips, so the view shrinks and the content moves down.
	sc.scroll_vertical = 0
	sc.reserve_button_space = true
	await root.get_tree().process_frame
	await root.get_tree().process_frame
	_assert(is_equal_approx(box.position.y, sc.button_thickness), "content starts below the reserved strip (got %s)" % box.position.y)
	_assert(is_equal_approx(sc.get_v_scroll_bar().page, 100.0 - 2.0 * sc.button_thickness), "view excludes both strips")
	_assert(sc._button_up.visible and sc._button_up.disabled, "reserved up button stays, disabled at the top")
	_assert(sc._button_down.visible and not sc._button_down.disabled, "reserved down button is enabled")
	_assert(is_equal_approx(sc.snap_length(true, 110.0), 60.0 + 2.0 * sc.button_thickness), "snap_length counts the reserved strips")

	# A real click on the down button (through the viewport, so the content can't swallow it).
	root.size = Vector2i(200, 200)
	await root.get_tree().process_frame
	var click_at := sc._button_down.get_global_rect().get_center()
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = click_at
		ev.global_position = click_at
		root.push_input(ev)
	await root.get_tree().create_timer(sc.animation_duration + 0.1).timeout
	_assert(sc.scroll_vertical > 0, "clicking the down button scrolls (got %d)" % sc.scroll_vertical)
	sc.scroll_vertical = 0
	await root.get_tree().process_frame

	# Fading: with a 68 view (100 minus the strips) only the first 60-tall item is wholly in view.
	sc.fade_hidden_items = true
	await root.get_tree().create_timer(sc.fade_duration + 0.1).timeout
	_assert(is_equal_approx(box.get_child(0).modulate.a, 1.0), "item in view stays opaque")
	_assert(is_equal_approx(box.get_child(1).modulate.a, 0.0), "cut-off item fades out (got %s)" % box.get_child(1).modulate.a)
	sc.scroll_vertical = 64
	await root.get_tree().create_timer(sc.fade_duration + 0.1).timeout
	_assert(is_equal_approx(box.get_child(0).modulate.a, 0.0), "item scrolled out fades out")
	_assert(is_equal_approx(box.get_child(1).modulate.a, 1.0), "item scrolled in fades back in")
	sc.scroll_vertical = 0
	await root.get_tree().process_frame

	# The wheel steps item by item like the buttons, so each notch reveals a whole item.
	# View is 68 (100 minus the strips): one 60-tall item at a time.
	_assert(sc.scroll_vertical == 0, "wheel test starts at the top")
	await _wheel(sc, MOUSE_BUTTON_WHEEL_DOWN)
	_assert(sc.scroll_vertical == 56, "wheel down lands on the next item's end (got %d)" % sc.scroll_vertical)
	_assert(is_equal_approx(box.get_child(1).modulate.a, 1.0), "wheel down reveals the next item")
	_assert(is_equal_approx(box.get_child(0).modulate.a, 0.0), "wheel down fades the item scrolled past")
	_assert(not sc._button_up.disabled, "wheel down enables the up button")
	await _wheel(sc, MOUSE_BUTTON_WHEEL_UP)
	_assert(sc.scroll_vertical == 0, "wheel up lands on the previous item's start (got %d)" % sc.scroll_vertical)
	_assert(sc._button_up.disabled, "back at the top disables the up button")

	# Content that fits takes no reserve, so the whole area is used.
	for i in 4:
		box.get_child(i + 1).visible = false
	await root.get_tree().process_frame
	await root.get_tree().process_frame
	_assert(is_equal_approx(box.position.y, 0.0), "no reserve when content fits")
	_assert(not sc._button_up.visible and not sc._button_down.visible, "no buttons when content fits")
	sc.free()


## One wheel notch over the middle of `sc`, then wait out the scroll and fade animations.
func _wheel(sc: ChevronScrollContainer, button: MouseButton) -> void:
	var at := sc.get_global_rect().get_center()
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = pressed
		ev.factor = 1.0
		ev.position = at
		ev.global_position = at
		root.push_input(ev)
	await root.get_tree().create_timer(sc.animation_duration + sc.fade_duration + 0.1).timeout
