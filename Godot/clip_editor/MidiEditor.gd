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
## Drum View's replacement for the piano keys. Shares VPiano's slot in the HBox;
## exactly one of the two is visible.
@onready var drum_row_header: DrumRowHeader = $HBox/DrumRowHeader
@onready var note_area: Control = $HBox/NoteArea
@onready var note_lanes: NoteLanes = $HBox/NoteArea/NoteLanes
@onready var grid_renderer: GridRenderer = $HBox/NoteArea/GridRenderer

# h_scroll Contains all NoteEditors
@onready var h_scroll: ScrollContainer = $HBox/NoteArea/HScroll
var note_editors : Array[NoteEditor] = []

# Track-mode state
var track_mode: bool = false  # True when displaying multiple clips across tracks
var current_track: Track = null:  # Active track in track-mode
	set(value):
		if current_track != value:
			current_track = value
			_update_note_editor_states()
			# Labels and colours come from the focused track's map (REQ-024).
			if is_inside_tree():
				call_deferred("refresh_note_map")

# Primary note editor (backwards compatibility, first in note_editors array)
var note_editor: NoteEditor:
	get:
		if note_editors.is_empty():
			return null
		return note_editors[0]


func get_active_note_editor() -> NoteEditor:
	"""Get the currently active note editor (respects track selection in track-mode)."""
	if not track_mode or not current_track:
		# Single-clip mode: use first editor
		return note_editor

	# Track-mode: find editor matching current_track
	for editor in note_editors:
		if not editor:
			continue

		var editor_track: Track = null
		if editor.multi_clip_mode and editor.track:
			editor_track = editor.track
		elif editor.clip_instance and editor.clip_instance.track:
			editor_track = editor.clip_instance.track

		if editor_track == current_track:
			return editor

	# Fallback to first editor
	return note_editor

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
			grid_renderer.set_grid_helper(gh)
			
			# Update all note editors
			for editor in note_editors:
				if editor:
					editor.grid_helper = gh

			# Connect to new grid_helper's changed signal
			if grid_helper:
				grid_helper.changed.connect(_on_grid_helper_changed)


# Local cursor position (in ticks) - propagated to NoteEditor(s)
var cursor_position_ticks: int = 0:
	set(value):
		cursor_position_ticks = value
		# Update all note editors
		for editor in note_editors:
			if editor:
				editor.cursor_position_ticks = cursor_position_ticks


## Shared pitch <-> row <-> Y math. Handed to VPiano, NoteLanes, DrumRowHeader and
## every NoteEditor so they all agree on where a pitch sits, exactly as they share
## one GridHelper horizontally. Chromatic in the piano roll, folded in Drum View.
var lane_layout: LaneLayout = LaneLayout.chromatic(20.0)

## Effective note map for the active track's channel, resolved once per change and
## cached (resolving walks the device chain, so never per frame).
var note_map: NoteMap = NoteMap.new()

## Tells us when a derived Auto map may have changed (REQ-004).
var _note_map_watcher := NoteMapWatcher.new()
var _watched_channel: Channel = null

## True while the editor shows Drum View instead of the piano roll.
var drum_view: bool = false:
	set(value):
		if drum_view == value:
			return
		drum_view = value
		_apply_view_mode()

## Set while a rebuild was deferred because a drag was in progress (REQ-021).
var _rows_dirty := false
## Set while a rebuild is already queued for the end of this frame, so a clip
## edit touching many notes still costs one rebuild.
var _rebuild_queued := false

## Emitted whenever the row set or the effective map changed, so ClipEditor can
## refresh the toolbar and the empty-view hint.
signal view_state_changed

## The user clicked the empty-Drum-View hint (REQ-023).
signal note_map_editor_requested

## Hint shown when Drum View has no rows to draw. Built in code because it only
## ever appears in this one state.
var _empty_hint: Button = null

# note height: drives lane_layout.row_height, which v_piano, note_lanes and the
# note editor(s) all read from
var note_height_min := 8
var note_height_max := 40
@export var note_height := 20:
	set(nh):
		if note_height != nh:
			note_height = clamp(nh, note_height_min, note_height_max)
			lane_layout.row_height = note_height
			if is_inside_tree():
				# Note editors resize from the layout's `changed` signal, but they
				# still mirror note_height for their own minimum size bookkeeping.
				for editor in note_editors:
					if editor:
						editor.note_height = note_height

