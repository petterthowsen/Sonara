@tool
class_name TimelineScrollBar extends Control

## Custom scrollbar for timeline with Bitwig-style behavior
## Draws a background and grabber, handles click and drag interactions


signal scroll_changed(value: float)


# Public timeline-specific properties
@export var song_length_ticks: int = 0:
	set(v):
		if song_length_ticks != v:
			song_length_ticks = v
			_update_internal_values()
			queue_redraw()


var grid_helper: GridHelper = null:
	set(v):
		# Disconnect from old grid_helper
		if grid_helper and grid_helper.changed.is_connected(_on_grid_helper_changed):
			grid_helper.changed.disconnect(_on_grid_helper_changed)

		grid_helper = v

		# Connect to new grid_helper to detect zoom/scroll changes
		if grid_helper:
			grid_helper.changed.connect(_on_grid_helper_changed)

		_update_internal_values()
		queue_redraw()


@export var viewport_width: float = 0.0:
	set(v):
		if viewport_width != v:
			viewport_width = v
			_update_internal_values()
			queue_redraw()


@export var scroll_position: float = 0.0:
	set(v):
		var old_value = _scroll_position
		_scroll_position = clamp(v, _min_value, _max_value) if not allow_greater else v
		if not allow_lesser:
			_scroll_position = max(_scroll_position, _min_value)
		if _scroll_position != old_value:
			scroll_changed.emit(_scroll_position)
			queue_redraw()
	get:
		return _scroll_position


@export var step: float = 1.0
@export var allow_greater: bool = true
@export var allow_lesser: bool = false


# Visual styling
@export var bg_color: Color = Color(0.15, 0.15, 0.15, 0.8)
@export var grabber_color: Color = Color(0.4, 0.4, 0.4, 1.0)
@export var grabber_hover_color: Color = Color(0.5, 0.5, 0.5, 1.0)
@export var grabber_pressed_color: Color = Color(0.6, 0.6, 0.6, 1.0)


# Private computed values
var _min_value: float = 0.0
var _max_value: float = 100.0
var _page: float = 10.0
var _scroll_position: float = 0.0  # Backing variable for scroll_position


# Interaction state
var _dragging: bool = false
var _drag_start_value: float = 0.0
var _drag_start_mouse_x: float = 0.0
var _hovering: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_update_internal_values()


func _on_grid_helper_changed() -> void:
	_update_internal_values()
	queue_redraw()


func _update_internal_values() -> void:
	## Compute internal scrollbar values from timeline properties
	_min_value = 0.0
	_page = viewport_width

	if grid_helper:
		# Use song length, or 4 bars minimum if no clips
		var ticks_to_use = song_length_ticks
		if ticks_to_use == 0:
			# Default to 4 bars when empty
			var ticks_per_bar = grid_helper.get_ticks_per_bar()
			ticks_to_use = ticks_per_bar * 4

		var song_length_pixels = grid_helper.ticks_to_pixels(ticks_to_use)
		_max_value = max(song_length_pixels, viewport_width)

		if randf() < 0.1:
			print("[TimelineScrollBar] Updated: ticks=", ticks_to_use, " (original=", song_length_ticks, ") pixels=", song_length_pixels, " max=", _max_value, " page=", _page)
	else:
		_max_value = viewport_width


func _get_effective_max() -> float:
	## Calculate effective maximum that expands dynamically for infinite scroll
	## The scrollable range should always include the current scroll position + viewport
	return max(_max_value, _scroll_position + _page)


func _draw() -> void:
	## Draw background and grabber
	var rect_size = size
	if randf() < 0.05:
		print("[TimelineScrollBar] _draw called - size: ", rect_size, " range: ", _max_value - _min_value, " scroll: ", _scroll_position)

	# Draw background
	draw_rect(Rect2(Vector2.ZERO, rect_size), bg_color, true)

	# Calculate grabber position and size using effective max (dynamic expansion for infinite scroll)
	var effective_max = _get_effective_max()
	var range = effective_max - _min_value
	if range <= 0:
		if randf() < 0.1:
			print("[TimelineScrollBar] _draw skipped - range is 0")
		return

	var grabber_width = (_page / range) * rect_size.x
	grabber_width = clamp(grabber_width, 20.0, rect_size.x)  # Min 20px grabber

	# Bitwig-style: position grabber based on scroll, but account for dynamic expansion
	# The grabber represents where you are in the total scrollable space
	var scroll_ratio = _scroll_position / (range - _page) if (range - _page) > 0 else 0.0
	var grabber_x = scroll_ratio * (rect_size.x - grabber_width)

	# Choose grabber color based on state
	var current_grabber_color = grabber_color
	if _dragging:
		current_grabber_color = grabber_pressed_color
	elif _hovering:
		current_grabber_color = grabber_hover_color

	# Draw grabber
	var grabber_rect = Rect2(Vector2(grabber_x, 0), Vector2(grabber_width, rect_size.y))
	draw_rect(grabber_rect, current_grabber_color, true)

	# Draw subtle border on grabber
	draw_rect(grabber_rect, Color(1, 1, 1, 0.1), false, 1.0)


