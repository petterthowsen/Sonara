# TimelineClip.gd
# Visual representation of a Clip on the timeline. The body, header band and name are drawn here
# rather than built from container and Label nodes: every node under the scrolled timeline costs
# time on each scroll frame, and a project has hundreds of clips. Only the note/waveform renderer
# is a child.
class_name TimelineClip extends Control

static var logger := Log.make("TimelineClip")

# Signals
signal select_requested(clip_ui: TimelineClip, add_to_selection: bool)  # Request to select this clip; add_to_selection = shift held
signal exclusive_click_requested(clip_ui: TimelineClip)  # Plain click finished without a drag
signal drag_begin_requested(clip_ui: TimelineClip, press_global_position: Vector2)  # Move drag passed the threshold; Timeline takes over
signal context_menu_requested(clip_ui: TimelineClip, global_position: Vector2)
signal open_in_editor_requested(clip_ui: TimelineClip)  # Double-click on the clip body

@onready var clip_renderer: MidiclipRenderer = $ClipRenderer
@onready var waveform_view: WaveformView = $ClipRenderer/Waveform

# Data binding
var clip_instance: ClipInstance = null:  # The instance we're displaying
	set(ci):
		clip_instance = ci
		
		if is_inside_tree():
			clip_renderer.clip_instance = clip_instance

var timeline = null
var _bound_source_clip: Clip = null
var _bound_grid_helper: GridHelper = null
var track_color: Color = Color.WHITE:
	set(tc):
		if track_color != tc:
			track_color = tc
			_apply_note_color()

# Selection and hover state
var is_selected: bool = false
var is_hovered: bool = false

# Drag state
var is_dragging: bool = false
var _press_was_additive: bool = false
var drag_start_pos: Vector2 = Vector2.ZERO
var drag_threshold: float = 10.0  # pixels before drag activates
var _drag_handed_off: bool = false  # Timeline runs the move; this node only swallows the release

# Resize state
var is_resizing: bool = false
var resize_edge: String = ""  # "left" or "right"
var resize_start_pos: Vector2 = Vector2.ZERO
var resize_start_ticks: int = 0
var resize_start_duration: int = 0
var resize_start_offset: int = 0  # Initial clip_offset when resize started
var resize_start_loop: Array = []  # Initial loop state when resize started
var resize_start_content_length: int = 0  # Source clip length when resize started
var resize_padding_added: int = 0  # Track total padding added during this resize
## Clips resized together with this grabbed one (itself included): the whole selection when
## this clip is part of a multi-selection.
var _resize_group: Array[TimelineClip] = []
@export var resize_edge_size: float = 8.0  # pixel width of resize edge zones

# Exported StyleBoxes for different states
@export var style_normal: StyleBoxFlat = null
@export var style_hovered: StyleBoxFlat = null
@export var style_selected: StyleBoxFlat = null

@export_group("Header")
## Band along the top holding the clip name. ClipRenderer's offset_top matches its height.
@export var header_style: StyleBoxFlat = null
@export var header_height: float = 24.0
## Font size and color of the clip name (the font is the theme's Label font).
@export var name_settings: LabelSettings = null
@export_group("")

## Loop-point drag: `_loop_drag_pass` is the 1-based divider being dragged (0 = none).
var _loop_drag_pass: int = 0
var _loop_drag_start_state: Array = []
var _loop_drag_start_content: int = 0
## Pixels either side of a divider that grab it.
const LOOP_GRAB_PX := 4.0

## Extra waveform views for the loop passes after the first (the scene's own view draws the first).
var _loop_waveforms: Array[WaveformView] = []
## Draws the dividers between loop passes above the notes and waveforms. Built on first use.
var _loop_overlay: Control = null
var _loop_boundaries: PackedInt32Array = PackedInt32Array()
## Cap on waveform views per clip; passes beyond it show no waveform.
const MAX_LOOP_WAVEFORMS := 64

