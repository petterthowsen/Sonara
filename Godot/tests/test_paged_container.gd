extends TestBase


func suite_name() -> String:
	return "PagedContainer tests"


func run_tests() -> void:
	var sc := PagedContainer.new()
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

	# Items are 60 tall in a 100 view: the second is cut off, so a page starts with it.
	_assert(is_equal_approx(sc._step_target(true, 1), 64.0), "down pages to the first item not wholly in view")
	sc.scroll_vertical = 64
	_assert(is_equal_approx(sc._step_target(true, -1), 0.0), "up pages back to the item start")
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
	# The 68 left between the strips holds one 60-tall row; the other 8 is split over both ends.
	_assert(is_equal_approx(box.position.y, sc.button_thickness + 4.0), "content starts below the reserved strip, centered (got %s)" % box.position.y)
	_assert(is_equal_approx(sc.get_v_scroll_bar().page, 60.0), "view is trimmed to whole rows (got %s)" % sc.get_v_scroll_bar().page)
	_assert(not sc._button_up.visible, "reserved up button hides at the top")
	_assert(sc._button_down.visible, "reserved down button is shown")
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

	# Fading: with a 60 view (100 minus the strips, trimmed to a row) only the first 60-tall item is wholly in view.
	sc.fade_hidden_items = true
	await root.get_tree().process_frame
	_assert(is_equal_approx(box.get_child(0).modulate.a, 1.0), "item in view stays opaque")
	_assert(is_equal_approx(box.get_child(1).modulate.a, 0.0), "cut-off item fades out (got %s)" % box.get_child(1).modulate.a)
	sc.scroll_vertical = 64
	await root.get_tree().process_frame
	_assert(is_equal_approx(box.get_child(0).modulate.a, 0.0), "item scrolled out fades out")
	_assert(is_equal_approx(box.get_child(1).modulate.a, 1.0), "item scrolled in fades back in")
	sc.scroll_vertical = 0
	await root.get_tree().process_frame

	# The wheel steps item by item like the buttons, so each notch reveals a whole item.
	# View is 60 (100 minus the strips, trimmed to a row): one 60-tall item at a time.
	_assert(sc.scroll_vertical == 0, "wheel test starts at the top")
	await _wheel(sc, MOUSE_BUTTON_WHEEL_DOWN)
	_assert(sc.scroll_vertical == 64, "wheel down pages to the next item's start (got %d)" % sc.scroll_vertical)
	_assert(is_equal_approx(box.get_child(1).modulate.a, 1.0), "wheel down reveals the next item")
	_assert(is_equal_approx(box.get_child(0).modulate.a, 0.0), "wheel down fades the item scrolled past")
	_assert(sc._button_up.visible, "wheel down shows the up button")
	await _wheel(sc, MOUSE_BUTTON_WHEEL_UP)
	_assert(sc.scroll_vertical == 0, "wheel up lands on the previous item's start (got %d)" % sc.scroll_vertical)
	_assert(not sc._button_up.visible, "back at the top hides the up button")

	# Hover-only buttons: hidden until the mouse is over the container, and over a button too.
	_assert(is_equal_approx(sc._button_layer.modulate.a, 1.0), "buttons always shown by default")
	await _move_mouse(Vector2(190, 190))
	sc.show_buttons_on_hover = true
	_assert(is_equal_approx(sc._button_layer.modulate.a, 0.0), "hover-only buttons hide while the mouse is away")
	await _move_mouse(sc.get_global_rect().get_center())
	_assert(is_equal_approx(sc._button_layer.modulate.a, 1.0), "hover-only buttons show on hover")
	await _move_mouse(sc._button_down.get_global_rect().get_center())
	_assert(is_equal_approx(sc._button_layer.modulate.a, 1.0), "buttons stay while hovering a button")
	await _move_mouse(Vector2(190, 190))
	_assert(is_equal_approx(sc._button_layer.modulate.a, 0.0), "hover-only buttons hide on leaving")
	sc.show_buttons_on_hover = false
	_assert(is_equal_approx(sc._button_layer.modulate.a, 1.0), "turning the option off shows the buttons")

	# Content that fits takes no reserve, so the whole area is used.
	for i in 4:
		box.get_child(i + 1).visible = false
	await root.get_tree().process_frame
	await root.get_tree().process_frame
	_assert(is_equal_approx(box.position.y, 0.0), "no reserve when content fits")
	_assert(not sc._button_up.visible and not sc._button_down.visible, "no buttons when content fits")
	sc.free()
	await _test_items_taller_than_view()
	await _test_odd_slack_pages_whole_rows()


