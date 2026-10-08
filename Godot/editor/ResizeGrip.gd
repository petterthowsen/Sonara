# Bottom-right corner handle for the borderless main window. The window manager does the
# actual resize (window_start_resize), like the floating device frames. Hidden while maximized.
class_name ResizeGrip extends Control

const GRIP_SIZE := 16.0
const LINE_COUNT := 3
const LINE_SPACING := 4.0

var _hover := false


func _ready() -> void:
	custom_minimum_size = Vector2(GRIP_SIZE, GRIP_SIZE)
	mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))
	get_window().size_changed.connect(_update_visibility)
	_update_visibility()


func _update_visibility() -> void:
	var mode := DisplayServer.window_get_mode()
	visible = mode == DisplayServer.WINDOW_MODE_WINDOWED


func _set_hover(on: bool) -> void:
	_hover = on
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		DisplayServer.window_start_resize(DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT)
		accept_event()


func _draw() -> void:
	var color := Color(1, 1, 1, 0.6 if _hover else 0.3)
	var corner := size - Vector2(3, 3)
	for i in LINE_COUNT:
		var d := 4.0 + i * LINE_SPACING
		draw_line(corner - Vector2(d, 0), corner - Vector2(0, d), color, 1.5)