var scroll_speed_notes = 2

@export var scroll_speed_v : int:
	get:
		return scroll_speed_notes * note_height

@export var scroll_speed_h = 50

# Zoom sensitivity: multiplier for zoom speed (higher = faster zoom)
@export var zoom_sensitivity_h: float = 1.1  # Horizontal zoom multiplier per scroll tick
@export var zoom_sensitivity_v: int = 1      # Vertical zoom delta per scroll tick
@export var pan_zoom_sensitivity: float = 0.5  # Zoom factor per pixel of mouse movement when shift+panning (percentage)

# Horizontal zoom limits (pixels per beat)
@export var zoom_min_pixels_per_beat: float = 8.0
@export var zoom_max_pixels_per_beat: float = 1024

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

## When on, clicking (or placing/dragging) a note plays it on the track's instrument.
var audition_enabled := false:
	set(on):
		audition_enabled = on
		if not on:
			_stop_preview_note()

# The one note currently previewed (piano key or audition), -1 when silent.
var _preview_note := -1
var _preview_channel_id := -1

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
	lane_layout.row_height = note_height
	v_piano.layout = lane_layout
	note_lanes.layout = lane_layout
	
	# Find existing NoteEditor in scene tree (from .tscn)
	var scene_note_editor = h_scroll.get_node_or_null("NoteEditor")
	if scene_note_editor:
		note_editors.append(scene_note_editor)
		_configure_note_editor(scene_note_editor)

	v_piano.key_pressed.connect(_on_piano_key_pressed)
	v_piano.key_released.connect(_on_piano_key_released)
	# The Drum View header emits the same signals, so audition works either way.
	drum_row_header.layout = lane_layout
	drum_row_header.key_pressed.connect(_on_piano_key_pressed)
	drum_row_header.key_released.connect(_on_piano_key_released)
	_note_map_watcher.changed.connect(_on_note_map_changed)
	visibility_changed.connect(_on_visibility_changed)
	_apply_view_mode()

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
	_update_hovered_key()


func unbind():
	"""Unbind all clip instances and clear note editors."""
	_stop_preview_note()
	clip = null
	clip_instance = null
	track_mode = false
	current_track = null
	
	# Unbind all note editors
	for editor in note_editors:
		if editor:
			editor.unbind()
	
	# Keep only the first editor (from scene tree), remove any dynamically created ones
	while note_editors.size() > 1:
		var editor = note_editors.pop_back()
		if editor:
			editor.queue_free()

func bind_to_clip_instance(ci : ClipInstance):
	"""Bind to a single clip instance (clip-mode)."""
	logger.info("bind_to_clip_instance called (clip-mode)")
	logger.info("  - clip_instance: ", ci)
	logger.info("  - clip_id: ", ci.clip_id if ci else "null")
	logger.info("  - clip: ", ci.clip if ci else "null")
	
	if clip_instance or track_mode:
		unbind()
	
	track_mode = false
	clip_instance = ci
	
	# Bind to the first (and only) note editor
	if note_editor:
		_configure_note_editor(note_editor)
		if clip_instance and clip_instance.track:
			note_editor.note_color = clip_instance.track.color
		note_editor.bind(clip_instance)
		# Clip-mode: no position offset (notes show at clip-local positions)
		note_editor.position_offset_ticks = 0
	
	call_deferred("refresh_note_map")
	call_deferred("scroll_to_note")


