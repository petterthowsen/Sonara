@tool
class_name DeviceLightButton extends Control

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

@export var light_color_inactive_disabled := Color.DARK_RED:
	set(c):
		light_color_inactive_disabled = c
		queue_redraw()

@export var light_color_inactive_enabled := Color.RED:
	set(c):
		light_color_inactive_enabled = c
		queue_redraw()

@export var light_color_active_disabled := Color.DARK_ORANGE:
	set(c):
		light_color_active_disabled = c
		queue_redraw()

@export var light_color_active_enabled := Color.ORANGE:
	set(c):
		light_color_active_enabled = c
		queue_redraw()

@export var light_texture : GradientTexture2D

@export var bg_color := Color("#333"):
	set(bg_c):
		bg_color = bg_c
		queue_redraw()

@export var border_color_inactive := Color("#333"):
	set(b_c):
		border_color_inactive = b_c
		queue_redraw()

@export var border_color_active := Color("#555"):
	set(b_c):
		border_color_active = b_c
		queue_redraw()

@export var border_thickness: float = 1.0:
	set(b_t):
		border_thickness = b_t
		queue_redraw()

@export var test_active := false:
	set(t_a):
		test_active = t_a
		queue_redraw()

@export var test_enabled := false:
	set(t_e):
		test_enabled = t_e
		queue_redraw()

@export var tooltip_text_inactive_disabled := "Disabled & Inactive (Saving RAM. Ctrl-click to activate)":
	set(t_t):
		tooltip_text_inactive_disabled = t_t
		queue_redraw()

@export var tooltip_text_inactive_enabled := "Enabled, but inactive (Saving RAM. Ctrl-click to activate)":
	set(t_t):
		tooltip_text_inactive_enabled = t_t
		queue_redraw()

@export var tooltip_text_active_disabled := "Disabled (Bypassing Only. Ctrl-click to deactivate and save RAM)":
	set(t_t):
		tooltip_text_active_disabled = t_t
		queue_redraw()

@export var tooltip_text_active_enabled := "Enabled (Audio is processed. Ctrl-click to deactivate and save RAM)":
	set(t_t):
		tooltip_text_active_enabled = t_t
		queue_redraw()

var device_instance : DeviceInstance

var active : bool:
	get:
		if Engine.is_editor_hint():
			return test_active
		else:
			return device_instance.active

var enabled : bool:
	get:
		if Engine.is_editor_hint():
			return test_enabled
		else:
			return device_instance.enabled

var _hovering := false

func _get_minimum_size() -> Vector2:
	return Vector2(diameter, diameter)

func bind_to_device_instance(dev_inst : DeviceInstance):
	device_instance = dev_inst
	device_instance.enabled_changed.connect(_on_device_enabled_changed)
	device_instance.active_changed.connect(_on_device_active_changed)

func _on_device_enabled_changed(_enabled : bool):
	queue_redraw()
	_update_tooltip()

func _on_device_active_changed(_active : bool):
	queue_redraw()
	_update_tooltip()

func _update_tooltip() -> void:
	if not active and not enabled:
		tooltip_text = tooltip_text_inactive_disabled
	elif not active and enabled:
		tooltip_text = tooltip_text_inactive_enabled
	elif active and not enabled:
		tooltip_text = tooltip_text_active_disabled
	elif active and enabled:
		tooltip_text = tooltip_text_active_enabled
	else:
		tooltip_text = ""

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
			if event.ctrl_pressed or event.shift_pressed:
				# toggle active/inactive
				device_instance.set_active(!device_instance.active)
			else:
				# toggle enabled/disabled
				device_instance.set_enabled(!device_instance.enabled)
			accept_event()

func _draw() -> void:
	var center = Vector2(radius, radius)
	var r = radius - 4
	
	# Determine colors based on state
	var border_color = border_color_active if active else border_color_inactive
	
	var light_color : Color
	if not active and not enabled:
		light_color = light_color_inactive_disabled
	elif not active and enabled:
		light_color = light_color_inactive_enabled
	elif active and not enabled:
		light_color = light_color_active_disabled
	elif active and enabled:
		light_color = light_color_active_enabled
	else:
		light_color = Color.HOT_PINK
	
	# Draw background
	draw_circle(center, r, bg_color, true, -1.0, true)
	draw_circle(center, r+1, border_color, false, border_thickness, true)
	
	draw_texture_rect(light_texture, Rect2(0, 0, size.x, size.y), false, light_color)
