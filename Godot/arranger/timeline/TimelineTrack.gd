# TimelineTrack.gd
#
# Draws vertical lines across itself and contains audio/midi clip nodes
@tool
class_name TimelineTrack extends Control

# Signals
signal empty_area_clicked(ticks: int, pixels: float)
signal selection_changed(selected_clips: Array[ClipInstance])  # Emitted when selection changes in this track
signal deselect_other_tracks_requested  # Request to deselect all other tracks before selecting in this one
signal clip_drag_started(source_track: Track, selected_clip_uis: Array, selected_instances: Array[ClipInstance])  # Cross-track drag initiated
signal clip_drag_moved(global_position: Vector2)  # Cross-track drag position update
signal clip_drag_ended(global_position: Vector2)  # Cross-track drag ended

@export var grid_color_bar: Color = "#000":
	set(value):
		grid_color_bar = value
		queue_redraw()

@export var grid_color_beat: Color = "#151515":
	set(value):
		grid_color_beat = value
		queue_redraw()

@export var grid_color_tick: Color = "#353535":
	set(value):
		grid_color_tick = value
		queue_redraw()

@export var bg_color: Color = "#555":
	set(value):
		bg_color = value
		queue_redraw()

@export_group("Border")
@export var border_color: Color = Color(0.15, 0.15, 0.15, 0.3):
	set(value):
		border_color = value
		queue_redraw()

@export var border_thickness: float = 1.0:
	set(value):
		border_thickness = value
		queue_redraw()

@export_group("")

# Data binding
var track: Track = null
var track_index: int = -1

# Timeline reference for grid drawing (also provides shared grid_helper)
var timeline: Timeline = null

# Clip UI instances
const TimelineClipScene = preload("res://arranger/timeline/clip/TimelineClip.tscn")
var clip_instances: Array = []  # Array of TimelineClip instances
var selected_clips: Array = []  # Array of selected TimelineClip instances (multi-select)

func _ready():
	mouse_filter = Control.MOUSE_FILTER_PASS


func _gui_input(event: InputEvent) -> void:
	"""Handle input events on the timeline track."""
	# Middle mouse button events will naturally bubble up to Arranger for panning
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# Check if we clicked on a clip < is this needed? I think TimlineClips swallow the event
			var clicked_on_clip = false
			for clip_instance in clip_instances:
				if clip_instance and clip_instance.get_rect().has_point(event.position):
					clicked_on_clip = true
					break

			if not clicked_on_clip:
				# Clicked on empty area - deselect all (in this track and others)
				deselect_other_tracks_requested.emit()
				_deselect_all()
				_emit_selection_changed()

				if timeline:
					var click_ticks = timeline.pixels_to_ticks(event.position.x)

					# Snap to grid (use timeline's grid_helper)
					if timeline.grid_helper:
						click_ticks = timeline.grid_helper.snap_ticks(click_ticks)

					empty_area_clicked.emit(click_ticks, event.position.x)

				# Double-click creates a clip
				if event.double_click:
					_on_double_click(event.position)

func bind_to_track(t: Track, idx: int) -> void:
	"""Bind this timeline track to a Track data object and listen for changes."""
	# Disconnect from old track if any
	if track:
		if track.height_changed.is_connected(_on_track_height_changed):
			track.height_changed.disconnect(_on_track_height_changed)
		if track.clip_instance_added.is_connected(_on_clip_instance_added):
			track.clip_instance_added.disconnect(_on_clip_instance_added)
		if track.clip_instance_removed.is_connected(_on_clip_instance_removed):
			track.clip_instance_removed.disconnect(_on_clip_instance_removed)

	track = t
	track_index = idx

	# Connect to track signals
	if track:
		track.height_changed.connect(_on_track_height_changed)
		track.clip_instance_added.connect(_on_clip_instance_added)
		track.clip_instance_removed.connect(_on_clip_instance_removed)

	# Update UI from track data
	_update_from_track()