func bind_to_clips(clips: Array[ClipInstance], tracks: Array[Track]):
	"""Bind to multiple clips in track-mode (song-relative positioning).

	NEW BEHAVIOR: Creates one NoteEditor per TRACK, showing ALL clips on each track.
	This gives a complete timeline view for each selected track.
	"""
	logger.info("[MidiEditor] bind_to_clips called (track-mode)")
	logger.info("  - %d clips across %d tracks" % [clips.size(), tracks.size()])

	# Unbind previous state
	if clip_instance or track_mode:
		unbind()

	track_mode = true

	# Create one NoteEditor per TRACK (not per clip)
	for i in range(tracks.size()):
		var track = tracks[i]

		# Get ALL clips from this track (entire timeline, not just selected clips)
		var all_track_clips = track.clip_instances

		logger.info("  - Track %d: '%s' has %d total clips" % [i, track.name, all_track_clips.size()])

		# Reuse first editor, create new ones for the rest
		var editor: NoteEditor
		if i < note_editors.size():
			editor = note_editors[i]
		else:
			editor = NoteEditor.new()
			h_scroll.add_child(editor)
			note_editors.append(editor)

		_configure_note_editor(editor)

		# Bind to ALL clips on this track (multi-clip mode)
		editor.bind_to_clips(all_track_clips, track)

		# Set color from track
		editor.note_color = track.color

		logger.info("  - Bound editor %d to track '%s' with %d clips" % [i, track.name, all_track_clips.size()])

	# Store reference to first clip for convenience (optional, may not be used)
	if not clips.is_empty():
		clip_instance = clips[0]

	# Set first track as active by default
	if not tracks.is_empty():
		current_track = tracks[0]

	call_deferred("refresh_note_map")
	call_deferred("scroll_to_note")


# set vertical scroll to the given note, or default to average note or C3 if no notes
func scroll_to_note(note: int = -1):
	if note == -1:
		if not clip or not clip.midi_notes.size():
			note = 60
		else:
			note = clip.find_average_note()
	
	var y := lane_layout.pitch_to_y(note)
	target_scroll_vertical = max(0, y - (size.y * 0.5))


func set_horizontal_zoom(new_pixels_per_beat: float) -> void:
	"""Set horizontal zoom level while maintaining the visual position under the mouse cursor."""
	if not grid_helper:
		return
	
	# Store old value for ratio calculation
	var old_pixels_per_beat = grid_helper.pixels_per_beat
	
	# Clamp new zoom
	var clamped_ppb = clamp(new_pixels_per_beat, zoom_min_pixels_per_beat, zoom_max_pixels_per_beat)
	
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

		# Always catch right mouse release to exit erase mode (safety handler)
		if mevent.button_index == MOUSE_BUTTON_RIGHT and mevent.is_released():
			var active_editor = get_active_note_editor()
			if active_editor and (active_editor.erasing_mode or active_editor.interaction_mode == NoteEditor.InteractionMode.ERASING):
				logger.info("Right mouse released - forcing erase mode exit (safety handler)")
				active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
				on_interaction_finished()
				active_editor.erasing_mode = false
				active_editor.last_erased_note = null
				_update_selection_overlays()
				accept_event()


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
		# Delegate keyboard input to active note editor
		var active_editor = get_active_note_editor()
		if active_editor:
			active_editor.handle_key_input(event)


# ============================================================================
# NOTE EDITING INPUT DELEGATION
# ============================================================================
func _handle_note_editing_mouse_button(mevent: InputEventMouseButton) -> void:
	"""Delegate mouse button events to note editor."""
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	# Convert mouse position to active note_editor local space
	var note_editor_pos = active_editor.make_canvas_position_local(mevent.global_position)

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
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	var clicked_note = active_editor.get_note_at_position(note_editor_pos)

	if clicked_note:
		# Clicking on a note
		if not mevent.ctrl_pressed:
			_audition_visual_note(clicked_note)
		if mevent.ctrl_pressed:
			active_editor.selection_manager.toggle_note_selection(clicked_note)
			accept_event()
		elif clicked_note._is_over_resize_handle(clicked_note.get_local_mouse_position()):
			active_editor._on_resize_started(clicked_note, note_editor_pos)
			active_editor.interaction_mode = NoteEditor.InteractionMode.RESIZING
			accept_event()
		else:
			active_editor._on_drag_started(clicked_note, note_editor_pos)
			active_editor.interaction_mode = NoteEditor.InteractionMode.DRAGGING
			accept_event()
	else:
		# Clicking on empty space
		if mevent.ctrl_pressed:
			active_editor.selection_manager.start_box_selection(note_editor_pos)
			active_editor.interaction_mode = NoteEditor.InteractionMode.BOX_SELECTING
			accept_event()
		else:
			var placed: VisualNote = active_editor.place_note_at_position(note_editor_pos)
			_audition_visual_note(placed)
			accept_event()

	_update_selection_overlays()


