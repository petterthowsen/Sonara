# test_drag_toggle_button.gd
# DragToggleButton toggles on press and paints its state onto other buttons of the group.
# Run: godot --headless --path Godot -s tests/test_drag_toggle_button.gd -- --test
extends TestBase


func suite_name() -> String:
	return "DragToggleButton tests"


func _make(group: StringName, pos: Vector2, root: Control) -> DragToggleButton:
	var b := DragToggleButton.new()
	b.drag_group = group
	b.position = pos
	b.size = Vector2(30, 30)
	root.add_child(b)
	return b


func run_tests() -> void:
	var root := Control.new()
	Engine.get_main_loop().root.add_child(root)
	var a := _make(&"solo", Vector2(0, 0), root)
	var b := _make(&"solo", Vector2(0, 40), root)
	var c := _make(&"solo", Vector2(0, 80), root)
	var m := _make(&"mute", Vector2(0, 40), root)

	_assert(a.action_mode == BaseButton.ACTION_MODE_BUTTON_PRESS, "toggles on press")

	a.button_pressed = true
	a._paint_value = true
	a._last_mouse = Vector2(10, 10)
	a._paint_to(Vector2(10, 95))  # a fast sweep over b and c
	_assert(b.button_pressed and c.button_pressed, "sweep paints every crossed button")
	_assert(not m.button_pressed, "other groups are untouched")

	a._paint_value = false
	a._last_mouse = Vector2(10, 10)
	a._paint_to(Vector2(10, 50))
	_assert(not b.button_pressed and c.button_pressed, "painting off stops at the pointer")

	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.shift_pressed = true
	a._gui_input(click)
	_assert(not c.button_pressed, "shift+press clears the other buttons of the group")

	root.queue_free()
