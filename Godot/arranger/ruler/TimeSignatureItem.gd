# TimeSignatureItem.gd
# One time signature change on the lane: a tab at its bar line labeled "N/D". Drag it along bar
# lines, double-click to edit the text in place, right-click for the menu. It only reports
# gestures; `TimeSignatureTrack` applies them to the map and records undo.
class_name TimeSignatureItem extends Control

signal pressed(change_id: int)
signal dragged(change_id: int, track_x: float)
signal released(change_id: int)
signal edit_committed(change_id: int, text: String)
signal menu_requested(change_id: int, global_pos: Vector2)

const TAB_COLOR := Color("#4aa3a3")
const MIN_WIDTH := 50.0
const FONT_SIZE := 14
const DRAG_THRESHOLD := 4.0

var change_id: int = -1
var text: String = ""

var _edit: LineEdit = null
var _pressing := false
var _press_x := 0.0
var _drag_active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func set_signature(id: int, numerator: int, denominator: int) -> void:
	change_id = id
	text = "%d/%d" % [numerator, denominator]
	var font := get_theme_default_font()
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + 18.0
	custom_minimum_size.x = maxf(MIN_WIDTH, width)
	size.x = custom_minimum_size.x
	tooltip_text = "Time signature %s" % text
	queue_redraw()


func is_editing() -> bool:
	return _edit != null


func begin_edit() -> void:
	if _edit != null:
		return
	_edit = LineEdit.new()
	_edit.text = text
	_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_edit.add_theme_font_size_override("font_size", FONT_SIZE)
	# The default LineEdit style is taller than the lane; use a tight flat box instead.
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.08, 0.08, 0.08)
	box.set_content_margin_all(0)
	box.content_margin_left = 4
	box.content_margin_right = 4
	for style_name in ["normal", "focus"]:
		_edit.add_theme_stylebox_override(style_name, box)
	_edit.custom_minimum_size = Vector2.ZERO
	_edit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_edit.text_submitted.connect(_on_edit_submitted)
	_edit.focus_exited.connect(_end_edit)
	_edit.gui_input.connect(_on_edit_gui_input)
	add_child(_edit)
	_edit.grab_focus()
	_edit.select_all()


func _on_edit_submitted(new_text: String) -> void:
	var id := change_id
	_end_edit()
	edit_committed.emit(id, new_text)


func _on_edit_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_end_edit()
		accept_event()


func _end_edit() -> void:
	if _edit == null:
		return
	var edit := _edit
	_edit = null
	edit.queue_free()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(TAB_COLOR, 0.85))
	draw_rect(Rect2(0, 0, 2, size.y), TAB_COLOR)
	if _edit == null:
		var font := get_theme_default_font()
		draw_string(font, Vector2(7, size.y * 0.5 + 5.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color.BLACK)


func _gui_input(event: InputEvent) -> void:
	if _edit != null:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.double_click:
					begin_edit()
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