func _handle_left_mouse_release(note_editor_pos: Vector2, mevent: InputEventMouseButton) -> void:
	"""Handle left mouse button release for note editing."""
	_stop_preview_note()
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	if active_editor.interaction_mode == NoteEditor.InteractionMode.BOX_SELECTING:
		var notes_in_box = active_editor.get_notes_in_box(active_editor.selection_manager.box_selection_rect)
		active_editor.selection_manager.end_box_selection(notes_in_box)
		active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		on_interaction_finished()
		accept_event()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.DRAGGING or active_editor.interaction_mode == NoteEditor.InteractionMode.PLACING_AND_DRAGGING:
		if active_editor.dragging_note:
			active_editor._on_drag_ended(active_editor.dragging_note)
		active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		on_interaction_finished()
		accept_event()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.RESIZING:
		if active_editor.resizing_note:
			active_editor._on_resize_ended(active_editor.resizing_note)
		active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		on_interaction_finished()
		accept_event()

	elif active_editor.placed_note_awaiting_drag:
		logger.info("Note placed without drag")
		active_editor.update_container_width()
		active_editor.placed_note_awaiting_drag = null
		accept_event()
	else:
		accept_event()

	_update_selection_overlays()


func _handle_right_mouse_press(note_editor_pos: Vector2, mevent: InputEventMouseButton) -> void:
	"""Handle right mouse button press for erase mode."""
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	active_editor.interaction_mode = NoteEditor.InteractionMode.ERASING
	active_editor.erasing_mode = true
	active_editor.last_erased_note = null

	var note_under_cursor = active_editor.get_note_at_position(note_editor_pos)
	if note_under_cursor:
		active_editor.erase_note(note_under_cursor)
		accept_event()
	else:
		active_editor.selection_manager.clear_selection()
		logger.info("Right-click on empty space - cleared selection, erase mode active")

	_update_selection_overlays()


func _handle_right_mouse_release() -> void:
	"""Handle right mouse button release - exit erase mode."""
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	if active_editor.erasing_mode or active_editor.interaction_mode == NoteEditor.InteractionMode.ERASING:
		logger.info("Right mouse released - exiting erase mode")
		active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		on_interaction_finished()
		active_editor.erasing_mode = false
		active_editor.last_erased_note = null
		_update_selection_overlays()


func _handle_note_editing_mouse_motion(mevent: InputEventMouseMotion) -> void:
	"""Delegate mouse motion to note editor."""
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	var note_editor_pos = active_editor.make_canvas_position_local(mevent.global_position)

	# Check for newly placed note waiting for drag
	if active_editor.placed_note_awaiting_drag and active_editor.placed_note_awaiting_drag.midi_note_data:
		var current_mouse_pos = get_global_mouse_position()
		var distance = current_mouse_pos.distance_to(active_editor.placed_note_mouse_pos)

		if distance >= active_editor.DRAG_THRESHOLD:
			logger.info("Starting drag after placement (moved %.1f pixels)" % distance)
			active_editor.start_place_and_drag(active_editor.placed_note_awaiting_drag)
			active_editor.placed_note_awaiting_drag = null
			accept_event()
			_update_selection_overlays()
			return

	# Handle active interactions
	if active_editor.interaction_mode == NoteEditor.InteractionMode.BOX_SELECTING:
		active_editor.selection_manager.update_box_selection(note_editor_pos)
		var notes_in_box = active_editor.get_notes_in_box(active_editor.selection_manager.box_selection_rect)
		active_editor.selection_manager._set_selected_notes(notes_in_box)
		accept_event()
		_update_selection_overlays()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.DRAGGING or active_editor.interaction_mode == NoteEditor.InteractionMode.PLACING_AND_DRAGGING:
		if active_editor.dragging_note:
			active_editor._on_drag_updated(active_editor.dragging_note, note_editor_pos)
			_retrigger_audition_on_pitch_change(active_editor.dragging_note)
			accept_event()
			_update_selection_overlays()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.RESIZING:
		if active_editor.resizing_note:
			active_editor._on_resize_updated(active_editor.resizing_note, note_editor_pos)
			accept_event()
			_update_selection_overlays()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.ERASING:
		var note_to_erase = active_editor.get_note_at_position(note_editor_pos)
		if note_to_erase and note_to_erase != active_editor.last_erased_note:
			active_editor.erase_note(note_to_erase)
			accept_event()
			_update_selection_overlays()