func _update_from_track() -> void:
	"""Update all UI elements from track data."""
	if track == null:
		return

	# Set minimum height to match track height
	custom_minimum_size.y = track.height

	# Create clip instances for all clips in track
	_update_clips()

	queue_redraw()


func _on_track_height_changed(new_height: int) -> void:
	"""React to track height changes."""
	custom_minimum_size.y = new_height
	_update_clip_sizes(new_height)  # Resize clips to match new track height

func _update_clips() -> void:
	"""Create/update TimelineClip UI instances for all clip instances in the track."""
	if track == null or timeline == null:
		return

	# Clear existing UI clip instances
	for clip_ui in clip_instances:
		if clip_ui:
			clip_ui.queue_free()
	clip_instances.clear()
	selected_clips.clear()

	# Create new UI instances for each ClipInstance in the track
	for clip_inst in track.clip_instances:
		var clip_ui = TimelineClipScene.instantiate()
		add_child(clip_ui)
		clip_ui.bind_to_clip_instance(clip_inst, timeline, track.color)

		# Connect signals
		clip_ui.select_requested.connect(_on_clip_select_requested)
		clip_ui.clip_move_requested.connect(_on_clip_move_requested)
		clip_ui.drag_started.connect(_on_clip_drag_started)
		clip_ui.drag_moved.connect(_on_clip_drag_moved)
		clip_ui.drag_ended.connect(_on_clip_drag_ended)

		clip_instances.append(clip_ui)

	# Update clip sizes after they're added to the tree
	await get_tree().process_frame
	_update_clip_sizes()

func _update_clip_sizes(height: int = -1) -> void:
	"""Update the size of all clip instances to match track height."""
	# Use provided height, or fall back to current size.y
	var clip_height = height if height > 0 else int(size.y)
	for clip_instance in clip_instances:
		if clip_instance:
			clip_instance.custom_minimum_size.y = clip_height
			clip_instance.size.y = clip_height

func _update_clip_positions() -> void:
	"""Update positions and widths of all clips based on current zoom."""
	for clip_ui in clip_instances:
		if clip_ui and clip_ui.clip_instance and timeline:
			var inst = clip_ui.clip_instance
			var start_x = timeline.ticks_to_pixels(inst.start_ticks)
			var width = timeline.ticks_to_pixels(inst.duration_ticks)

			clip_ui.position.x = start_x
			clip_ui.custom_minimum_size.x = width
			clip_ui.size.x = width

# ============================================================================
# CLIP INTERACTION
# ============================================================================

func _on_clip_select_requested(clip_ui: Node, add_to_selection: bool) -> void:
	"""Handle clip selection request (shift-aware)."""
	print("[TimelineTrack] Clip select requested")
	print("  - clip_ui: ", clip_ui)
	print("  - add_to_selection: ", add_to_selection)
	
	if not add_to_selection:
		# Normal click: deselect all OTHER tracks first, then deselect clips in this track
		deselect_other_tracks_requested.emit()
		_deselect_all()
		_select_clip(clip_ui)
	else:
		# Shift+click: toggle this clip in selection
		if clip_ui in selected_clips:
			_deselect_clip(clip_ui)
		else:
			_select_clip(clip_ui)

	# Emit selection changed signal
	_emit_selection_changed()


func _select_clip(clip_ui: Node) -> void:
	"""Add a clip to the selection."""
	if clip_ui not in selected_clips:
		selected_clips.append(clip_ui)
		clip_ui.set_selected(true)


func _deselect_clip(clip_ui: Node) -> void:
	"""Remove a clip from the selection."""
	if clip_ui in selected_clips:
		selected_clips.erase(clip_ui)
		clip_ui.set_selected(false)


func _deselect_all() -> void:
	"""Deselect all clips."""
	for clip_ui in selected_clips:
		clip_ui.set_selected(false)
	selected_clips.clear()


