# MarkerTrack.gd
# Lane for song markers; double-click empty space to add a marker at the playhead grid.
class_name MarkerTrack extends Control

const MarkerItemScene := preload("res://arranger/ruler/MarkerItem.tscn")
const DEFAULT_MARKER_BEATS := 4
const ADDITIVE_DRAG_THRESHOLD := 6.0
const DOUBLE_CLICK_THRESHOLD := 0.3
const MAX_MARKER_TICK := 999999999

signal marker_created(marker: SongMarker)
## Ctrl/Cmd click without drag: set arranger time-range start (same as beat ruler).
signal selection_start_requested(ticks: int)
## Ctrl/Cmd drag: begin full-height box select at timeline content X.
signal box_select_started(content_x: float)

@export var default_marker_beats: int = DEFAULT_MARKER_BEATS
@export var bg_color: Color = Color(0.15, 0.15, 0.15, 1.0)

var grid_helper: GridHelper = null
var project: Project = null

var _marker_items: Dictionary = {}  # SongMarker -> MarkerItem
var _last_click_time: float = 0.0
var _additive_pending: bool = false
var _additive_press_pos: Vector2 = Vector2.ZERO


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.y = 24
	if not resized.is_connected(_on_grid_changed):
		resized.connect(_on_grid_changed)


func _draw() -> void:
	var sb_normal := get_theme_stylebox("normal", "Ruler")
	if sb_normal:
		draw_style_box(sb_normal, Rect2(0, 0, size.x, size.y))
	else:
		draw_rect(Rect2(0, 0, size.x, size.y), bg_color)


## Attach shared grid helper used by the arranger timeline.
func set_grid_helper(gh: GridHelper) -> void:
	if grid_helper:
		if grid_helper.changed.is_connected(_on_grid_changed):
			grid_helper.changed.disconnect(_on_grid_changed)
		if grid_helper.changed.is_connected(queue_redraw):
			grid_helper.changed.disconnect(queue_redraw)
	grid_helper = gh
	if grid_helper and not grid_helper.changed.is_connected(_on_grid_changed):
		grid_helper.changed.connect(_on_grid_changed)
	if grid_helper and not grid_helper.changed.is_connected(queue_redraw):
		grid_helper.changed.connect(queue_redraw)


## Bind to project marker list; pass null to clear.
func bind_project(p: Project) -> void:
	if project:
		if project.marker_added.is_connected(_on_marker_added):
			project.marker_added.disconnect(_on_marker_added)
		if project.marker_removed.is_connected(_on_marker_removed):
			project.marker_removed.disconnect(_on_marker_removed)
	_clear_items()
	project = p
	if project:
		if not project.marker_added.is_connected(_on_marker_added):
			project.marker_added.connect(_on_marker_added)
		if not project.marker_removed.is_connected(_on_marker_removed):
			project.marker_removed.connect(_on_marker_removed)
		for marker in project.markers:
			_add_marker_ui(marker)
		_refresh_all_layouts()


func _gui_input(event: InputEvent) -> void:
	if project == null or grid_helper == null:
		return
	if not (event is InputEventMouseButton):
		return
	if event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
		return
	if _is_pointer_over_marker():
		return

	if event.ctrl_pressed or event.meta_pressed:
		start_additive_gesture(event.position.x)
		accept_event()
		return

	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_click_time < DOUBLE_CLICK_THRESHOLD:
		_last_click_time = 0.0
		_create_marker_at_x(event.position.x)
		accept_event()
	else:
		_last_click_time = now


func _input(event: InputEvent) -> void:
	if _additive_pending:
		_handle_additive_input(event)


## Begin Ctrl/Cmd range gesture at track-local X (markers or empty lane).
func start_additive_gesture(local_x: float) -> void:
	_additive_pending = true
	_additive_press_pos = Vector2(local_x, 0.0)