# ============================================================================
# SELECTION OVERLAYS UPDATE
# ============================================================================
func _update_selection_overlays() -> void:
	"""Update overlays with current selection state."""
	var active_editor = get_active_note_editor()
	if not active_editor or not active_editor.selection_manager or not grid_helper or not overlays:
		return

	var sm = active_editor.selection_manager

	# Update box selection
	overlays.is_box_selecting = sm.is_box_selecting
	if sm.is_box_selecting and sm.box_selection_rect.size.length() > 0:
		# Transform box from active_editor space to overlays space
		var box_global_pos = active_editor.get_global_transform() * sm.box_selection_rect.position
		var box_local_pos = overlays.make_canvas_position_local(box_global_pos)
		overlays.box_selection_rect = Rect2(box_local_pos, sm.box_selection_rect.size)
	else:
		# Clear the box when not actively selecting
		overlays.box_selection_rect = Rect2()

	# Update selection range markers
	var selection_length = sm.box_selection_end_tick - sm.box_selection_start_tick
	overlays.show_selection_markers = selection_length > 0

	if overlays.show_selection_markers:
		# Use the box_selection_start_tick and box_selection_end_tick directly
		# These are grid-snapped positions from the user's box selection gesture
		# In track-mode, these are already song-relative ticks (from ruler conversion)
		# In clip-mode, these are clip-local ticks
		# Do NOT add clip offsets - the ticks are already in the correct coordinate space

		var start_tick = sm.box_selection_start_tick
		var end_tick = sm.box_selection_end_tick

		# Convert to pixels in content space
		var start_x_content = grid_helper.ticks_to_pixels(start_tick)
		var end_x_content = grid_helper.ticks_to_pixels(end_tick)

		# Position relative to note_area, accounting for h_scroll offset (same as playhead)
		overlays.selection_start_x = start_x_content - h_scroll.scroll_horizontal + h_scroll.position.x
		overlays.selection_end_x = end_x_content - h_scroll.scroll_horizontal + h_scroll.position.x

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


func _update_note_editor_states() -> void:
	"""Update visual state of note editors based on current_track."""
	if not track_mode or not current_track:
		# In clip-mode, ensure first editor is active
		for i in range(note_editors.size()):
			var editor = note_editors[i]
			if editor:
				editor.z_index = 1 if i == 0 else 0
				editor.modulate.a = 1.0 if i == 0 else 0.5
		return

	# In track-mode, activate editor matching current_track
	for editor in note_editors:
		if not editor:
			continue

		# Get the track this editor is bound to
		var editor_track: Track = null
		if editor.multi_clip_mode and editor.track:
			# Multi-clip mode: editor is bound to a track
			editor_track = editor.track
		elif editor.clip_instance and editor.clip_instance.track:
			# Single-clip mode: get track from clip instance
			editor_track = editor.clip_instance.track

		if not editor_track:
			continue

		var is_active = editor_track == current_track

		# Active editor: on top (z=1), full opacity
		# Inactive editors: behind (z=0), half opacity for context
		editor.z_index = 1 if is_active else 0
		editor.modulate.a = 1.0 if is_active else 0.5
		if is_active:
			editor.move_to_front()
	
	logger.info("[MidiEditor] Updated editor states for track: %s" % current_track.name)


## Keep a note editor sized to content and wired to this MidiEditor's grid.
## The scene editor is reused across binds; re-assigning grid_helper reconnects
## zoom/scroll so its notes keep following the piano roll.
func _configure_note_editor(editor: NoteEditor) -> void:
	if editor == null:
		return
	editor.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	editor.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	editor.layout = lane_layout
	if not editor.notes_changed.is_connected(queue_row_rebuild):
		editor.notes_changed.connect(queue_row_rebuild)
	editor.note_height = note_height
	editor.cursor_position_ticks = cursor_position_ticks
	if grid_helper:
		editor.grid_helper = grid_helper