## The clip name, shaped once per rename and trimmed with an ellipsis to the header width.
var _name_line := TextLine.new()
var _name_text: String = ""

## Own hover, cursor, and mouse-filter so child visuals don't steal clip clicks.
func _ready() -> void:
	focus_mode = Control.FOCUS_CLICK
	# Children are visual-only; this Control owns clip mouse input. PASS so
	# unused events (middle-click pan) are not auto-handled by the Viewport.
	mouse_filter = Control.MOUSE_FILTER_PASS
	_name_line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_shape_name()
	if clip_renderer:
		clip_renderer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	
	clip_renderer.clip_instance = clip_instance
	_layout_clip_renderer()
	_apply_note_color()
	_bind_grid_helper()
	_update_waveform()


## Keep the note/waveform renderer inside the clip's border and below the header band. Without
## this a short clip draws its notes over the 1px body border (the renderer spans the full rect
## and children paint over the parent's stylebox); the left/right insets stop wide notes from
## covering the vertical borders too.
func _layout_clip_renderer() -> void:
	if clip_renderer == null:
		return
	var style := _get_current_style()
	var left := 0.0
	var right := 0.0
	var bottom := 0.0
	if style:
		left = float(style.border_width_left)
		right = float(style.border_width_right)
		bottom = float(style.border_width_bottom)
	clip_renderer.anchor_left = 0.0
	clip_renderer.anchor_top = 0.0
	clip_renderer.anchor_right = 1.0
	clip_renderer.anchor_bottom = 1.0
	clip_renderer.offset_left = left
	clip_renderer.offset_top = header_height
	clip_renderer.offset_right = -right
	clip_renderer.offset_bottom = -bottom


func _exit_tree() -> void:
	_unbind_grid_helper()


## Paint MIDI notes with the stored track color; only clamp for drawing.
func _apply_note_color() -> void:
	if clip_renderer == null:
		return
	clip_renderer.note_color = Utils.display_color(track_color)
	clip_renderer.queue_redraw()
	if waveform_view:
		waveform_view.color = Utils.display_color(track_color)


func bind_to_clip_instance(inst: ClipInstance, tl, t_color: Color = Color.WHITE) -> void:
	"""Bind this UI element to a ClipInstance data object.

	Connects to clip signals for real-time updates, including progressive waveform
	loading notifications.
	"""
	if clip_instance and clip_instance.clip_changed.is_connected(_on_instance_clip_changed):
		clip_instance.clip_changed.disconnect(_on_instance_clip_changed)
	if clip_instance and clip_instance.instance_modified.is_connected(_on_instance_modified):
		clip_instance.instance_modified.disconnect(_on_instance_modified)
	_unbind_source_clip()

	clip_instance = inst
	timeline = tl
	track_color = t_color

	if clip_instance and not clip_instance.clip_changed.is_connected(_on_instance_clip_changed):
		clip_instance.clip_changed.connect(_on_instance_clip_changed)
	if clip_instance and not clip_instance.instance_modified.is_connected(_on_instance_modified):
		clip_instance.instance_modified.connect(_on_instance_modified)
	_bind_source_clip(clip_instance.clip if clip_instance else null)

	# Update UI from clip instance data
	if is_inside_tree():
		_bind_grid_helper()
		_update_from_clip_instance()


## Follow Make Unique / retarget so the header shows the new clip name.
func _on_instance_clip_changed(new_clip: Clip) -> void:
	_bind_source_clip(new_clip)
	if is_inside_tree():
		_update_from_clip_instance()


## Follow model changes that bypass this view (undo/redo, other views) to the new position and width.
func _on_instance_modified() -> void:
	if clip_instance == null or timeline == null:
		return
	var width = timeline.ticks_to_pixels(clip_instance.duration_ticks)
	position.x = timeline.ticks_to_pixels(clip_instance.start_ticks)
	custom_minimum_size.x = width
	size.x = width
	modulate.a = 0.45 if clip_instance.muted else 1.0
	_update_waveform()
	if clip_renderer:
		clip_renderer.queue_redraw()
	queue_redraw()


