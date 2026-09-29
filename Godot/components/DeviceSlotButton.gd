## Shows or hides one container slot in the device lane. Drawn as a small tile: a strip in the
## slot color along the top and the slot title in the middle. Open slots get a colored border and
## a brighter title. Bind it with `bind_to_slot`; it follows the container's `slots_changed`.
class_name DeviceSlotButton extends Control

const STRIP_HEIGHT := 8.0
const BG_COLOR := Color(0.11, 0.11, 0.11)
const BORDER_COLOR := Color(0.3, 0.3, 0.3)
const TITLE_COLOR := Color(0.6, 0.6, 0.6)
const TITLE_COLOR_OPEN := Color(0.92, 0.92, 0.92)

@export var font_size := 14

var container: DeviceInstance = null
var key := ""
var _hovering := false


func _init() -> void:
	custom_minimum_size = Vector2(120, 64)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))


## Show slot `p_key` of `p_container` (null unbinds).
func bind_to_slot(p_container: DeviceInstance, p_key: String) -> void:
	_unbind()
	container = p_container
	key = p_key
	if container:
		container.slots_changed.connect(_on_slots_changed)
	_on_slots_changed()


func _unbind() -> void:
	if container and container.slots_changed.is_connected(_on_slots_changed):
		container.slots_changed.disconnect(_on_slots_changed)
	container = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


func is_open() -> bool:
	return container != null and container.is_slot_open(key)


func _on_slots_changed() -> void:
	tooltip_text = ("Hide %s" if is_open() else "Show %s") % _title() if container else ""
	queue_redraw()


func _title() -> String:
	return container.slot_title(key) if container else ""


func _set_hover(on: bool) -> void:
	_hovering = on
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and container:
		container.toggle_slot(key)
		accept_event()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var open := is_open()
	var color := container.slot_color(key) if container else BORDER_COLOR
	draw_rect(rect, BG_COLOR.lightened(0.04) if _hovering else BG_COLOR)
	draw_rect(Rect2(0, 0, size.x, STRIP_HEIGHT), color if open or _hovering else color.darkened(0.35))
	draw_rect(rect.grow(-0.5), color if open else BORDER_COLOR, false, 1.0)

	var line := TextLine.new()
	line.add_string(_title().to_upper(), get_theme_font("font", "Label"), font_size)
	line.width = size.x - 8.0
	line.alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var top := STRIP_HEIGHT + (size.y - STRIP_HEIGHT - line.get_size().y) * 0.5
	line.draw(get_canvas_item(), Vector2(4.0, top), TITLE_COLOR_OPEN if open or _hovering else TITLE_COLOR)
