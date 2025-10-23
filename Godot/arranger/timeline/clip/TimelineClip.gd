# TimelineClip.gd
# Visual representation of a Clip on the timeline
class_name TimelineClip extends Control

# Signals
signal select_requested(clip_ui: TimelineClip, add_to_selection: bool)  # Request to select this clip; add_to_selection = shift held
signal clip_move_requested(clip_instance: TimelineClip, new_start_ticks: int)
signal drag_started(clip_ui: TimelineClip, clip_instance: ClipInstance)  # Drag between tracks initiated
signal drag_moved(clip_ui: TimelineClip, global_position: Vector2)  # Drag position update
signal drag_ended(clip_ui: TimelineClip, global_position: Vector2)  # Drag ended

@onready var header: PanelContainer = $VBoxContainer/Header
@onready var label: Label = $VBoxContainer/Header/Label
@onready var clip_renderer: MidiclipRenderer = $VBoxContainer/ClipRenderer

# Data binding
var clip_instance: ClipInstance = null:  # The instance we're displaying
	set(ci):
		clip_instance = ci
		clip_renderer.clip_instance = clip_instance

var timeline: Timeline = null
var track_color: Color = Color.WHITE

# Selection and hover state
var is_selected: bool = false
var is_hovered: bool = false

# Drag state
var is_dragging: bool = false
var drag_start_pos: Vector2 = Vector2.ZERO
var drag_start_ticks: int = 0
var drag_threshold: float = 10.0  # pixels before drag activates
var drag_activated: bool = false  # true when threshold crossed
var is_cross_track_drag: bool = false  # true if dragging vertically between tracks

# Resize state
var is_resizing: bool = false
var resize_edge: String = ""  # "left" or "right"
var resize_start_pos: Vector2 = Vector2.ZERO
var resize_start_ticks: int = 0
var resize_start_duration: int = 0
@export var resize_edge_size: float = 8.0  # pixel width of resize edge zones

# Exported StyleBoxes for different states
@export var style_normal: StyleBoxFlat = null
@export var style_hovered: StyleBoxFlat = null
@export var style_selected: StyleBoxFlat = null

func _ready() -> void:
	"""Connect to built-in hover signals."""
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func bind_to_clip_instance(inst: ClipInstance, tl: Timeline, t_color: Color = Color.WHITE) -> void:
	"""Bind this UI element to a ClipInstance data object."""
	clip_instance = inst
	timeline = tl
	track_color = t_color

	# Update UI from clip instance data
	_update_from_clip_instance()

func set_selected(selected: bool) -> void:
	"""Set selection state and update visual."""
	if is_selected == selected:
		return  # No change

	is_selected = selected
	_update_style()

func set_hovered(hovered: bool) -> void:
	"""Set hover state and update visual."""
	if is_hovered == hovered:
		return  # No change

	is_hovered = hovered
	_update_style()

func _update_from_clip_instance() -> void:
	"""Update all UI elements from clip instance data."""
	if clip_instance == null or timeline == null:
		return

	# Update label (use clip name if available)
	if clip_instance.clip:
		label.text = clip_instance.clip.name
	else:
		label.text = "Clip Instance"

	# Update position and size based on instance timing
	var start_x = timeline.ticks_to_pixels(clip_instance.start_ticks)
	var width = timeline.ticks_to_pixels(clip_instance.duration_ticks)

	position.x = start_x
	custom_minimum_size.x = width
	size.x = width

	# Apply initial style
	_update_style()


func _draw() -> void:
	"""Draw the stylebox manually."""
	var style := _get_current_style()
	style.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))


func _get_current_style() -> StyleBoxFlat:
	"""Get the appropriate StyleBox based on state priority: selected > hovered > normal."""
	# Priority: selected takes precedence, then hovered, then normal
	if is_selected and style_selected:
		return style_selected
	elif is_hovered and style_hovered:
		return style_hovered
	elif style_normal:
		return style_normal
	return null


func _update_style() -> void:
	"""Trigger redraw to update visual appearance."""
	queue_redraw()

# ============================================================================
# RESIZE HELPERS
# ============================================================================

func _get_edge_at_position(local_pos: Vector2) -> String:
	"""Check if position is within an edge zone. Returns 'left', 'right', or ''."""
	if local_pos.x <= resize_edge_size:
		return "left"
	elif local_pos.x >= size.x - resize_edge_size:
		return "right"
	return ""


func _update_cursor_for_position(local_pos: Vector2) -> void:
	"""Update cursor based on position within the clip."""
	if is_resizing:
		# Keep resize cursor during active resize
		mouse_default_cursor_shape = CURSOR_HSIZE
	else:
		var edge = _get_edge_at_position(local_pos)
		if edge != "":
			mouse_default_cursor_shape = CURSOR_HSIZE
		else:
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