## Follow zoom changes so the waveform's frames-per-pixel stays in step. Not scroll: the
## WaveformView tracks its own visible slice, and every clip would otherwise run this per frame.
func _bind_grid_helper() -> void:
	var gh: GridHelper = timeline.grid_helper if timeline else null
	if gh == _bound_grid_helper:
		return
	_unbind_grid_helper()
	_bound_grid_helper = gh
	if gh:
		gh.scale_changed.connect(_update_waveform)


func _unbind_grid_helper() -> void:
	if _bound_grid_helper and _bound_grid_helper.scale_changed.is_connected(_update_waveform):
		_bound_grid_helper.scale_changed.disconnect(_update_waveform)
	_bound_grid_helper = null


## Point the WaveformView at the clip's peak data and map timeline ticks to source frames.
## Matches the engine's constant stretch (AudioPlayback::calculate_stretch_factor): one tick
## covers 60 / (recorded_bpm × ppq) seconds of the source file.
func _update_waveform() -> void:
	_update_loop_overlay()
	if waveform_view == null:
		return
	var clip: Clip = clip_instance.clip if clip_instance else null
	var is_audio := clip != null and clip.type == Clip.ClipType.AUDIO
	waveform_view.visible = is_audio
	if not is_audio:
		waveform_view.data = null
		_layout_loop_waveforms([])
		return
	waveform_view.reverse = clip_instance.reverse_enabled
	waveform_view.data = clip.audio_source.data
	var gh: GridHelper = timeline.grid_helper if timeline else null
	if gh == null or not waveform_view.is_data_ready() or gh.pixels_per_beat <= 0.0:
		return
	var bpm: float = clip.recorded_bpm if clip.recorded_bpm > 0.0 else gh.tempo
	var frames_per_tick := float(waveform_view.source_sample_rate()) * 60.0 / (bpm * float(gh.ppq))
	var frames_per_pixel := float(gh.ppq) / gh.pixels_per_beat * frames_per_tick
	var segments: Array[Vector3i] = []
	if clip_instance.loop_enabled:
		segments = clip_instance.get_loop_segments(MAX_LOOP_WAVEFORMS + 1)
	if segments.size() <= 1:
		# One run of content: the view fills the clip body.
		_layout_loop_waveforms([])
		waveform_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		waveform_view.start_frame = float(clip_instance.clip_offset) * frames_per_tick
		waveform_view.frames_per_pixel = frames_per_pixel
		return
	_layout_loop_waveforms(segments)
	_place_waveform(waveform_view, segments[0], frames_per_tick, frames_per_pixel)
	for i in _loop_waveforms.size():
		_place_waveform(_loop_waveforms[i], segments[i + 1], frames_per_tick, frames_per_pixel)


## Put `view` over one run of content: `segment` is Vector3i(local_start, local_end, content_start).
func _place_waveform(view: WaveformView, segment: Vector3i, frames_per_tick: float, frames_per_pixel: float) -> void:
	var x0: float = timeline.ticks_to_pixels(segment.x)
	var x1: float = timeline.ticks_to_pixels(segment.y)
	# Anchored to the body's top and bottom, with the run's x range as the horizontal offsets.
	view.anchor_left = 0.0
	view.anchor_right = 0.0
	view.anchor_top = 0.0
	view.anchor_bottom = 1.0
	view.offset_left = x0
	view.offset_right = maxf(x1, x0)
	view.offset_top = 0.0
	view.offset_bottom = 0.0
	view.start_frame = float(segment.z) * frames_per_tick
	view.frames_per_pixel = frames_per_pixel