func _gui_input(event: InputEvent) -> void:
	## Handle mouse clicks and dragging
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_start_drag(event.position.x)
			accept_event()
		else:
			_end_drag()
			accept_event()

	elif event is InputEventMouseMotion:
		if _dragging:
			_update_drag(event.position.x)
			accept_event()

		# Update hover state
		var grabber_rect = _get_grabber_rect()
		var was_hovering = _hovering
		_hovering = grabber_rect.has_point(event.position)
		if _hovering != was_hovering:
			queue_redraw()


func set_scroll_position_no_signal(new_value: float) -> void:
	## Set scroll position without emitting scroll_changed signal
	var clamped = clamp(new_value, _min_value, _max_value) if not allow_greater else new_value
	if not allow_lesser:
		clamped = max(clamped, _min_value)

	_scroll_position = clamped  # Set backing variable directly to bypass setter
	queue_redraw()  # Always redraw, even if value unchanged (grabber position may need update)


func _start_drag(mouse_x: float) -> void:
	## Start dragging from mouse position - always allow drag from anywhere
	_dragging = true
	_drag_start_value = _scroll_position
	_drag_start_mouse_x = mouse_x
	queue_redraw()


func _update_drag(mouse_x: float) -> void:
	## Update scroll value during drag
	var delta_x = mouse_x - _drag_start_mouse_x
	var effective_max = _get_effective_max()
	var range = effective_max - _min_value
	var grabber_width = (_page / range) * size.x
	grabber_width = clamp(grabber_width, 20.0, size.x)
	var usable_width = size.x - grabber_width

	# When grabber is full width, use a fixed scroll sensitivity
	if usable_width <= 1.0:
		# Map pixels to scroll units directly (1px = 1 unit of scroll)
		var delta_value = delta_x
		var new_value = _drag_start_value + delta_value

		# Apply step
		if step > 0:
			new_value = round(new_value / step) * step

		scroll_position = new_value
	else:
		var delta_value = (delta_x / usable_width) * range
		var new_value = _drag_start_value + delta_value

		# Apply step
		if step > 0:
			new_value = round(new_value / step) * step

		# Set value (will emit signal and redraw)
		scroll_position = new_value


func _end_drag() -> void:
	## End dragging interaction
	_dragging = false
	queue_redraw()


func _jump_to_position(mouse_x: float) -> void:
	## Jump scroll to clicked position
	var effective_max = _get_effective_max()
	var range = effective_max - _min_value
	var grabber_width = (_page / range) * size.x
	grabber_width = clamp(grabber_width, 20.0, size.x)

	# Calculate target position (center grabber on click)
	var target_x = mouse_x - (grabber_width * 0.5)
	var usable_width = size.x - grabber_width

	if usable_width > 0:
		var ratio = clamp(target_x / usable_width, 0.0, 1.0)
		var new_value = _min_value + (ratio * range)

		# Apply step
		if step > 0:
			new_value = round(new_value / step) * step

		scroll_position = new_value


func _get_grabber_rect() -> Rect2:
	## Calculate current grabber rectangle
	var effective_max = _get_effective_max()
	var range = effective_max - _min_value
	if range <= 0:
		return Rect2()

	var grabber_width = (_page / range) * size.x
	grabber_width = clamp(grabber_width, 20.0, size.x)

	# Bitwig-style: position grabber based on scroll, but account for dynamic expansion
	var scroll_ratio = _scroll_position / (range - _page) if (range - _page) > 0 else 0.0
	var grabber_x = scroll_ratio * (size.x - grabber_width)

	return Rect2(Vector2(grabber_x, 0), Vector2(grabber_width, size.y))


func _on_mouse_entered() -> void:
	## Update hover state on mouse enter
	_hovering = true
	queue_redraw()


func _on_mouse_exited() -> void:
	## Update hover state on mouse exit
	_hovering = false
	queue_redraw()
