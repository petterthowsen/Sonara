# test_key_change_item.gd
# Spec 034 G-004: the key change tab shows the scale's display name, has a minimum width, and
# reports its gestures: left press/drag/release, right-click menu, arrow click and double-click
# open the dropdown (there is no text edit here, unlike the time signature tab).
#
# Run: godot --headless --path Godot -s tests/test_key_change_item.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Key change item"


func run_tests() -> void:
	_test_label_and_width()
	_test_signals()


func _mouse(item: Control, button: int, pos: Vector2, pressed: bool, double := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	e.double_click = double
	item._gui_input(e)


func _motion(item: Control, pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	item._gui_input(e)


func _test_label_and_width() -> void:
	var item: Control = load("res://arranger/ruler/KeyChangeItem.gd").new()
	get_root().add_child(item)
	item.set_key(7, 2, "dorian")
	_assert(item.change_id == 7, "set_key stores the id")
	_assert(item.text == "D Dorian", "label is MusicalScale.display_name(): %s" % item.text)
	_assert(item.custom_minimum_size.x >= item.MIN_WIDTH, "tab is at least MIN_WIDTH wide")
	_assert(item.is_editing() == false, "double-click never opens a text edit")
	item.set_key(8, 0, "none")
	_assert(item.text == "No scale", "none reads No scale")
	item.set_key(9, 9, "natural_minor")
	_assert(item.text == "A Natural Minor", "root and label combine: %s" % item.text)
	var a: Rect2 = item.arrow_rect()
	_assert(a.position.x > 0.0 and a.end.x <= item.size.x and a.size.x > 0.0,
		"arrow sits inside the tab on the right edge")
	item.queue_free()


func _test_signals() -> void:
	var item: Control = load("res://arranger/ruler/KeyChangeItem.gd").new()
	get_root().add_child(item)
	item.set_key(3, 2, "dorian")
	item.size = Vector2(item.custom_minimum_size.x, 24.0)  # the track normally sizes it
	var pressed_ids: Array = []
	var dragged: Array = []
	var released: Array = []
	var menus: Array = []
	var dropdowns: Array = []
	item.pressed.connect(func(id): pressed_ids.append(id))
	item.dragged.connect(func(id, x): dragged.append([id, x]))
	item.released.connect(func(id): released.append(id))
	item.menu_requested.connect(func(id, pos): menus.append([id, pos]))
	item.dropdown_requested.connect(func(id, pos): dropdowns.append([id, pos]))

	# Press then drag: gestures only, no map edits here.
	_mouse(item, MOUSE_BUTTON_LEFT, Vector2(5, 5), true)
	_motion(item, Vector2(30, 5))
	_mouse(item, MOUSE_BUTTON_LEFT, Vector2(30, 5), false)
	_assert(pressed_ids == [3], "left press emits pressed")
	_assert(dragged.size() == 1 and dragged[0][0] == 3, "drag motion emits dragged")
	_assert(released == [3], "release after a drag emits released")

	# Right-click asks for the menu.
	_mouse(item, MOUSE_BUTTON_RIGHT, Vector2(10, 5), true)
	_assert(menus.size() == 1 and menus[0][0] == 3, "right-click emits menu_requested")

	# Arrow click and double-click both open the dropdown.
	_mouse(item, MOUSE_BUTTON_LEFT, item.arrow_rect().get_center(), true)
	_assert(dropdowns.size() == 1 and dropdowns[0][0] == 3, "arrow click emits dropdown_requested")
	_mouse(item, MOUSE_BUTTON_LEFT, Vector2(10, 5), true, true)
	_assert(dropdowns.size() == 2, "double-click emits dropdown_requested (no text edit)")

	# A plain click on the body neither drags nor re-opens the dropdown.
	_mouse(item, MOUSE_BUTTON_LEFT, Vector2(10, 5), true)
	_mouse(item, MOUSE_BUTTON_LEFT, Vector2(10, 5), false)
	_assert(dropdowns.size() == 2 and released.size() == 1,
		"a click without motion stays pressed (no release, no dropdown)")
	item.queue_free()