func _handle_additive_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		selection_start_requested.emit(_snapped_ticks_from_local(_additive_press_pos.x))
		_additive_pending = false
		get_viewport().set_input_as_handled()
		return

	if not is_visible_in_tree():
		_additive_pending = false
		return

	if event is InputEventMouseMotion:
		var local_pos := get_local_mouse_position()
		if local_pos.distance_to(_additive_press_pos) > ADDITIVE_DRAG_THRESHOLD:
			box_select_started.emit(_content_x_from_local(_additive_press_pos.x))
			_additive_pending = false
			get_viewport().set_input_as_handled()


func _content_x_from_local(local_x: float) -> float:
	if grid_helper:
		return grid_helper.scroll_position + local_x
	return local_x


func _snapped_ticks_from_local(local_x: float) -> int:
	if not grid_helper:
		return 0
	return maxi(grid_helper.snap_ticks(grid_helper.pixels_to_ticks(_content_x_from_local(local_x))), 0)


func _create_marker_at_x(local_x: float) -> void:
	var content_x := local_x + grid_helper.scroll_position
	var start_ticks := grid_helper.snap_ticks(grid_helper.pixels_to_ticks(content_x))
	var duration := default_marker_beats * grid_helper.get_ticks_per_beat()
	var min_dur := grid_helper.get_ticks_per_beat()
	var clamped := clamp_marker_range(null, start_ticks, duration, min_dur)
	start_ticks = clamped.x
	duration = clamped.y
	if duration < min_dur:
		return
	var marker := project.create_marker(start_ticks, duration)
	HistoryUtil.execute(MarkerCreateCommand.new(project, marker))
	marker_created.emit(marker)
	call_deferred("_begin_edit_for_marker", marker)


func _begin_edit_for_marker(marker: SongMarker) -> void:
	var item: MarkerItem = _marker_items.get(marker)
	if item:
		item.begin_name_edit()


func _is_pointer_over_marker() -> bool:
	for child in get_children():
		if child is MarkerItem and child.get_rect().has_point(get_local_mouse_position()):
			return true
	return false


func _on_marker_added(marker: SongMarker) -> void:
	_add_marker_ui(marker)
	_refresh_all_layouts()


func _on_marker_removed(marker: SongMarker) -> void:
	_remove_marker_ui(marker)


func _add_marker_ui(marker: SongMarker) -> void:
	if _marker_items.has(marker):
		return
	var item := MarkerItemScene.instantiate() as MarkerItem
	item.name = "Marker_%d" % marker.id
	add_child(item)
	item.bind(marker, grid_helper)
	if not item.range_gesture_finished.is_connected(_on_item_range_gesture_finished):
		item.range_gesture_finished.connect(_on_item_range_gesture_finished)
	_marker_items[marker] = item


func _remove_marker_ui(marker: SongMarker) -> void:
	var item: MarkerItem = _marker_items.get(marker)
	if item == null:
		return
	_marker_items.erase(marker)
	if item.range_gesture_finished.is_connected(_on_item_range_gesture_finished):
		item.range_gesture_finished.disconnect(_on_item_range_gesture_finished)
	item.queue_free()


func _on_item_range_gesture_finished(
	marker: SongMarker,
	old_start: int,
	old_duration: int,
	gesture_label: String
) -> void:
	if marker == null:
		return
	HistoryUtil.record(
		MarkerRangeCommand.new(
			gesture_label,
			marker,
			grid_helper.get_ticks_per_beat() if grid_helper else 960,
			old_start,
			old_duration,
			marker.start_ticks,
			marker.duration_ticks
		)
	)


func _on_grid_changed() -> void:
	_refresh_all_layouts()


func _refresh_all_layouts() -> void:
	for item in _marker_items.values():
		if item is MarkerItem:
			item.refresh_layout()


func _clear_items() -> void:
	for marker in _marker_items.keys():
		_remove_marker_ui(marker)


