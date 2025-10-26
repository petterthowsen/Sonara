# Midi Editor
# 
# Composed of a VPiano (Vertical Piano keys) on the left side
# and NoteLanes, GridRenderer and layerreed NoteEditors on the right.
#
# designed to have a ScrollContainer with only vertical scroll enabled
# I.E VPiano, and notte_area nodes are as tall as the keyboard
#
# vertical zoom is handled by inc/dec the note lane/piano key heights in sync
#
# horizontal zoom supported by h_scroll but we handle it
# 
# handles input and delegates to note_editor(s) for multi-track note editing and selection
class_name MidiEditor extends ScrollContainer

var logger := Log.make("MidiEditor")

@onready var v_piano: VPiano = $HBox/VPiano
@onready var note_area: Control = $HBox/NoteArea
@onready var note_lanes: NoteLanes = $HBox/NoteArea/NoteLanes
@onready var grid_renderer: GridRenderer = $HBox/NoteArea/GridRenderer

@onready var h_scroll: ScrollContainer = $HBox/NoteArea/HScroll
@onready var note_editor: NoteEditor = $HBox/NoteArea/HScroll/NoteEditor

@onready var playhead: TextureRect = $HBox/NoteArea/Playhead

# overlays help render noteselection boundaries and selection box
@onready var overlays: MidiEditorOverlays = $HBox/NoteArea/Overlays

# Playhead position (in clip-local ticks)
var playhead_ticks: int = -1:
	set(value):
		playhead_ticks = value
		_update_playhead_position()

var grid_helper: GridHelper:
	set(gh):
		if grid_helper != gh:
			logger.info("grid_helper changed: ", gh)
			# Disconnect from old grid_helper if it exists
			if grid_helper and grid_helper.changed.is_connected(_on_grid_helper_changed):
				grid_helper.changed.disconnect(_on_grid_helper_changed)

			grid_helper = gh
			note_lanes.grid_helper = gh
			note_editor.grid_helper = gh
			grid_renderer.set_grid_helper(gh)

			# Connect to new grid_helper's changed signal
			if grid_helper:
				grid_helper.changed.connect(_on_grid_helper_changed)


# Local cursor position (in ticks) - propagated to NoteEditor
var cursor_position_ticks: int = 0:
	set(value):
		cursor_position_ticks = value
		note_editor.cursor_position_ticks = cursor_position_ticks


# note height: synced to v_piano, note_lanes and note_editor
var note_height_min := 8
var note_height_max := 40
@export var note_height := 20:
	set(nh):
		if note_height != nh:
			note_height = clamp(nh, note_height_min, note_height_max)
			if is_inside_tree():
				v_piano.key_height = note_height
				note_lanes.key_height = note_height
				note_editor.note_height = note_height

var scroll_speed_notes = 2

@export var scroll_speed_v : int:
	get:
		return scroll_speed_notes * note_height

@export var scroll_speed_h = 50

# Zoom sensitivity: multiplier for zoom speed (higher = faster zoom)
@export var zoom_sensitivity_h: float = 1.1  # Horizontal zoom multiplier per scroll tick
@export var zoom_sensitivity_v: int = 1      # Vertical zoom delta per scroll tick
@export var pan_zoom_sensitivity: float = 0.5  # Zoom factor per pixel of mouse movement when shift+panning (percentage)

# Smooth scrolling: 0 = instant, higher = smoother (0.1-0.3 recommended)
@export var scroll_smoothing: float = 0.2

# Target scroll positions for smooth scrolling
var target_scroll_vertical: float = 0.0
var target_scroll_horizontal: float = 0.0

# Middle mouse button panning state
var is_panning: bool = false
var pan_start_mouse_pos: Vector2 = Vector2.ZERO
var pan_start_scroll_v: float = 0.0
var pan_start_scroll_h: float = 0.0
var pan_start_pixels_per_beat: float = 0.0
var pan_start_h_scroll_mouse_pos: Vector2 = Vector2.ZERO  # Mouse pos relative to h_scroll when pan started

