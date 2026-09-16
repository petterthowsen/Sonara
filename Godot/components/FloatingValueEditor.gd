## Floating LineEdit for double-click-to-edit value controls (RotaryKnob, Volumeter, Meter, VSlider).
## Enter commits; Escape or a click outside the editor cancels. Frees itself when done.
class_name FloatingValueEditor extends LineEdit

signal committed(text: String)
signal cancelled

var _done := false


func _ready() -> void:
	top_level = true
	z_index = 128
	select_all_on_focus = true
	text_submitted.connect(_on_text_submitted)
	focus_exited.connect(_on_focus_exited)


## Show the editor at `pos` (global) sized to `editor_size`, prefilled with `initial_text`.
func open(initial_text: String, pos: Vector2, editor_size: Vector2) -> void:
	text = initial_text
	global_position = pos
	size = editor_size
	visible = true
	grab_focus.call_deferred()
	select_all.call_deferred()


## Global position for an `box_size`-sized box centered above `control`, clamped to the viewport.
static func position_above(control: Control, box_size: Vector2) -> Vector2:
	var top_center := control.global_position + Vector2(control.size.x * 0.5, 0.0)
	var pos := top_center - Vector2(box_size.x * 0.5, box_size.y + 4.0)
	if pos.y < 0.0:
		pos.y = control.global_position.y + control.size.y + 4.0
	var view_size := control.get_viewport_rect().size
	pos.x = clampf(pos.x, 0.0, maxf(view_size.x - box_size.x, 0.0))
	return pos


func _input(event: InputEvent) -> void:
	if _done or not visible:
		return
	if event is InputEventMouseButton and event.pressed:
		if not get_global_rect().has_point(event.global_position):
			_cancel()


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		accept_event()
		_cancel()


func _on_text_submitted(new_text: String) -> void:
	if _done:
		return
	_done = true
	committed.emit(new_text)
	queue_free()


func _on_focus_exited() -> void:
	if _done:
		return
	_cancel()


func _cancel() -> void:
	_done = true
	cancelled.emit()
	queue_free()