func _emit_selection_changed() -> void:
	"""Emit selection changed signal with currently selected clip instances."""
	print("[TimelineTrack] _emit_selection_changed called")
	print("  - track: ", track.id if track else "null")
	print("  - selected_clips count: ", selected_clips.size())
	
	var selected_instances: Array[ClipInstance] = []
	for clip_ui in selected_clips:
		if clip_ui.clip_instance:
			selected_instances.append(clip_ui.clip_instance)
			print("  - Adding clip instance: ", clip_ui.clip_instance.clip_id)

	print("  - Emitting selection_changed with ", selected_instances.size(), " instances")
	selection_changed.emit(selected_instances)

func _on_clip_move_requested(clip_ui: Node, new_start_ticks: int) -> void:
	"""Handle clip move request."""
	if clip_ui.clip_instance:
		# Update clip instance position (ClipInstance has setters that emit signals and sync to engine)
		clip_ui.clip_instance.set_position(new_start_ticks)

		# Update visual position
		var new_x = timeline.ticks_to_pixels(new_start_ticks)
		clip_ui.position.x = new_x

func _on_clip_drag_started(clip_ui: Node, clip_instance: ClipInstance) -> void:
	"""Handle cross-track drag start - drag the entire selection."""
	# Emit drag started with all selected clips
	var selected_instances: Array[ClipInstance] = []
	for clip_ui_item in selected_clips:
		if clip_ui_item.clip_instance:
			selected_instances.append(clip_ui_item.clip_instance)

	clip_drag_started.emit(track, selected_clips, selected_instances)


func _on_clip_drag_moved(clip_ui: Node, global_position: Vector2) -> void:
	"""Handle cross-track drag movement."""
	clip_drag_moved.emit(global_position)


func _on_clip_drag_ended(clip_ui: Node, global_position: Vector2) -> void:
	"""Handle cross-track drag end."""
	clip_drag_ended.emit(global_position)


# ============================================================================
# DRAWING
# ============================================================================

func _draw():
	# Draw background
	var col = bg_color
	if Sonara.get_config("appearence/color_timeline_by_track", true):
		col = Color.from_hsv(track.color.h, track.color.s, bg_color.v)
		col.a = 0.5

	draw_rect(Rect2(Vector2(0, 0), size), col, true, -1.0, false)
	
	# Draw grid lines
	if timeline and Sonara and Sonara.editor and Sonara.editor.project:
		_draw_grid()
	
	# Draw bottom border
	if border_thickness > 0:
		var border_y = size.y - border_thickness
		draw_rect(Rect2(0, border_y, size.x, border_thickness), border_color, true)
	
	# TODO: Draw clips

func _draw_grid() -> void:
	"""Draw vertical grid lines using GridHelper."""
	if not timeline or not timeline.grid_helper:
		return
	
	# Calculate visible range (in local coordinates)
	var start_x = 0.0
	var end_x = size.x
	
	# Get grid lines from shared grid_helper
	# use_scroll = false because TimelineTrack is inside a ScrollContainer
	# which automatically handles the viewport translation
	var grid_lines = timeline.grid_helper.get_visible_grid_lines(start_x, end_x, 0.0, false)
	
	# Draw each grid line
	for line in grid_lines:
		var x = line.x
		
		# Only draw if within visible area
		if x >= 0.0 and x <= size.x:
			match line.type:
				GridHelper.GridLineType.BAR:
					draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color_bar, 2.0)
				
				GridHelper.GridLineType.BEAT:
					draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color_beat, 1.0)
				
				GridHelper.GridLineType.SUBDIVISION:
					draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color_tick, 1.0)

# ============================================================================
# INPUT HANDLING
# ============================================================================