# The clip instance that opened this editor (for context, not edited directly)
var clip_instance: ClipInstance = null

# Convenience to get the Clip of clip_instance
var clip: Clip:
	get:
		return clip_instance.clip if clip_instance else null
	set(clip):
		pass

func _ready():
	# Initialize target scroll positions to current values
	target_scroll_vertical = scroll_vertical
	target_scroll_horizontal = h_scroll.scroll_horizontal
	v_piano.key_height = note_height
	note_lanes.key_height = note_height
	note_editor.note_height = note_height

func _process(delta: float):
	# Smooth scroll interpolation
	if scroll_smoothing > 0:
		# Lerp vertical scroll
		var lerp_factor = 1.0 - pow(scroll_smoothing, delta * 60.0)
		scroll_vertical = int(lerp(float(scroll_vertical), target_scroll_vertical, lerp_factor))

		# Lerp horizontal scroll
		var new_h_scroll = lerp(float(h_scroll.scroll_horizontal), target_scroll_horizontal, lerp_factor)
		h_scroll.scroll_horizontal = int(new_h_scroll)
		grid_helper.scroll_position = new_h_scroll
	else:
		# Instant scrolling when smoothing is disabled
		scroll_vertical = int(target_scroll_vertical)
		h_scroll.scroll_horizontal = int(target_scroll_horizontal)
		grid_helper.scroll_position = target_scroll_horizontal

	# Update playhead position based on scroll/zoom
	_update_playhead_position()


func unbind():
	clip = null
	clip_instance = null
	note_editor.unbind()

func bind_to_clip_instance(ci : ClipInstance):
	print("[MidiEditor] bind_to_clip_instance called")
	print("  - clip_instance: ", ci)
	print("  - clip_id: ", ci.clip_id if ci else "null")
	print("  - clip: ", ci.clip if ci else "null")
	
	if clip_instance:
		unbind()
	
	clip_instance = ci
	note_editor.bind(clip_instance)
	
	call_deferred("scroll_to_note")


# set vertical scroll to the given note, or default to average note or C3 if no notes
func scroll_to_note(note: int = -1):
	if note == -1:
		if not clip or not clip.midi_notes.size():
			note = 60
		else:
			note = clip.find_average_note()
	
	var y = note_editor.note_to_y(note)
	target_scroll_vertical = max(0, y - (size.y * 0.5))


func set_horizontal_zoom(new_pixels_per_beat: float) -> void:
	"""Set horizontal zoom level while maintaining the visual position under the mouse cursor."""
	if not grid_helper:
		return
	
	# Store old value for ratio calculation
	var old_pixels_per_beat = grid_helper.pixels_per_beat
	
	# Clamp new zoom
	var clamped_ppb = clamp(new_pixels_per_beat, 8.0, 512.0)
	
	# If we hit the limits or no change, don't adjust
	if clamped_ppb == old_pixels_per_beat:
		return
	
	# Get mouse position relative to h_scroll viewport
	var h_scroll_mouse_pos = h_scroll.get_local_mouse_position()
	
	# Store the current scroll position before zoom
	var old_scroll = h_scroll.scroll_horizontal
	
	# Calculate the zoom ratio
	var zoom_ratio = clamped_ppb / old_pixels_per_beat
	
	# Apply zoom (this triggers grid_helper.changed signal)
	grid_helper.pixels_per_beat = clamped_ppb
	
	# Calculate the content position under the mouse before zoom
	var old_content_x = old_scroll + h_scroll_mouse_pos.x
	
	# Scale the content position by the zoom ratio
	var new_content_x = old_content_x * zoom_ratio
	
	# Calculate the new scroll to keep the same content under the mouse
	var scroll_offset = new_content_x - h_scroll_mouse_pos.x
	
	# Snap to zero if we're close to the start (nice UX touch)
	var snap_threshold = 30.0
	if scroll_offset > 0 and scroll_offset < snap_threshold:
		scroll_offset = 0.0
	
	# Apply scroll immediately (bypassing smooth scrolling for zoom)
	target_scroll_horizontal = max(0, scroll_offset)
	h_scroll.scroll_horizontal = int(target_scroll_horizontal)
	grid_helper.scroll_position = target_scroll_horizontal
	

