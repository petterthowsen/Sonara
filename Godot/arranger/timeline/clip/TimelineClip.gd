# TimelineClip.gd
# Visual representation of a Clip on the timeline
class_name TimelineClip extends Control

# Signals
signal select_requested(clip_ui: TimelineClip, add_to_selection: bool)  # Request to select this clip; add_to_selection = shift held
signal clip_move_requested(clip_instance: TimelineClip, new_start_ticks: int)
signal drag_started(clip_ui: TimelineClip, clip_instance: ClipInstance)  # Drag between tracks initiated
signal drag_moved(clip_ui: TimelineClip, global_position: Vector2)  # Drag position update
signal drag_ended(clip_ui: TimelineClip, global_position: Vector2)  # Drag ended
signal context_menu_requested(clip_ui: TimelineClip, global_position: Vector2)

@onready var header: PanelContainer = $VBoxContainer/Header
@onready var label: Label = $VBoxContainer/Header/Label
@onready var clip_renderer: MidiclipRenderer = $VBoxContainer/ClipRenderer

# Data binding
var clip_instance: ClipInstance = null:  # The instance we're displaying
	set(ci):
		clip_instance = ci
		
		if is_inside_tree():
			clip_renderer.clip_instance = clip_instance

var timeline = null
var track_color: Color = Color.WHITE:
	set(tc):
		if track_color != tc:
			track_color = tc
			if clip_renderer:
				clip_renderer.note_color = track_color
				clip_renderer.note_color.v = max(0.5, track_color.v)
				clip_renderer.queue_redraw()

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
var resize_start_offset: int = 0  # Initial clip_offset when resize started
var resize_padding_added: int = 0  # Track total padding added during this resize
@export var resize_edge_size: float = 8.0  # pixel width of resize edge zones

# Exported StyleBoxes for different states
@export var style_normal: StyleBoxFlat = null
@export var style_hovered: StyleBoxFlat = null
@export var style_selected: StyleBoxFlat = null

func _ready() -> void:
	"""Connect to built-in hover signals."""
	focus_mode = Control.FOCUS_CLICK
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	
	clip_renderer.clip_instance = clip_instance
	clip_renderer.note_color = track_color
	clip_renderer.note_color.v = max(0.5, track_color.v)


func bind_to_clip_instance(inst: ClipInstance, tl, t_color: Color = Color.WHITE) -> void:
	"""Bind this UI element to a ClipInstance data object.

	Connects to clip signals for real-time updates, including progressive waveform
	loading notifications.
	"""
	# Disconnect from previous clip if necessary
	if clip_instance and clip_instance.clip:
		if clip_instance.clip.waveform_level_updated.is_connected(_on_clip_waveform_level_loaded):
			clip_instance.clip.waveform_level_updated.disconnect(_on_clip_waveform_level_loaded)

	clip_instance = inst
	timeline = tl
	track_color = t_color

	# Connect to waveform loading events for progressive rendering
	if clip_instance and clip_instance.clip:
		if not clip_instance.clip.waveform_level_updated.is_connected(_on_clip_waveform_level_loaded):
			clip_instance.clip.waveform_level_updated.connect(_on_clip_waveform_level_loaded)

	# Update UI from clip instance data
	if is_inside_tree():
		_update_from_clip_instance()


func _find_nearest_clip_left(reference_start: int = -1) -> int:
	"""Find the end position of the nearest clip to the left of this clip.
	Returns 0 if no clip is found.
	If reference_start is provided, uses it instead of the current clip position."""
	if not clip_instance or not clip_instance.track:
		return 0
	
	var ref_pos = reference_start if reference_start >= 0 else clip_instance.start_ticks
	var nearest_end = 0
	for other_instance in clip_instance.track.clip_instances:
		if other_instance == clip_instance:
			continue
		var other_end = other_instance.start_ticks + other_instance.duration_ticks
		if other_end <= ref_pos and other_end > nearest_end:
			nearest_end = other_end
	
	return nearest_end


func _find_nearest_clip_right(reference_end: int = -1) -> int:
	"""Find the start position of the nearest clip to the right of this clip.
	Returns a very large number if no clip is found.
	If reference_end is provided, uses it instead of the current clip end position."""
	if not clip_instance or not clip_instance.track:
		return 999999999
	
	var ref_pos = reference_end if reference_end >= 0 else (clip_instance.start_ticks + clip_instance.duration_ticks)
	var nearest_start = 999999999
	for other_instance in clip_instance.track.clip_instances:
		if other_instance == clip_instance:
			continue
		var other_start = other_instance.start_ticks
		if other_start >= ref_pos and other_start < nearest_start:
			nearest_start = other_start
	
	return nearest_start