## Keep one extra waveform view per run after the first: `segments` is empty for an unlooped clip.
func _layout_loop_waveforms(segments: Array) -> void:
	var wanted := maxi(0, segments.size() - 1)
	while _loop_waveforms.size() > wanted:
		_loop_waveforms.pop_back().queue_free()
	while _loop_waveforms.size() < wanted:
		var view := WaveformView.new()
		view.color = waveform_view.color
		view.data = waveform_view.data
		clip_renderer.add_child(view)
		_loop_waveforms.append(view)
	for view in _loop_waveforms:
		view.data = waveform_view.data
		view.color = waveform_view.color
		view.reverse = waveform_view.reverse


## Redraw the dividers between loop passes, creating the overlay the first time a clip loops.
func _update_loop_overlay() -> void:
	_loop_boundaries.clear()
	if clip_instance and clip_instance.loop_enabled:
		for segment in clip_instance.get_loop_segments():
			if segment.x > 0:
				_loop_boundaries.append(segment.x)
	if _loop_boundaries.is_empty() and _loop_overlay == null:
		return
	if _loop_overlay == null:
		_loop_overlay = Control.new()
		_loop_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_loop_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_loop_overlay.offset_top = header_height
		# Stop the dividers above the body's bottom border, like the note renderer.
		_loop_overlay.offset_bottom = -1.0
		_loop_overlay.draw.connect(_draw_loop_overlay)
		add_child(_loop_overlay)
	_loop_overlay.queue_redraw()


func _draw_loop_overlay() -> void:
	if timeline == null:
		return
	var color := Color(1.0, 1.0, 1.0, 0.45)
	for tick in _loop_boundaries:
		var x: float = roundf(timeline.ticks_to_pixels(tick)) + 0.5
		if x <= 0.0 or x >= size.x:
			continue
		# Dashed, so it reads as a repeat marker rather than a clip edge.
		var y := 0.0
		while y < _loop_overlay.size.y:
			_loop_overlay.draw_line(Vector2(x, y), Vector2(x, minf(y + 4.0, _loop_overlay.size.y)), color, 1.0)
			y += 8.0


## Listen to the current source clip for rename and content updates.
func _bind_source_clip(c: Clip) -> void:
	if _bound_source_clip == c:
		return
	_unbind_source_clip()
	_bound_source_clip = c
	if _bound_source_clip == null:
		return
	if not _bound_source_clip.waveform_ready.is_connected(_on_clip_waveform_ready):
		_bound_source_clip.waveform_ready.connect(_on_clip_waveform_ready)
	if not _bound_source_clip.clip_modified.is_connected(_on_source_clip_modified):
		_bound_source_clip.clip_modified.connect(_on_source_clip_modified)


## Drop source-clip listeners before rebinding or freeing.
func _unbind_source_clip() -> void:
	if _bound_source_clip == null:
		return
	if _bound_source_clip.waveform_ready.is_connected(_on_clip_waveform_ready):
		_bound_source_clip.waveform_ready.disconnect(_on_clip_waveform_ready)
	if _bound_source_clip.clip_modified.is_connected(_on_source_clip_modified):
		_bound_source_clip.clip_modified.disconnect(_on_source_clip_modified)
	_bound_source_clip = null


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


## Refresh label when the source clip is renamed or its notes change.
func _on_source_clip_modified() -> void:
	if is_inside_tree():
		_update_from_clip_instance()


## Peak data arrived (or was shared): show it.
func _on_clip_waveform_ready(_clip: Clip) -> void:
	_update_waveform()


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

	# Update the name (use clip name if available)
	_set_name_text(clip_instance.clip.name if clip_instance.clip else "Clip Instance")
	modulate.a = 0.45 if clip_instance.muted else 1.0

	# Update position and size based on instance timing
	var start_x = timeline.ticks_to_pixels(clip_instance.start_ticks)
	var width = timeline.ticks_to_pixels(clip_instance.duration_ticks)

	position.x = start_x
	custom_minimum_size.x = width
	size.x = width
	_update_waveform()

	# Apply initial style
	_update_style()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
	elif what == NOTIFICATION_THEME_CHANGED:
		_shape_name()