func _zoom_vertical(delta_note_height: int):
	"""Zoom vertically while maintaining the visual position of notes at the mouse cursor."""
	var note_editor_mouse_pos = note_editor.get_local_mouse_position()
	
	# Store the old note height for ratio calculation
	var old_note_height = note_height
	
	# Apply zoom
	note_height += delta_note_height
	note_height = clamp(note_height, note_height_min, note_height_max)
	
	# If we hit the limits, don't adjust scroll
	if note_height == old_note_height:
		return

	# Calculate the zoom ratio
	var zoom_ratio = float(note_height) / float(old_note_height)
	
	# Calculate the new scroll position to keep the same note under the mouse
	# Use the zoom ratio to calculate the expected change in note position
	# The note position should scale by the zoom ratio
	var old_note_y = note_editor_mouse_pos.y
	var new_note_y = old_note_y * zoom_ratio
	
	# Calculate the scroll offset needed to keep the note under the mouse
	var scroll_offset = new_note_y - note_editor_mouse_pos.y
	
	# Apply scroll immediately (bypassing smooth scrolling for zoom)
	target_scroll_vertical = max(0, scroll_vertical + scroll_offset)
	scroll_vertical = int(target_scroll_vertical)



func _unhandled_input(event: InputEvent):
	"""Unhandled input handler - catch events not consumed by child nodes."""
	if not visible or not is_visible_in_tree():
		return

	if event is InputEventMouseButton:
		var mevent = event as InputEventMouseButton

		# Always catch right mouse release to exit erase mode
		if mevent.button_index == MOUSE_BUTTON_RIGHT and mevent.is_released():
			if note_editor.erasing_mode or note_editor.interaction_mode == NoteEditor.InteractionMode.ERASING:
				print("[MidiEditor] Right mouse released - forcing erase mode exit")
				note_editor.interaction_mode = NoteEditor.InteractionMode.NONE
				note_editor.erasing_mode = false
				note_editor.last_erased_note = null
				_update_selection_overlays()


