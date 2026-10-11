# KeyChangeItem.gd
# One key change on the lane: a tab at its tick labeled e.g. "D Dorian" with a small ▾ arrow
# that opens the scale dropdown. Drag it along bar lines, right-click for the menu, double-click
# opens the dropdown too (there is no text editing here, unlike the time signature tab). It only
# reports gestures; `KeyChangeTrack` applies them to the map and records undo.
class_name KeyChangeItem extends Control

signal pressed(change_id: int)
signal dragged(change_id: int, track_x: float)
signal released(change_id: int)
signal menu_requested(change_id: int, global_pos: Vector2)
signal dropdown_requested(change_id: int, global_pos: Vector2)

const TAB_COLOR := Color("#b48ead")
const MIN_WIDTH := 62.0
const FONT_SIZE := 14
const ARROW_WIDTH := 14.0
const DRAG_THRESHOLD := 4.0

var change_id: int = -1
var text: String = ""

var _pressing := false
var _press_x := 0.0
var _drag_active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func set_key(id: int, root: int, type_id: String) -> void:
	change_id = id
	text = MusicalScale.make(root, type_id).display_name()
	var font := get_theme_default_font()
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + 18.0 + ARROW_WIDTH
	custom_minimum_size.x = maxf(MIN_WIDTH, width)
	size.x = custom_minimum_size.x
	tooltip_text = "Key change: %s" % text
	queue_redraw()


func is_editing() -> bool:
	return false


## Rect of the ▾ arrow (right edge), in item coordinates.
func arrow_rect() -> Rect2:
	return Rect2(size.x - ARROW_WIDTH - 4.0, 0.0, ARROW_WIDTH, size.y)


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(TAB_COLOR, 0.85))
	draw_rect(Rect2(0, 0, 2, size.y), TAB_COLOR)
	var font := get_theme_default_font()
	var text_color := Color.BLACK
	var text_width := size.x - ARROW_WIDTH - 6.0
	draw_string(font, Vector2(7, size.y * 0.5 + 5.0), text, HORIZONTAL_ALIGNMENT_LEFT, text_width, FONT_SIZE, text_color)
	# ▾ centered in its rect.
	var a := arrow_rect()
	var cx := a.position.x + a.size.x * 0.5
	var cy := size.y * 0.5
	draw_colored_polygon(PackedVector2Array([Vector2(cx - 4, cy - 2.5), Vector2(cx + 4, cy - 2.5), Vector2(cx, cy + 3.5)]), text_color)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.double_click:
					dropdown_requested.emit(change_id, get_global_mouse_position())
				elif arrow_rect().has_point(event.position):
					dropdown_requested.emit(change_id, get_global_mouse_position())
				else:
					_pressing = true
					_drag_active = false
					_press_x = event.global_position.x
					pressed.emit(change_id)
			elif _pressing:
				_pressing = false
				if _drag_active:
					released.emit(change_id)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			menu_requested.emit(change_id, event.global_position)
			accept_event()
	elif event is InputEventMouseMotion and _pressing:
		if not _drag_active and absf(event.global_position.x - _press_x) < DRAG_THRESHOLD:
			return
		_drag_active = true
		dragged.emit(change_id, position.x + event.position.x)
		accept_event()