func _draw() -> void:
	"""Draw the body stylebox, the header band and the clip name."""
	var style := _get_current_style()
	if style:
		style.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))
	var band := Rect2(0.0, 0.0, size.x, minf(header_height, size.y))
	if header_style:
		header_style.draw(get_canvas_item(), band)
	if _name_text.is_empty():
		return
	var margin_left := header_style.content_margin_left if header_style else 0.0
	var margin_right := header_style.content_margin_right if header_style else 0.0
	var margin_top := header_style.content_margin_top if header_style else 0.0
	var width := size.x - margin_left - margin_right
	if width <= 0.0:
		return
	_name_line.width = width
	var color := name_settings.font_color if name_settings else Color.WHITE
	_name_line.draw(get_canvas_item(), Vector2(margin_left, margin_top), color)


func _set_name_text(text: String) -> void:
	if text == _name_text:
		return
	_name_text = text
	_shape_name()


## Reshape the name for the current text and font; `_draw` only sets the width.
func _shape_name() -> void:
	_name_line.clear()
	if not _name_text.is_empty() and is_inside_tree():
		var font: Font = name_settings.font if name_settings and name_settings.font else get_theme_font("font", "Label")
		var font_size: int = name_settings.font_size if name_settings else get_theme_font_size("font_size", "Label")
		_name_line.add_string(_name_text, font, font_size)
	queue_redraw()


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
	_layout_clip_renderer()
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
		if edge != "" or _loop_boundary_pass_at(local_pos.x) > 0 or _loop_drag_pass > 0:
			mouse_default_cursor_shape = CURSOR_HSIZE
		else:
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


# ============================================================================
# INPUT HANDLING
# ============================================================================
## Start a Ctrl/Cmd click-or-drag: this clip is already selected; a move starts a box-select.
func _begin_additive_gesture() -> void:
	if not timeline or not timeline.clip_selection_manager:
		return
	timeline.clip_selection_manager.begin_additive_gesture(
		timeline.get_local_mouse_position(), clip_instance)


