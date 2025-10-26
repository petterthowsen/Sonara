extends HBoxContainer

var is_dragging: bool = false
var drag_start_pos: Vector2i = Vector2i.ZERO
var window_start_pos: Vector2i = Vector2i.ZERO


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and event.double_click:
				if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				else:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
			elif event.pressed:
				_start_dragging()
			else:
				_stop_dragging()
			accept_event()


func _start_dragging() -> void:
	is_dragging = true
	drag_start_pos = DisplayServer.mouse_get_position()
	window_start_pos = DisplayServer.window_get_position()
	set_process(true)


func _stop_dragging() -> void:
	is_dragging = false
	set_process(false)


func _process(_delta: float) -> void:
	if is_dragging:
		var mouse_pos = DisplayServer.mouse_get_position()
		var delta = mouse_pos - drag_start_pos
		DisplayServer.window_set_position(window_start_pos + delta)