func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		# Middle mouse button panning
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				# Start panning
				is_panning = true
				pan_start_mouse_pos = event.position
				pan_start_scroll_v = target_scroll_vertical
				pan_start_scroll_h = target_scroll_horizontal
				pan_start_pixels_per_beat = grid_helper.pixels_per_beat if grid_helper else 0.0
				pan_start_h_scroll_mouse_pos = h_scroll.get_local_mouse_position()
				accept_event()
			else:
				# Stop panning
				is_panning = false
				accept_event()

		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if event.alt_pressed:
				# alt scroll up: scroll left
				target_scroll_horizontal = max(0, target_scroll_horizontal - scroll_speed_h)
			elif event.shift_pressed:
				# horizontal zoom in
				set_horizontal_zoom(grid_helper.pixels_per_beat * zoom_sensitivity_h)
			elif event.ctrl_pressed:
				# vertical zoom in
				_zoom_vertical(zoom_sensitivity_v)
			else:
				# vertical scroll up
				target_scroll_vertical = max(0, target_scroll_vertical - scroll_speed_v)
			accept_event()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.alt_pressed:
				# alt scroll down: scroll right
				target_scroll_horizontal += scroll_speed_h
			elif event.shift_pressed:
				# horizontal zoom out
				set_horizontal_zoom(grid_helper.pixels_per_beat / zoom_sensitivity_h)
			elif event.ctrl_pressed:
				# vertical zoom out
				_zoom_vertical(-zoom_sensitivity_v)
			else:
				# scroll down
				target_scroll_vertical += scroll_speed_v
			accept_event()

		# Delegate left/right mouse buttons to note editor
		elif event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			_handle_note_editing_mouse_button(event)

	elif event is InputEventMouseMotion:
		if is_panning:
			# Calculate the delta from the starting position
			var delta = event.position - pan_start_mouse_pos

			# Zoom or scroll based on modifiers
			if event.shift_pressed:
				# Shift + middle mouse: delta.y controls horizontal zoom proportionally, anchored at mouse position
				# Negative delta.y (moving up) = zoom in, positive (moving down) = zoom out
				# Scale the sensitivity by the starting zoom level for consistent feel across all zoom levels
				var zoom_factor = 1.0 - (delta.y * pan_zoom_sensitivity / 50)
				var new_ppb = pan_start_pixels_per_beat * zoom_factor
				new_ppb = clamp(new_ppb, 8.0, 512.0)

				# Calculate zoom ratio
				var zoom_ratio = new_ppb / pan_start_pixels_per_beat

				# Calculate the content position under the mouse anchor point before zoom
				var old_content_x = pan_start_scroll_h + pan_start_h_scroll_mouse_pos.x

				# Scale by zoom ratio
				var new_content_x = old_content_x * zoom_ratio

				# Calculate new scroll to keep the same content under the anchor point
				var zoom_scroll = new_content_x - pan_start_h_scroll_mouse_pos.x

				# Apply zoom
				grid_helper.pixels_per_beat = new_ppb

				# Apply horizontal panning on top of zoom scroll adjustment
				target_scroll_horizontal = max(0, zoom_scroll - delta.x)

				# Vertical scroll not affected when shift is pressed
				target_scroll_vertical = pan_start_scroll_v
			else:
				# Normal panning: Update scroll positions (negative delta because we're moving the viewport opposite to mouse movement)
				target_scroll_horizontal = max(0, pan_start_scroll_h - delta.x)
				target_scroll_vertical = max(0, pan_start_scroll_v - delta.y)

			# For panning, apply immediately for better responsiveness
			h_scroll.scroll_horizontal = int(target_scroll_horizontal)
			scroll_vertical = int(target_scroll_vertical)
			grid_helper.scroll_position = target_scroll_horizontal

			accept_event()
		else:
			# Delegate mouse motion to note editor when not panning
			_handle_note_editing_mouse_motion(event)

	elif event is InputEventKey:
		# Delegate keyboard input to note editor
		note_editor.handle_key_input(event)


# ============================================================================
# NOTE EDITING INPUT DELEGATION
# ============================================================================
func _handle_note_editing_mouse_button(mevent: InputEventMouseButton) -> void:
	"""Delegate mouse button events to note editor."""
	# Convert mouse position to note_editor local space
	var note_editor_pos = note_editor.make_canvas_position_local(mevent.global_position)

	# Left mouse button
	if mevent.button_index == MOUSE_BUTTON_LEFT:
		if mevent.is_pressed():
			_handle_left_mouse_press(note_editor_pos, mevent)
		else:
			_handle_left_mouse_release(note_editor_pos, mevent)

	# Right mouse button - erase mode
	elif mevent.button_index == MOUSE_BUTTON_RIGHT:
		if mevent.is_pressed():
			_handle_right_mouse_press(note_editor_pos, mevent)
		elif mevent.is_released():
			_handle_right_mouse_release()