func _on_double_click(pos: Vector2) -> void:
	"""Handle double-click to create a clip instance."""
	if not timeline or not Sonara or not Sonara.editor or not Sonara.editor.project:
		return

	if track_index < 0 or track == null:
		return

	var project = Sonara.editor.project

	# Convert click position to ticks
	var click_ticks = timeline.pixels_to_ticks(pos.x)

	# Snap to grid using shared GridHelper
	var snapped_ticks = click_ticks
	if timeline and timeline.grid_helper:
		snapped_ticks = timeline.grid_helper.snap_ticks(click_ticks)

	# Create a new Clip in the project's clip pool
	var clip_type = Clip.ClipType.MIDI if track.type == Track.TrackType.INSTRUMENT else Clip.ClipType.AUDIO
	var clip_name = track.name + " %d" % (project.clips.size() + 1)
	var new_clip = project.create_clip(clip_name, clip_type)

	# Set clip properties
	new_clip.color = track.color
	new_clip.content_length_ticks = project.ppq * 4  # Default: 4 beats
	
	# Add clip to project pool (required for serialization!)
	project.add_clip(new_clip)

	# Create a ClipInstance on this track
	var ppq = project.ppq
	var instance = track.create_clip_instance(new_clip, snapped_ticks, ppq * 4)

	# UI will be updated automatically via clip_instance_added signal


# ============================================================================
# DRAG AND DROP SUPPORT (Asset drops from Browser)
# ============================================================================

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	"""Accept Asset drops from Browser."""
	return data is Asset


func _drop_data(at_position: Vector2, data: Variant) -> void:
	"""Create clip from dropped Asset."""
	if not data is Asset:
		return

	if not track or not Sonara or not Sonara.editor or not Sonara.editor.project:
		print("[TimelineTrack] Drop failed: missing dependencies")
		return

	var asset = data as Asset
	var project = Sonara.editor.project

	# Convert drop position to timeline ticks
	if not timeline:
		print("[TimelineTrack] Drop failed: no timeline reference")
		return

	var drop_ticks = timeline.pixels_to_ticks(at_position.x)

	# Snap to grid using shared GridHelper
	if timeline and timeline.grid_helper:
		drop_ticks = timeline.grid_helper.snap_ticks(drop_ticks)

	# Create clip from asset
	var clip = project.create_clip_from_asset(asset, track.color)

	# Create instance on this track
	# Use the clip's actual content length for audio clips, or default for MIDI
	var instance_duration = clip.content_length_ticks if clip.type == Clip.ClipType.AUDIO else project.ppq * 4
	var instance = track.create_clip_instance(clip, drop_ticks, instance_duration)

	# UI will be updated automatically via clip_instance_added signal

	# Mark asset as used
	AssetService.mark_asset_used(asset.path)

	print("[TimelineTrack] Created %s clip from: %s" % [
		"audio" if asset.is_audio() else "MIDI",
		asset.get_display_name()
	])


# ============================================================================
# TRACK SIGNAL HANDLERS
# ============================================================================

func _on_clip_instance_added(instance: ClipInstance) -> void:
	"""Handle when a clip instance is added to the track (via data layer)."""
	# Create UI for this specific clip instance
	var clip_ui = TimelineClipScene.instantiate()
	add_child(clip_ui)
	clip_ui.bind_to_clip_instance(instance, timeline, track.color)

	# Connect signals
	clip_ui.select_requested.connect(_on_clip_select_requested)
	clip_ui.clip_move_requested.connect(_on_clip_move_requested)
	clip_ui.drag_started.connect(_on_clip_drag_started)
	clip_ui.drag_moved.connect(_on_clip_drag_moved)
	clip_ui.drag_ended.connect(_on_clip_drag_ended)

	clip_instances.append(clip_ui)

	# Set size to match track height
	var clip_height = int(size.y) if size.y > 0 else 60
	clip_ui.custom_minimum_size.y = clip_height
	clip_ui.size.y = clip_height


func _on_clip_instance_removed(instance: ClipInstance) -> void:
	"""Handle when a clip instance is removed from the track (via data layer)."""
	# Find and remove the UI for this specific clip instance
	for i in range(clip_instances.size() - 1, -1, -1):
		var clip_ui = clip_instances[i]
		if clip_ui and clip_ui.clip_instance == instance:
			# Deselect if it was selected
			if clip_ui in selected_clips:
				selected_clips.erase(clip_ui)
			clip_ui.queue_free()
			clip_instances.remove_at(i)
			break
