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

@export var light_color := Color.YELLOW:
	set(lc):
		light_color = lc
		queue_redraw()

@export var light_texture : GradientTexture2D

@export var bg_color := Color("#333"):
	set(bg_c):
		bg_color = bg_c
		queue_redraw()

@export var border_color := Color("#333"):
	set(b_c):
		border_color = b_c
		queue_redraw()

var _value := false

@export var value := false:
	set(value):
		if _value != value:
			_value = value
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

func _draw() -> void:
	var center = Vector2(radius, radius)
	
	var r = radius - 4
	
	# draw background
	draw_circle(center, r, bg_color, true, -1.0, true)
	draw_circle(center, r+1, border_color, false, 1, false)
	
	if value:
		draw_texture_rect(light_texture, Rect2(0, 0, size.x, size.y), false, Color.WHITE)
		# draw light
		#var l_c = light_color
		#if _hovering:
			#l_c = l_c.lightened(0.1)
		#draw_circle(center, r, l_c, true, -1.0, true)
		
		# draw shine
		#var shine_c = l_c.lightened(0.5)
		#shine_c.a = 0.1
		#draw_circle(center + Vector2(-1, -1), r - 2, shine_c, true, -1.0, true)
