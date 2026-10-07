# A checkbox buttton that shows as a light
# Designed to be compact
@tool
class_name LightButton extends Control

@export var diameter : float = 20:
	set(d):
		diameter = d
		queue_redraw()

var radius:
	get:
		return diameter / 2
	set(r):
		diameter = r * 2
		queue_redraw()

var _tc := ThemedColors.new(self, &"LightButton")
var light_color: Color:
	get:
		return _tc.get_color(&"light")
	set(c):
		_tc.set_color(&"light", c)

@export var light_texture : GradientTexture2D

var bg_color: Color:
	get:
		return _tc.get_color(&"bg")
	set(c):
		_tc.set_color(&"bg", c)

var border_color: Color:
	get:
		return _tc.get_color(&"border")
	set(c):
		_tc.set_color(&"border", c)

var _value := false

@export var value := false:
	set(value):
		if _value != value:
			_value = value
			toggled.emit(value)
			queue_redraw()
	get:
		return _value

var _hovering := false

signal toggled(pressed : bool)

func set_value_no_signal(val : bool):
	if val != _value:
		_value = val
		queue_redraw()

func _get_minimum_size() -> Vector2:
	return Vector2(diameter, diameter)

func _ready() -> void:
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

func _on_mouse_entered():
	_hovering = true
	queue_redraw()

func _on_mouse_exited():
	_hovering = false
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			value = !value
			accept_event()

func _draw() -> void:
	var center = Vector2(radius, radius)
	
	var r = radius - 4
	
	# draw background
	draw_circle(center, r, bg_color, true, -1.0, true)
	draw_circle(center, r+1, border_color, false, 1, false)
	
	if value:
		draw_texture_rect(light_texture, Rect2(0, 0, size.x, size.y), false, Color.WHITE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_tc.refresh()
		queue_redraw()
