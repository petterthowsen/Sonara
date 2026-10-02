## A toggle button that flips on press and can be "painted" across its neighbours.
## Press one, keep the mouse down and sweep over other `drag_region`s in the same
## `drag_group`: each button there is set to the state the first press produced.
## Shift+press toggles this button and clears every other button of the group
## (solo one track, mute one track and unmute the rest).
## Used for mute/solo in the arranger track list and the mixer.
class_name DragToggleButton extends Button

## Buttons with the same group paint each other (e.g. "mute", "solo").
@export var drag_group: StringName = &""
## The area that counts as "over this button" while painting, e.g. the whole track
## item or mixer strip. Defaults to the button itself.
@export var drag_region: Control

var _painting := false
var _paint_value := false
var _last_mouse := Vector2.ZERO


func _init() -> void:
	toggle_mode = true
	action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS


func _ready() -> void:
	if drag_group != &"":
		add_to_group(_group_name())


func _group_name() -> String:
	return "drag_toggle_" + String(drag_group)


func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and event.shift_pressed and drag_group != &"":
			_painting = false
			_clear_others()
		elif event.pressed:
			_painting = drag_group != &""
			_paint_value = not button_pressed  # the state this press is about to produce
			_last_mouse = get_global_mouse_position()
		else:
			_painting = false
	elif event is InputEventMouseMotion and _painting:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_painting = false  # the release was lost (focus change)
			return
		_paint_to(get_global_mouse_position())


## Unlike painting this includes hidden buttons (e.g. the mixer's twin of a track),
## so every view of every channel ends up consistent.
func _clear_others() -> void:
	for node in get_tree().get_nodes_in_group(_group_name()):
		var other := node as DragToggleButton
		if other != null and other != self and other.button_pressed:
			other.button_pressed = false


## Applies the paint value to every other button whose region the pointer crossed
## since the last motion event (a segment, so fast sweeps do not skip items).
func _paint_to(mouse: Vector2) -> void:
	var swept := Rect2(_last_mouse, Vector2.ZERO).expand(mouse).grow(1.0)
	_last_mouse = mouse
	for node in get_tree().get_nodes_in_group(_group_name()):
		var other := node as DragToggleButton
		if other == null or other == self or other.disabled or not other.is_visible_in_tree():
			continue
		if other.button_pressed != _paint_value and other._region().get_global_rect().intersects(swept):
			other.button_pressed = _paint_value  # emits toggled like a click


func _region() -> Control:
	return drag_region if is_instance_valid(drag_region) else self