## Handle mouse input for selection, dragging, and resizing.
func _gui_input(event: InputEvent) -> void:
	# Update cursor based on mouse position
	if event is InputEventMouseMotion:
		var local_pos = get_local_mouse_position()
		_update_cursor_for_position(local_pos)

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			# Consume press so parent lanes don't treat this as empty space.
			# Open on release so the popup is not dismissed by the same click.
			if not event.pressed:
				context_menu_requested.emit(self, get_global_mouse_position())
			accept_event()
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var local_pos = get_local_mouse_position()
				var edge = _get_edge_at_position(local_pos)
				var boundary_pass := _loop_boundary_pass_at(local_pos.x) if edge == "" else 0

				if boundary_pass > 0:
					_loop_drag_start_state = clip_instance.get_loop_state()
					_begin_loop_drag(boundary_pass)
					if Sonara.editor:
						Sonara.editor.set_playhead(clip_instance.start_ticks + _loop_boundaries[boundary_pass - 1])
					accept_event()
				elif edge != "":
					# Start resize
					is_resizing = true
					resize_start_pos = get_global_mouse_position()
					_resize_group = _find_resize_group()
					for clip_ui in _resize_group:
						clip_ui._begin_resize(edge)
					if edge == "right" and event.alt_pressed and clip_instance and not clip_instance.loop_enabled:
						# Alt puts a loop point at the instance's current end; the drag then lengthens
						# the instance, which repeats the loop. A MIDI clip is trimmed (or grown) to
						# end there too, so the loop is exactly what the instance showed.
						var region := clip_instance.default_loop_region()
						var clip := clip_instance.clip
						if clip and clip.type == Clip.ClipType.MIDI:
							region = Vector2i(clip_instance.clip_offset, clip_instance.duration_ticks)
							clip.set_content_length(region.x + region.y)
						clip_instance.set_loop(true, region.x, region.y)
					accept_event()
				elif event.double_click and not (event.ctrl_pressed or event.meta_pressed or event.shift_pressed):
					# The first click already selected this clip; open it instead of starting a drag.
					open_in_editor_requested.emit(self)
					accept_event()
				else:
					grab_focus()
					# Ctrl/Cmd: toggle immediately; a drag starts a box-select instead of moving the clip.
					if event.ctrl_pressed or event.meta_pressed or Input.is_action_pressed("ui_select"):
						_press_was_additive = true
						select_requested.emit(self, true)
						_begin_additive_gesture()
						accept_event()
						return
					var additive = event.shift_pressed
					_press_was_additive = additive
					select_requested.emit(self, additive)
					# Prepare for drag (don't start yet - wait for threshold)
					is_dragging = true
					_drag_handed_off = false
					drag_start_pos = get_global_mouse_position()
					accept_event()
			else:
				# End resize or drag
				if _loop_drag_pass > 0:
					_finish_loop_drag()
					accept_event()
				elif is_resizing:
					is_resizing = false
					_finish_resize()
					accept_event()
				elif _drag_handed_off:
					# Timeline already finished the move in its _input.
					_drag_handed_off = false
					accept_event()
				elif is_dragging:
					if not _press_was_additive:
						exclusive_click_requested.emit(self)
					is_dragging = false
					accept_event()

	elif event is InputEventMouseMotion and _loop_drag_pass > 0 and clip_instance and timeline:
		_drag_loop_point(event.shift_pressed)
		accept_event()

	elif event is InputEventMouseMotion and is_resizing and clip_instance and timeline:
		# Handle resize dragging: this clip's snapped edge sets the delta for the whole group
		var pixel_delta = (get_global_mouse_position() - resize_start_pos).x
		var tick_delta = timeline.pixels_to_ticks(pixel_delta)
		# Shift bypasses grid snap
		var free_move: bool = event.shift_pressed
		var snap_interval = 0 if free_move else timeline.get_snap_interval()
		# Minimum duration of 1 snap interval (or 1 tick if no snap)
		var min_duration = snap_interval if snap_interval > 0 else 1
		var delta := _snapped_resize_delta(tick_delta, free_move)
		for clip_ui in _resize_group:
			if is_instance_valid(clip_ui):
				clip_ui._resize_by(delta, min_duration)

		accept_event()

	elif event is InputEventMouseMotion and is_dragging and clip_instance and timeline:
		if (get_global_mouse_position() - drag_start_pos).length() > drag_threshold:
			# Hand the move to the Timeline: a cross-track move frees this node mid-drag.
			is_dragging = false
			_drag_handed_off = true
			drag_begin_requested.emit(self, drag_start_pos)
		accept_event()


## The 1-based divider under local x `x`, or 0.
func _loop_boundary_pass_at(x: float) -> int:
	if timeline == null:
		return 0
	for i in _loop_boundaries.size():
		if absf(timeline.ticks_to_pixels(_loop_boundaries[i]) - x) <= LOOP_GRAB_PX:
			return i + 1
	return 0


## Start dragging the loop point that ends divider `pass_index`. A pass of 1 is the loop end
## itself; later dividers are whole loop lengths further on.
func _begin_loop_drag(pass_index: int) -> void:
	_loop_drag_pass = pass_index
	_loop_drag_start_content = clip_instance.clip.content_length_ticks if clip_instance.clip else 0