# ============================================================================
# KEY HOVER + NOTE PREVIEW (piano keys and audition mode)
# ============================================================================
func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		_stop_preview_note()
		v_piano.hovered_note = -1
		drum_row_header.hovered_note = -1


## Highlight the piano key for the lane under the mouse (note area or piano).
func _update_hovered_key() -> void:
	var note := -1
	var header: Control = drum_row_header if drum_view else v_piano
	var hovered: Control = get_viewport().gui_get_hovered_control() if is_visible_in_tree() else null
	if hovered and (hovered == self or is_ancestor_of(hovered)) and not is_panning:
		if hovered == header:
			note = header.get_note_at_position(header.get_local_mouse_position())
		else:
			var y := note_lanes.get_local_mouse_position().y
			if y >= 0.0 and y < lane_layout.total_height():
				note = lane_layout.y_to_pitch(y)
	header.hovered_note = note


# ============================================================================
# NOTE MAPS AND DRUM VIEW
# ============================================================================

## Channel whose note map applies: the focused track's in track-mode, otherwise
## the bound clip's track's.
func get_active_channel() -> Channel:
	var t: Track = current_track if track_mode else (clip_instance.track if clip_instance else null)
	if t == null:
		return null
	# The track's own link first: it needs no editor, which keeps this usable
	# headless and during load, before Sonara.editor is wired up.
	var ch := t.get_linked_channel()
	if ch:
		return ch
	var project: Project = Sonara.editor.project if Sonara.editor else null
	return project.get_channel_by_id(t.default_channel_id) if project else null


## Re-bind the watcher and re-resolve the map for the channel now in focus. Called
## whenever the binding changes; the watcher then keeps it current by itself.
func refresh_note_map() -> void:
	var channel := get_active_channel()
	if channel != _watched_channel:
		_watched_channel = channel
		_note_map_watcher.bind(channel)
	note_map = NoteMapResolver.effective_map(channel)
	v_piano.note_map = note_map
	note_lanes.note_map = note_map
	drum_row_header.note_map = note_map
	rebuild_rows()
	view_state_changed.emit()


## The Auto map's source changed (a pad renamed, moved, added or recoloured), or
## the assignment did. Coalesced to one call per frame by NoteMapWatcher.
func _on_note_map_changed() -> void:
	refresh_note_map()


## Whether this channel's clips should open in Drum View (REQ-028).
func wants_drum_view() -> bool:
	return NoteMapResolver.wants_drum_view(get_active_channel())


## Every clip currently on screen, across all note editors.
func _visible_clips() -> Array:
	var clips: Array = []
	for editor in note_editors:
		if editor == null:
			continue
		if editor.multi_clip_mode:
			clips.append_array(editor.clip_instances)
		elif editor.clip_instance:
			clips.append(editor.clip_instance)
	return clips


## Rows for Drum View: the union across every editor of its map's pitches and the
## pitches its clips use (REQ-016, REQ-024).
func compute_rows() -> PackedInt32Array:
	return DrumRows.rows_for(note_map, _visible_clips())


## Recompute the folded row set. Deferred while a drag is running so rows can't
## reshuffle under the cursor (REQ-021); the drag's end calls this again.
func rebuild_rows() -> void:
	if not drum_view:
		return
	var active := get_active_note_editor()
	if active and active.interaction_mode != NoteEditor.InteractionMode.NONE:
		_rows_dirty = true
		return
	_rows_dirty = false
	lane_layout.set_rows(compute_rows())
	_update_empty_hint()
	view_state_changed.emit()


## Called when an interaction finishes, so a row set that changed mid-drag is
## applied once the cursor is released (REQ-021).
func on_interaction_finished() -> void:
	if _rows_dirty:
		rebuild_rows()


## Ask for a row rebuild after the current frame. Notes added, erased or dragged
## to a new pitch change the row set; while a drag is running rebuild_rows()
## defers itself, and on_interaction_finished() picks it up on release.
func queue_row_rebuild() -> void:
	if not drum_view or _rebuild_queued:
		return
	_rows_dirty = true
	_rebuild_queued = true
	_flush_row_rebuild.call_deferred()


