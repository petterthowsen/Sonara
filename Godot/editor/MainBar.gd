extends HBoxContainer
# Title bar of the borderless main window. Dragging is handed to the window manager
# (window_start_drag), like ResizeGrip does for resizing: Wayland forbids moving a window
# by setting its position.


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and event.double_click:
				if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MAXIMIZED:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				else:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
			elif event.pressed:
				DisplayServer.window_start_drag()
			accept_event()