## Move the dragged divider to the pointer: the loop length changes, the clip's own length doesn't.
func _drag_loop_point(free_move: bool) -> void:
	var inst := clip_instance
	var local_tick: int = timeline.pixels_to_ticks(get_local_mouse_position().x)
	if not free_move:
		local_tick = timeline.grid_helper.snap_ticks(inst.start_ticks + local_tick) - inst.start_ticks
	# Divider k sits k loop lengths after the loop start, minus the trim
	var new_length := int(round(float(inst.clip_offset + local_tick - inst.loop_start_ticks) / float(_loop_drag_pass)))
	new_length = maxi(1, new_length)
	var clip := inst.clip
	if clip and clip.type == Clip.ClipType.MIDI:
		# Past the end of the notes the clip itself grows; pulling back gives the growth up again
		clip.set_content_length(maxi(_loop_drag_start_content, inst.loop_start_ticks + new_length))
	elif clip:
		# Audio can't grow, so the loop stops at the end of the file
		new_length = mini(new_length, maxi(1, inst.content_end_ticks() - inst.loop_start_ticks))
	inst.set_loop(true, inst.loop_start_ticks, new_length)
	_update_waveform()
	clip_renderer.queue_redraw()


## Record the loop-point drag as one undo step.
func _finish_loop_drag() -> void:
	_loop_drag_pass = 0
	var new_state := clip_instance.get_loop_state()
	var clip_length := clip_instance.clip.content_length_ticks if clip_instance.clip else 0
	if new_state != _loop_drag_start_state or clip_length != _loop_drag_start_content:
		HistoryUtil.record(ClipInstanceTransformCommand.new(
			"Move Loop Point", clip_instance,
			clip_instance.start_ticks, clip_instance.duration_ticks, clip_instance.clip_offset,
			clip_instance.start_ticks, clip_instance.duration_ticks, clip_instance.clip_offset,
			_loop_drag_start_state, new_state,
			_loop_drag_start_content,
			clip_instance.clip.content_length_ticks if clip_instance.clip else -1))
	_loop_drag_start_state = []


## Every selected clip when this one is part of a multi-selection, else just this clip.
func _find_resize_group() -> Array[TimelineClip]:
	var group: Array[TimelineClip] = [self]
	var manager = timeline.clip_selection_manager if timeline else null
	if manager == null or not clip_instance:
		return group
	var selected: Array[ClipInstance] = manager.get_selected_instances()
	if selected.size() < 2 or not selected.has(clip_instance):
		return group
	for instance in selected:
		var clip_ui: TimelineClip = manager.get_clip_ui(instance)
		if clip_ui and clip_ui != self:
			group.append(clip_ui)
	return group


## Remember this clip's placement before a resize of `edge` ("left" or "right").
func _begin_resize(edge: String) -> void:
	resize_edge = edge
	resize_padding_added = 0
	if clip_instance:
		resize_start_ticks = clip_instance.start_ticks
		resize_start_duration = clip_instance.duration_ticks
		resize_start_offset = clip_instance.clip_offset
		resize_start_loop = clip_instance.get_loop_state()
		resize_start_content_length = clip_instance.clip.content_length_ticks if clip_instance.clip else 0


## Pointer movement of `tick_delta` as an edge delta, snapped so this clip's edge lands on the grid.
func _snapped_resize_delta(tick_delta: int, free_move: bool) -> int:
	var edge_ticks := resize_start_ticks
	if resize_edge == "right":
		edge_ticks += resize_start_duration
	var new_edge := edge_ticks + tick_delta
	if not free_move:
		new_edge = timeline.grid_helper.snap_ticks(new_edge)
	return new_edge - edge_ticks