# ============================================================================
# INPUT HANDLING
# ============================================================================
func _gui_input(event: InputEvent) -> void:
	"""Handle mouse input for selection, dragging, and resizing."""
	# Update cursor based on mouse position
	if event is InputEventMouseMotion:
		var local_pos = get_local_mouse_position()
		_update_cursor_for_position(local_pos)

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var local_pos = get_local_mouse_position()
				var edge = _get_edge_at_position(local_pos)

				if edge != "":
					# Start resize
					is_resizing = true
					resize_edge = edge
					resize_start_pos = get_global_mouse_position()
					if clip_instance:
						resize_start_ticks = clip_instance.start_ticks
						resize_start_duration = clip_instance.duration_ticks
					accept_event()
				else:
					# Request selection with shift-key awareness
					var add_to_selection = Input.is_action_pressed("ui_select")
					if event is InputEventMouseButton:
						add_to_selection = event.shift_pressed
					select_requested.emit(self, add_to_selection)
					# Prepare for drag (don't start yet - wait for threshold)
					is_dragging = true
					drag_activated = false
					is_cross_track_drag = false
					drag_start_pos = get_global_mouse_position()
					if clip_instance:
						drag_start_ticks = clip_instance.start_ticks
					accept_event()
			else:
				# End resize or drag
				if is_resizing:
					is_resizing = false
					resize_edge = ""
					accept_event()
				elif is_dragging:
					if is_cross_track_drag and clip_instance:
						# Emit drag ended for cross-track moves
						drag_ended.emit(self, get_global_mouse_position())
					is_dragging = false
					drag_activated = false
					is_cross_track_drag = false
					accept_event()

	elif event is InputEventMouseMotion and is_resizing and clip_instance and timeline:
		# Handle resize dragging
		var mouse_pos = get_global_mouse_position()
		var pixel_delta = (mouse_pos - resize_start_pos).x
		var tick_delta = timeline.pixels_to_ticks(pixel_delta)

		if resize_edge == "left":
			# Resize from left: adjust start_ticks and duration
			var new_start_ticks = resize_start_ticks + tick_delta

			# Snap to grid
			var snap_interval = timeline.get_snap_interval()
			if snap_interval > 0:
				@warning_ignore("integer_division")
				new_start_ticks = (new_start_ticks / snap_interval) * snap_interval

			# Clamp to positive values
			new_start_ticks = max(0, new_start_ticks)

			# Calculate new duration (original end point stays fixed)
			var original_end_ticks = resize_start_ticks + resize_start_duration
			var new_duration = original_end_ticks - new_start_ticks

			# Minimum duration of 1 snap interval (or 1 tick if no snap)
			var min_duration = snap_interval if snap_interval > 0 else 1
			new_duration = max(min_duration, new_duration)

			# Update clip instance
			clip_instance.set_position(new_start_ticks)
			clip_instance.set_duration(new_duration)
			_update_from_clip_instance()

		elif resize_edge == "right":
			# Resize from right: adjust duration only
			var new_duration = resize_start_duration + tick_delta

			# Snap to grid (snap the end point)
			var snap_interval = timeline.get_snap_interval()
			if snap_interval > 0:
				var new_end_ticks = resize_start_ticks + new_duration
				@warning_ignore("integer_division")
				new_end_ticks = (new_end_ticks / snap_interval) * snap_interval
				new_duration = new_end_ticks - resize_start_ticks

			# Minimum duration of 1 snap interval (or 1 tick if no snap)
			var min_duration = snap_interval if snap_interval > 0 else 1
			new_duration = max(min_duration, new_duration)

			# Update clip instance
			clip_instance.set_duration(new_duration)
			_update_from_clip_instance()

		accept_event()

	elif event is InputEventMouseMotion and is_dragging and clip_instance and timeline:
		var mouse_pos = get_global_mouse_position()
		var mouse_delta = mouse_pos - drag_start_pos
		var delta_magnitude = mouse_delta.length()

		# Check if drag threshold crossed
		if not drag_activated and delta_magnitude > drag_threshold:
			# Determine drag type based on dominant axis
			is_cross_track_drag = abs(mouse_delta.y) > abs(mouse_delta.x)
			drag_activated = true

			if is_cross_track_drag:
				# Cross-track drag: emit drag_started
				drag_started.emit(self, clip_instance)
				accept_event()

		# Handle active drag
		if drag_activated:
			if is_cross_track_drag:
				# Cross-track drag: emit position updates
				drag_moved.emit(self, mouse_pos)
				accept_event()
			else:
				# Horizontal drag: reposition within track
				var pixel_delta = mouse_delta.x
				var tick_delta = timeline.pixels_to_ticks(pixel_delta)
				var new_start_ticks = drag_start_ticks + tick_delta

				# Snap to grid
				var snap_interval = timeline.get_snap_interval()
				if snap_interval > 0:
					@warning_ignore("integer_division")
					new_start_ticks = (new_start_ticks / snap_interval) * snap_interval

				# Clamp to positive values
				new_start_ticks = max(0, new_start_ticks)

				# Emit move request
				clip_move_requested.emit(self, new_start_ticks)
				accept_event()


func _on_mouse_entered() -> void:
	"""Handle mouse entering the clip."""
	set_hovered(true)


func _on_mouse_exited() -> void:
	"""Handle mouse exiting the clip."""
	set_hovered(false)