func _handle_left_mouse_press(note_editor_pos: Vector2, mevent: InputEventMouseButton) -> void:
	"""Handle left mouse button press for note editing."""
	var clicked_note = note_editor.get_note_at_position(note_editor_pos)

	if clicked_note:
		# Clicking on a note
		if mevent.ctrl_pressed:
			note_editor.selection_manager.toggle_note_selection(clicked_note)
			accept_event()
		elif clicked_note._is_over_resize_handle(clicked_note.get_local_mouse_position()):
			note_editor._on_resize_started(clicked_note, note_editor_pos)
			note_editor.interaction_mode = NoteEditor.InteractionMode.RESIZING
			accept_event()
		else:
			note_editor._on_drag_started(clicked_note, note_editor_pos)
			note_editor.interaction_mode = NoteEditor.InteractionMode.DRAGGING
			accept_event()
	else:
		# Clicking on empty space
		if mevent.ctrl_pressed:
			note_editor.selection_manager.start_box_selection(note_editor_pos)
			note_editor.interaction_mode = NoteEditor.InteractionMode.BOX_SELECTING
			accept_event()
		else:
			note_editor.place_note_at_position(note_editor_pos)
			accept_event()

	_update_selection_overlays()


func _handle_left_mouse_release(note_editor_pos: Vector2, mevent: InputEventMouseButton) -> void:
	"""Handle left mouse button release for note editing."""
	if note_editor.interaction_mode == NoteEditor.InteractionMode.BOX_SELECTING:
		var notes_in_box = note_editor.get_notes_in_box(note_editor.selection_manager.box_selection_rect)
		note_editor.selection_manager.end_box_selection(notes_in_box)
		note_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		accept_event()

	elif note_editor.interaction_mode == NoteEditor.InteractionMode.DRAGGING or note_editor.interaction_mode == NoteEditor.InteractionMode.PLACING_AND_DRAGGING:
		if note_editor.dragging_note:
			note_editor._on_drag_ended(note_editor.dragging_note)
		note_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		accept_event()

	elif note_editor.interaction_mode == NoteEditor.InteractionMode.RESIZING:
		if note_editor.resizing_note:
			note_editor._on_resize_ended(note_editor.resizing_note)
		note_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		accept_event()

	elif note_editor.placed_note_awaiting_drag:
		print("[MidiEditor] Note placed without drag")
		note_editor.update_container_width()
		note_editor.placed_note_awaiting_drag = null
		accept_event()
	else:
		accept_event()

	_update_selection_overlays()


func _handle_right_mouse_press(note_editor_pos: Vector2, mevent: InputEventMouseButton) -> void:
	"""Handle right mouse button press for erase mode."""
	note_editor.interaction_mode = NoteEditor.InteractionMode.ERASING
	note_editor.erasing_mode = true
	note_editor.last_erased_note = null

	var note_under_cursor = note_editor.get_note_at_position(note_editor_pos)
	if note_under_cursor:
		note_editor.erase_note(note_under_cursor)
		accept_event()
	else:
		note_editor.selection_manager.clear_selection()
		print("[MidiEditor] Right-click on empty space - cleared selection, erase mode active")

	_update_selection_overlays()


func _handle_right_mouse_release() -> void:
	"""Handle right mouse button release - exit erase mode."""
	if note_editor.erasing_mode or note_editor.interaction_mode == NoteEditor.InteractionMode.ERASING:
		print("[MidiEditor] Right mouse released - exiting erase mode")
		note_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		note_editor.erasing_mode = false
		note_editor.last_erased_note = null
		_update_selection_overlays()