func _on_clip_waveform_level_loaded(level: int, clip: Clip) -> void:
	"""Handle progressive waveform level loaded event.

	Called by Clip.waveform_level_updated signal when a new resolution level
	becomes available. Triggers renderer redraw to progressively display waveforms.

	Args:
		level: Resolution level index that just loaded
		clip: The Clip object that was updated
	"""
	print_rich("[color=green][TIMELINE_CLIP][/color] Waveform level %d loaded, queuing redraw" % level)
	clip_renderer.queue_redraw()


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
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			context_menu_requested.emit(self, get_global_mouse_position())
			accept_event()
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var local_pos = get_local_mouse_position()
				var edge = _get_edge_at_position(local_pos)

				if edge != "":
					# Start resize
					is_resizing = true
					resize_edge = edge
					resize_start_pos = get_global_mouse_position()
					resize_padding_added = 0  # Reset padding tracker
					if clip_instance:
						resize_start_ticks = clip_instance.start_ticks
						resize_start_duration = clip_instance.duration_ticks
						resize_start_offset = clip_instance.clip_offset
					accept_event()
				else:
					grab_focus()
					# Request selection with modifier awareness
					var additive = event.ctrl_pressed or event.meta_pressed or Input.is_action_pressed("ui_select")
					if event.shift_pressed and not additive:
						additive = true
					select_requested.emit(self, additive)
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
					if drag_activated and clip_instance:
						# Emit drag ended for both horizontal and cross-track drags
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
			# Resize from left: adjust start_ticks, duration, and clip_offset
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
			
			# Clamp to avoid collisions - find the nearest clip on the left
			# Use the original resize start position as reference
			var left_limit = _find_nearest_clip_left(resize_start_ticks)
			new_start_ticks = max(left_limit, new_start_ticks)
			
			# Recalculate duration after clamping
			new_duration = original_end_ticks - new_start_ticks
			new_duration = max(min_duration, new_duration)
			
			# Calculate how much we moved the left edge (accounting for any padding already added)
			var left_edge_delta = new_start_ticks - resize_start_ticks
			
			# Update clip_offset: skip the trimmed portion of the clip
			# If we moved right (+delta), we need to increase the offset to skip that content
			# Account for padding we've already added during this resize
			var new_clip_offset = resize_start_offset + left_edge_delta + resize_padding_added
			
			# Handle negative offset: add padding to the beginning of the clip
			if new_clip_offset < 0:
				var padding_needed = -new_clip_offset
				_add_padding_to_clip(padding_needed)
				resize_padding_added += padding_needed  # Track cumulative padding
				new_clip_offset = 0  # Reset offset after adding padding
			
			# Update clip instance (this will sync to engine via OSC)
			clip_instance.set_clip_offset(new_clip_offset)
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

			# Clamp to avoid collisions - find the nearest clip on the right
			# Use the original resize end position as reference
			var original_end = resize_start_ticks + resize_start_duration
			var right_limit = _find_nearest_clip_right(original_end)
			var max_duration = right_limit - resize_start_ticks
			new_duration = min(new_duration, max_duration)
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
			
			# Horizontal drag component
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

			# Emit move request - Timeline will handle collision detection for multi-clip selection
			clip_move_requested.emit(self, new_start_ticks)
			accept_event()


func _on_mouse_entered() -> void:
	"""Handle mouse entering the clip."""
	set_hovered(true)


func _on_mouse_exited() -> void:
	"""Handle mouse exiting the clip."""
	set_hovered(false)


func _add_padding_to_clip(padding_ticks: int) -> void:
	"""Add padding to the beginning of the clip by shifting all content forward.
	The caller is responsible for moving the ClipInstance backward on the timeline
	to keep the visual position of the content unchanged."""
	if not clip_instance or not clip_instance.clip:
		return
	
	var clip = clip_instance.clip
	
	if clip.type == Clip.ClipType.MIDI:
		print("[TimelineClip] Before padding: %d notes in clip %s" % [clip.midi_notes.size(), clip.id])
		for note in clip.midi_notes:
			print("[TimelineClip]   Note %d: start=%d" % [note.id, note.start_tick])
		
		# Shift all MIDI notes forward
		for note in clip.midi_notes:
			note.start_tick += padding_ticks
		
		# Increase clip content length
		clip.content_length_ticks += padding_ticks
		
		# Notify the clip that it has been modified (triggers update_note OSC calls)
		for note in clip.midi_notes:
			clip.update_midi_note(note)
		
		print("[TimelineClip] After padding: Added %d ticks to clip %s (new length: %d)" % 
			[padding_ticks, clip.id, clip.content_length_ticks])
		for note in clip.midi_notes:
			print("[TimelineClip]   Note %d: start=%d" % [note.id, note.start_tick])
	
	elif clip.type == Clip.ClipType.AUDIO:
		# For audio clips, we'd need to prepend silence samples
		# This is more complex and requires reprocessing waveforms
		# For now, we'll just prevent negative offsets for audio clips
		push_warning("[TimelineClip] Audio clip padding not yet implemented - clamping to 0")
		# TODO: Implement audio padding by prepending silence samples
