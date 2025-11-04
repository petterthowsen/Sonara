@tool
class_name EnvelopeControl extends Control

# ========================================================
# Styling properties
# ========================================================

@export var bg_color := Color.BLACK:
	set(c):
		bg_color = c
		if is_inside_tree():
			queue_redraw()

@export var line_color := Color.WHITE:
	set(c):
		line_color = c
		if is_inside_tree():
			queue_redraw()

@export var line_width := 2.0:
	set(w):
		line_width = w
		queue_redraw()
	
@export var grid_color := Color.GRAY:
	set(c):
		grid_color = c
		queue_redraw()

@export var grid_width := 1.0:
	set(w):
		grid_width = w
		queue_redraw()

@export var handle_color := Color.LIGHT_GRAY:
	set(c):
		handle_color = c
		queue_redraw()

@export var handle_color_hover := Color.WHITE:
	set(c):
		handle_color_hover = c
		queue_redraw()

@export var handle_radius := 8.0:
	set(r):
		handle_radius = r
		queue_redraw()

@export var envelope: Envelope:
	set(value):
		if envelope != value:
			if envelope != null:
				envelope.changed.disconnect(queue_redraw)
			if envelope != null:
				envelope.changed.connect(queue_redraw)
			envelope = value
			queue_redraw()

@export var attack_enabled := true
@export var decay_enabled := true
@export var sustain_enabled := true
@export var release_enabled := true

func _ready() -> void:
	if envelope and not envelope.changed.is_connected(queue_redraw):
		envelope.changed.connect(queue_redraw)

func _get_minimum_size() -> Vector2:
	return Vector2(100, 30)


func pixel_to_secoonds(pixels : float) -> float:
	var pixels_per_second = size.x / get_duration()
	return pixels / pixels_per_second


func seconds_to_pixels(seconds : float) -> float:
	var pixels_per_second = size.x / get_duration()
	return seconds * pixels_per_second


func get_duration() -> float:
	# the total maximum length of the envelope in seconds
	var duration = 0.0
	if attack_enabled:
		duration += envelope.max_attack
	
	if decay_enabled:
		duration += envelope.max_decay
	
	if release_enabled:
		duration += envelope.max_release
	
	return duration

func get_attack_length_seconds() -> float:
	# attack and release get 33% of the total width each
	return get_duration() * 0.33

func get_attack_length_pixels() -> float:
	return seconds_to_pixels(get_attack_length_seconds())

func get_decay_length_seconds() -> float:
	# decay gets 33% of the total width
	return get_duration() * 0.33

func get_decay_length_pixels() -> float:
	return seconds_to_pixels(get_decay_length_seconds())

func get_release_length_seconds() -> float:
	# release gets 33% of the total width
	return get_duration() * 0.33

func get_release_length_pixels() -> float:
	return seconds_to_pixels(get_release_length_seconds())


func get_attack_area() -> Rect2:
	return Rect2(0, 0, get_attack_length_pixels(), size.y)


func get_decay_sustain_area() -> Rect2:
	return Rect2(get_attack_length_pixels(), 0, get_decay_length_pixels(), size.y)


func get_release_area() -> Rect2:
	return Rect2(get_attack_length_pixels() + get_decay_length_pixels(), 0, get_release_length_pixels(), size.y)


func get_attack_handle_pos() -> Vector2:
	var attack_area = get_attack_area()
	return Vector2(envelope.attack_normalized * attack_area.end.x, 0)


func get_decay_handle_pos() -> Vector2:
	var decay_area = get_decay_sustain_area()
	var y = size.y - (size.y * envelope.sustain)
	return Vector2(decay_area.position.x + (envelope.decay_normalized * decay_area.size.x), y)


func get_release_handle_pos() -> Vector2:
	var release_area = get_release_area()
	var y = size.y - (size.y * envelope.sustain)
	return Vector2(release_area.end.x - (envelope.release_normalized * release_area.size.x), y)