## Move this clip's resize edge `delta` ticks from where it started, clamped to its neighbours
## and to `min_duration`.
func _resize_by(delta: int, min_duration: int) -> void:
	if not clip_instance:
		return
	if resize_edge == "left":
		# Resize from left: adjust start_ticks, duration, and clip_offset
		var new_start_ticks = max(0, resize_start_ticks + delta)

		# Clamp to avoid collisions - find the nearest clip on the left
		# Use the original resize start position as reference
		var left_limit = _find_nearest_clip_left(resize_start_ticks)
		new_start_ticks = max(left_limit, new_start_ticks)

		# The original end point stays fixed
		var original_end_ticks = resize_start_ticks + resize_start_duration
		var new_duration = max(min_duration, original_end_ticks - new_start_ticks)

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
		var new_duration = max(min_duration, resize_start_duration + delta)

		# Clamp to avoid collisions - find the nearest clip on the right
		# Use the original resize end position as reference
		var original_end = resize_start_ticks + resize_start_duration
		var right_limit = _find_nearest_clip_right(original_end)
		var max_duration = right_limit - resize_start_ticks
		new_duration = min(new_duration, max_duration)
		new_duration = max(min_duration, new_duration)

		# Update clip instance
		clip_instance.set_duration(new_duration)
		_extend_clip_to(new_duration, resize_start_content_length)
		_update_from_clip_instance()


## Grow a MIDI clip's length so the instance's end is inside it, never below `start_length`
## (so dragging the edge back undoes the growth). Audio can't grow, and a looping instance
## repeats its content rather than lengthening it.
func _extend_clip_to(instance_end_ticks: int, start_length: int) -> void:
	var clip := clip_instance.clip
	if clip == null or clip.type != Clip.ClipType.MIDI or clip_instance.loop_enabled:
		return
	var wanted := maxi(start_length, clip_instance.clip_offset + instance_end_ticks)
	if wanted != clip.content_length_ticks:
		clip.set_content_length(wanted)


## Record the group's resize as one undo step and clear the resize state.
func _finish_resize() -> void:
	var cmds: Array[Command] = []
	for clip_ui in _resize_group:
		if not is_instance_valid(clip_ui):
			continue
		var inst: ClipInstance = clip_ui.clip_instance
		clip_ui.resize_edge = ""
		if inst and (
			inst.start_ticks != clip_ui.resize_start_ticks
			or inst.duration_ticks != clip_ui.resize_start_duration
			or inst.clip_offset != clip_ui.resize_start_offset
			or inst.get_loop_state() != clip_ui.resize_start_loop
			or (inst.clip and inst.clip.content_length_ticks != clip_ui.resize_start_content_length)
		):
			cmds.append(ClipInstanceTransformCommand.new(
				"Resize Clip",
				inst,
				clip_ui.resize_start_ticks, clip_ui.resize_start_duration, clip_ui.resize_start_offset,
				inst.start_ticks, inst.duration_ticks, inst.clip_offset,
				clip_ui.resize_start_loop, inst.get_loop_state(),
				clip_ui.resize_start_content_length,
				inst.clip.content_length_ticks if inst.clip else -1
			))
	_resize_group.clear()
	HistoryUtil.record_many("Resize Clips", cmds)


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
		logger.debug("Before padding: %d notes in clip %s" % [clip.midi_notes.size(), clip.id])
		for note in clip.midi_notes:
			logger.debug("  Note %d: start=%d" % [note.id, note.start_tick])

		# Shift all MIDI notes forward
		for note in clip.midi_notes:
			note.start_tick += padding_ticks

		# Increase clip content length
		clip.content_length_ticks += padding_ticks

		# Notify the clip that it has been modified (triggers update_note OSC calls)
		for note in clip.midi_notes:
			clip.update_midi_note(note)

		logger.debug("After padding: Added %d ticks to clip %s (new length: %d)" %
			[padding_ticks, clip.id, clip.content_length_ticks])
		for note in clip.midi_notes:
			logger.debug("  Note %d: start=%d" % [note.id, note.start_tick])
	
	elif clip.type == Clip.ClipType.AUDIO:
		# For audio clips, we'd need to prepend silence samples
		# This is more complex and requires reprocessing waveforms
		# For now, we'll just prevent negative offsets for audio clips
		push_warning("[TimelineClip] Audio clip padding not yet implemented - clamping to 0")
		# TODO: Implement audio padding by prepending silence samples