func _flush_row_rebuild() -> void:
	_rebuild_queued = false
	rebuild_rows()


## Swap the header controls and the layout mode, keeping the selection and a
## visible pitch on screen (REQ-015).
func _apply_view_mode() -> void:
	if not is_inside_tree():
		return
	# A pitch that is on screen now, so the same row can be brought back after the
	# switch. Selection lives in the note editors and is untouched either way.
	var anchor := _visible_anchor_pitch()

	v_piano.visible = not drum_view
	drum_row_header.visible = drum_view
	if drum_view:
		lane_layout.set_rows(compute_rows())
	else:
		lane_layout.set_chromatic()
	_rows_dirty = false

	if anchor >= 0 and lane_layout.row_of_pitch(anchor) >= 0:
		call_deferred("scroll_to_note", anchor)
	_update_empty_hint()
	view_state_changed.emit()


## A pitch to keep in view across a mode switch: the first selected note's, else
## whatever sits in the middle of the viewport.
func _visible_anchor_pitch() -> int:
	var active := get_active_note_editor()
	if active and active.selection_manager:
		for vn in active.selection_manager.selected_notes:
			if vn and vn.midi_note_data:
				return vn.midi_note_data.note
	if lane_layout.total_height() <= 0:
		return -1
	return lane_layout.y_to_pitch(scroll_vertical + size.y * 0.5)


## True when Drum View has nothing to show, so ClipEditor can offer the hint
## that opens the note map editor (REQ-023).
func drum_view_is_empty() -> bool:
	return drum_view and lane_layout.row_count() == 0


## Show or hide the "nothing to show here" hint over the note area (REQ-023).
func _update_empty_hint() -> void:
	var should_show := drum_view_is_empty()
	if _empty_hint == null:
		if not should_show:
			return
		_empty_hint = Button.new()
		_empty_hint.name = "DrumViewEmptyHint"
		_empty_hint.text = "No drum rows yet — set up a note map for this channel"
		_empty_hint.flat = true
		_empty_hint.focus_mode = Control.FOCUS_NONE
		_empty_hint.mouse_filter = Control.MOUSE_FILTER_STOP
		_empty_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		_empty_hint.offset_top = 24.0
		_empty_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_empty_hint.pressed.connect(func(): note_map_editor_requested.emit())
		note_area.add_child(_empty_hint)
	_empty_hint.visible = should_show


## Channel that previews should play on: the focused track in track-mode,
## otherwise the bound clip's track.
func _get_preview_channel_id() -> int:
	var t: Track = current_track if track_mode else (clip_instance.track if clip_instance else null)
	return t.default_channel_id if t else -1


func _start_preview_note(note: int, velocity: int) -> void:
	_stop_preview_note()
	var channel_id := _get_preview_channel_id()
	if channel_id < 0:
		return
	_preview_note = note
	_preview_channel_id = channel_id
	MidiManager.send_note_to_channel(channel_id, note, velocity, true)


func _stop_preview_note() -> void:
	if _preview_note < 0:
		return
	MidiManager.send_note_to_channel(_preview_channel_id, _preview_note, 0, false)
	_preview_note = -1
	_preview_channel_id = -1


func _on_piano_key_pressed(note: int, velocity: int) -> void:
	_start_preview_note(note, velocity)


func _on_piano_key_released(note: int) -> void:
	if note == _preview_note:
		_stop_preview_note()


func _audition_visual_note(vn: VisualNote) -> void:
	if not audition_enabled or vn == null or vn.midi_note_data == null:
		return
	_start_preview_note(vn.midi_note_data.note, vn.midi_note_data.velocity)


## While dragging with audition on, replay the note whenever its pitch changes.
func _retrigger_audition_on_pitch_change(vn: VisualNote) -> void:
	if not audition_enabled or _preview_note < 0 or vn == null or vn.midi_note_data == null:
		return
	if vn.midi_note_data.note != _preview_note:
		_start_preview_note(vn.midi_note_data.note, vn.midi_note_data.velocity)