func _is_mouse_in_handle(handle : Vector2, threshold: float = handle_radius) -> bool:
	return handle.distance_to(get_local_mouse_position()) < threshold

enum DragType {NONE, ATTACK, DECAY, RELEASE}

var drag_type: DragType = DragType.NONE

var is_dragging: bool:
	get:
		return drag_type != DragType.NONE

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if not is_dragging and event.pressed:
				var attack_handle = get_attack_handle_pos()
				var decay_handle = get_decay_handle_pos()
				var release_handle = get_release_handle_pos()

				if _is_mouse_in_handle(attack_handle, handle_radius * 2):
					drag_type = DragType.ATTACK
				elif _is_mouse_in_handle(decay_handle, handle_radius * 2):
					drag_type = DragType.DECAY
				elif _is_mouse_in_handle(release_handle, handle_radius * 2):
					drag_type = DragType.RELEASE
				else:
					drag_type = DragType.NONE
			elif is_dragging and event.is_released():
				_stop_drag()
	elif event is InputEventMouseMotion:
		if is_dragging:
			_drag(event.position)
		queue_redraw()


func _start_drag(dt: DragType) -> void:
	drag_type = dt
	accept_event()

func _stop_drag() -> void:
	drag_type = DragType.NONE
	accept_event()

func _drag(mouse: Vector2) -> void:
	match drag_type:
		DragType.ATTACK:
			var attack_area = get_attack_area()
			mouse.x = clamp(mouse.x, attack_area.position.x, attack_area.end.x)
			mouse.y = 0

			envelope.attack_normalized = remap(mouse.x, attack_area.position.x, attack_area.end.x, 0, 1)
		
		DragType.DECAY:
			var decay_area = get_decay_sustain_area()
			mouse.x = clamp(mouse.x, decay_area.position.x, decay_area.end.x)
			mouse.y = clamp(mouse.y, 0, size.y)

			envelope.decay_normalized = remap(mouse.x, decay_area.position.x, decay_area.end.x, 0, 1)
			envelope.sustain = remap(mouse.y, 0, size.y, 1, 0)
		
		DragType.RELEASE:
			var release_area = get_release_area()
			mouse.x = clamp(mouse.x, release_area.position.x, release_area.end.x)
			mouse.y = clamp(mouse.y, 0, size.y)

			envelope.release_normalized = remap(mouse.x, release_area.position.x, release_area.end.x, 1, 0)
			envelope.sustain = remap(mouse.y, 0, size.y, 1, 0)
		_:
			pass


func _draw() -> void:
	# draw the background
	draw_rect(Rect2(0, 0, size.x, size.y), bg_color, true, -1.0, true)
	
	# draw grid lines every second
	for i in range(1, floor(get_duration())):
		var x = seconds_to_pixels(i)
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color, grid_width, true)

	
	# draw the envelope line
	var points = [
		Vector2(0, size.y),
		get_attack_handle_pos(),
		get_decay_handle_pos(),
		get_release_handle_pos(),
		Vector2(size.x, size.y),
	]
	draw_polyline(points, line_color, line_width, true if line_width >= 1.0 else false)

	var attack_handle = get_attack_handle_pos()
	var decay_handle = get_decay_handle_pos()
	var release_handle = get_release_handle_pos()

	# attack attack handle
	if _is_mouse_in_handle(attack_handle):
		_draw_handle(attack_handle, handle_color_hover)
	else:
		_draw_handle(attack_handle, handle_color)

	# decay handle
	if _is_mouse_in_handle(decay_handle):
		_draw_handle(decay_handle, handle_color_hover)
	else:
		_draw_handle(decay_handle, handle_color)

	# release handle
	if _is_mouse_in_handle(release_handle):
		_draw_handle(release_handle, handle_color_hover)
	else:
		_draw_handle(release_handle, handle_color)


func _draw_handle(pos: Vector2, color: Color) -> void:
	draw_circle(pos, handle_radius, color, true, -1.0, true)