## Items longer than the view can't show whole: paging lands on their starts, never cutting
## the top off an item to show its end.
func _test_items_taller_than_view() -> void:
	var sc := PagedContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size = Vector2(100, 40)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	for i in 6:
		var item := Control.new()
		item.custom_minimum_size = Vector2(100, 60)
		box.add_child(item)
	sc.add_child(box)
	root.add_child(sc)
	sc.size = Vector2(100, 40)
	await root.get_tree().process_frame
	await root.get_tree().process_frame
	_assert(is_equal_approx(sc._step_target(true, 1), 64.0), "tall items: down pages to the next item start (got %s)" % sc._step_target(true, 1))
	sc.scroll_vertical = 64
	_assert(is_equal_approx(sc._step_target(true, 1), 128.0), "tall items: next page is the following item start (got %s)" % sc._step_target(true, 1))
	_assert(is_equal_approx(sc._step_target(true, -1), 0.0), "tall items: up pages to the previous item start")

	# A view of two whole rows pages two rows at a time, both ways.
	sc.size = Vector2(100, 140)
	sc.scroll_vertical = 0
	await root.get_tree().process_frame
	_assert(is_equal_approx(sc._step_target(true, 1), 128.0), "a two-row view pages two rows (got %s)" % sc._step_target(true, 1))
	sc.scroll_vertical = 128
	_assert(is_equal_approx(sc._step_target(true, -1), 0.0), "a two-row view pages back two rows (got %s)" % sc._step_target(true, -1))
	sc.free()


## A view that leaves an odd number of pixels after its whole rows: the page is still exactly
## the rows, so the scroll end is a row start and the last page doesn't crawl by a pixel.
func _test_odd_slack_pages_whole_rows() -> void:
	var sc := PagedContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	for i in 5:
		var item := Control.new()
		item.custom_minimum_size = Vector2(100, 60)
		box.add_child(item)
	sc.add_child(box)
	root.add_child(sc)
	# 101 holds one 60-tall row, leaving 41: 20 above, 21 below.
	sc.size = Vector2(100, 101)
	await root.get_tree().process_frame
	await root.get_tree().process_frame
	_assert(is_equal_approx(sc.get_v_scroll_bar().page, 60.0), "odd slack: the page is one row (got %s)" % sc.get_v_scroll_bar().page)
	_assert(is_equal_approx(box.position.y, 20.0), "odd slack: the row sits centered (got %s)" % box.position.y)
	_assert(is_equal_approx(sc._max_scroll(true), 256.0), "odd slack: the scroll end is the last row start (got %s)" % sc._max_scroll(true))
	sc.scroll_vertical = 256
	_assert(is_equal_approx(sc._step_target(true, 1), 256.0), "odd slack: the last page doesn't step on")
	sc.free()


## One wheel notch over the middle of `sc`, then wait out the scroll and fade animations.
func _wheel(sc: PagedContainer, button: MouseButton) -> void:
	var at := sc.get_global_rect().get_center()
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = pressed
		ev.factor = 1.0
		ev.position = at
		ev.global_position = at
		root.push_input(ev)
	await root.get_tree().create_timer(sc.animation_duration + 0.1).timeout


func _move_mouse(at: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = at
	ev.global_position = at
	root.push_input(ev)
	await root.get_tree().process_frame