func _handle_note_editing_mouse_motion(mevent: InputEventMouseMotion) -> void:
	"""Delegate mouse motion to note editor."""
	var note_editor_pos = note_editor.make_canvas_position_local(mevent.global_position)

	# Check for newly placed note waiting for drag
	if note_editor.placed_note_awaiting_drag and note_editor.placed_note_awaiting_drag.midi_note_data:
		var current_mouse_pos = get_global_mouse_position()
		var distance = current_mouse_pos.distance_to(note_editor.placed_note_mouse_pos)

		if distance >= note_editor.DRAG_THRESHOLD:
			print("[MidiEditor] Starting drag after placement (moved %.1f pixels)" % distance)
			note_editor.start_place_and_drag(note_editor.placed_note_awaiting_drag)
			note_editor.placed_note_awaiting_drag = null
			accept_event()
			_update_selection_overlays()
			return

	# Handle active interactions
	if note_editor.interaction_mode == NoteEditor.InteractionMode.BOX_SELECTING:
		note_editor.selection_manager.update_box_selection(note_editor_pos)
		var notes_in_box = note_editor.get_notes_in_box(note_editor.selection_manager.box_selection_rect)
		note_editor.selection_manager._set_selected_notes(notes_in_box)
		accept_event()
		_update_selection_overlays()

	elif note_editor.interaction_mode == NoteEditor.InteractionMode.DRAGGING or note_editor.interaction_mode == NoteEditor.InteractionMode.PLACING_AND_DRAGGING:
		if note_editor.dragging_note:
			note_editor._on_drag_updated(note_editor.dragging_note, note_editor_pos)
			accept_event()
			_update_selection_overlays()

	elif note_editor.interaction_mode == NoteEditor.InteractionMode.RESIZING:
		if note_editor.resizing_note:
			note_editor._on_resize_updated(note_editor.resizing_note, note_editor_pos)
			accept_event()
			_update_selection_overlays()

	elif note_editor.interaction_mode == NoteEditor.InteractionMode.ERASING:
		var note_to_erase = note_editor.get_note_at_position(note_editor_pos)
		if note_to_erase and note_to_erase != note_editor.last_erased_note:
			note_editor.erase_note(note_to_erase)
			accept_event()
			_update_selection_overlays()


# ============================================================================
# SELECTION OVERLAYS UPDATE
# ============================================================================
func _update_selection_overlays() -> void:
	"""Update overlays with current selection state."""
	if not note_editor or not note_editor.selection_manager or not grid_helper or not overlays:
		return

	var sm := note_editor.selection_manager

	# Update box selection
	overlays.is_box_selecting = sm.is_box_selecting
	if sm.is_box_selecting and sm.box_selection_rect.size.length() > 0:
		# Transform box from note_editor space to overlays space
		var box_global_pos = note_editor.get_global_transform() * sm.box_selection_rect.position
		var box_local_pos = overlays.make_canvas_position_local(box_global_pos)
		overlays.box_selection_rect = Rect2(box_local_pos, sm.box_selection_rect.size)
	else:
		# Clear the box when not actively selecting
		overlays.box_selection_rect = Rect2()

	# Update selection range markers
	var selection_length = sm.box_selection_end_tick - sm.box_selection_start_tick
	overlays.show_selection_markers = not sm.selected_notes.is_empty() and selection_length > 0

	if overlays.show_selection_markers:
		# Get X positions in note_editor content space
		var start_x = grid_helper.ticks_to_pixels(sm.box_selection_start_tick)
		var end_x = grid_helper.ticks_to_pixels(sm.box_selection_end_tick)

		# Transform to overlays local space
		var marker_start_global = note_editor.get_global_transform() * Vector2(start_x, 0)
		var marker_end_global = note_editor.get_global_transform() * Vector2(end_x, 0)
		overlays.selection_start_x = overlays.make_canvas_position_local(marker_start_global).x
		overlays.selection_end_x = overlays.make_canvas_position_local(marker_end_global).x

	overlays.queue_redraw()


func _on_grid_helper_changed() -> void:
	"""Called when grid_helper properties change (zoom, scroll, time signature, etc.)"""
	_update_playhead_position()
	_update_selection_overlays()


func _update_playhead_position() -> void:
	"""Update the Playhead control position based on playhead_ticks."""
	if not grid_helper or not playhead:
		return

	if playhead_ticks < 0:
		playhead.visible = false
		return

	playhead.visible = true

	# Convert ticks to pixels in content space
	var playhead_x_content = grid_helper.ticks_to_pixels(playhead_ticks)

	# Position relative to note_area, accounting for h_scroll offset
	playhead.position.x = playhead_x_content - h_scroll.scroll_horizontal + h_scroll.position.x
	playhead.position.x -= 3 # offset to center the playhead on the pixel, it's 3px wide.