## End tick of the nearest marker strictly to the left of `before_tick` (adjacent gaps allowed).
func nearest_marker_end_left(marker: SongMarker, before_tick: int) -> int:
	var nearest := 0
	if project == null:
		return 0
	for other in project.markers:
		if other == marker:
			continue
		var other_end := other.get_end_ticks()
		if other_end <= before_tick and other_end > nearest:
			nearest = other_end
	return nearest


## Start tick of the nearest marker at or to the right of `at_or_after_tick`.
func nearest_marker_start_right(marker: SongMarker, at_or_after_tick: int) -> int:
	var nearest := MAX_MARKER_TICK
	if project == null:
		return MAX_MARKER_TICK
	for other in project.markers:
		if other == marker:
			continue
		var other_start := other.start_ticks
		if other_start >= at_or_after_tick and other_start < nearest:
			nearest = other_start
	return nearest


## Clamp so [start, start + duration) does not overlap other markers (`marker` excluded).
func clamp_marker_range(
	marker: SongMarker,
	start: int,
	duration: int,
	min_duration: int
) -> Vector2i:
	var new_start := maxi(0, start)
	var new_duration := maxi(min_duration, duration)
	if project == null:
		return Vector2i(new_start, new_duration)

	var guard := 0
	while guard < project.markers.size() + 2:
		guard += 1
		var left_limit := nearest_marker_end_left(marker, new_start)
		new_start = maxi(left_limit, new_start)

		var new_end := new_start + new_duration
		var right_limit := nearest_marker_start_right(marker, new_end)
		if new_end > right_limit:
			new_end = right_limit
			new_duration = new_end - new_start
			if new_duration < min_duration:
				new_duration = min_duration
				new_start = new_end - new_duration
				left_limit = nearest_marker_end_left(marker, new_start)
				new_start = maxi(left_limit, new_start)
				new_duration = maxi(min_duration, new_end - new_start)

		var blocker := _first_overlapping_marker(marker, new_start, new_duration)
		if blocker == null:
			break
		new_start = blocker.get_end_ticks()

	return Vector2i(new_start, new_duration)


func _first_overlapping_marker(
	marker: SongMarker,
	start: int,
	duration: int
) -> SongMarker:
	if project == null:
		return null
	var end := start + duration
	for other in project.markers:
		if other == marker:
			continue
		if start < other.get_end_ticks() and other.start_ticks < end:
			return other
	return null


## Clamp a move keeping duration fixed (uses gesture-start duration).
func clamp_marker_move(marker: SongMarker, new_start: int, duration: int, min_duration: int) -> int:
	if grid_helper:
		new_start = grid_helper.snap_ticks(new_start)
	var clamped := clamp_marker_range(marker, new_start, duration, min_duration)
	return clamped.x


## Clamp left-edge resize; `fixed_end` is the end tick at gesture start.
func clamp_marker_left_resize(
	marker: SongMarker,
	new_start: int,
	fixed_end: int,
	neighbor_ref_start: int,
	min_duration: int
) -> Vector2i:
	if grid_helper:
		new_start = grid_helper.snap_ticks(new_start)
	new_start = mini(new_start, fixed_end - min_duration)
	new_start = maxi(0, new_start)
	var left_limit := nearest_marker_end_left(marker, neighbor_ref_start)
	new_start = maxi(left_limit, new_start)
	var new_duration := fixed_end - new_start
	new_duration = maxi(min_duration, new_duration)
	new_start = fixed_end - new_duration
	new_start = maxi(left_limit, new_start)
	new_duration = fixed_end - new_start
	return Vector2i(new_start, new_duration)


## Clamp right-edge resize; `fixed_start` is the start tick at gesture start.
func clamp_marker_right_resize(
	marker: SongMarker,
	fixed_start: int,
	new_end: int,
	neighbor_ref_end: int,
	min_duration: int
) -> int:
	if grid_helper:
		new_end = grid_helper.snap_ticks(new_end)
	var right_limit := nearest_marker_start_right(marker, neighbor_ref_end)
	new_end = mini(new_end, right_limit)
	var new_duration := new_end - fixed_start
	return maxi(min_duration, new_duration)
