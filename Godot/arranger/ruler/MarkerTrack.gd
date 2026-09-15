# MarkerTrack.gd
# Lane for song markers. Double-click or right-click > Add Marker on empty space creates a marker
# (spanning the arranger time range when one is set); right-click a marker for its menu.
# Double-click-and-hold places like a note: the new marker follows the mouse (Shift drags only its
# end) and is committed, carving overlapped markers, on release. Escape cancels the placement.
class_name MarkerTrack extends Control

const MarkerItemScene := preload("res://arranger/ruler/MarkerItem.tscn")
const MarkerContextMenuScene := preload("res://arranger/ruler/MarkerContextMenu.tscn")
const DEFAULT_MARKER_BEATS := 4
const ADDITIVE_DRAG_THRESHOLD := 6.0
const DOUBLE_CLICK_THRESHOLD := 0.3
const MAX_MARKER_TICK := 999999999
const RENAME_ON_CREATE_SETTING := "arranger/markers/rename_on_create"

signal marker_created(marker: SongMarker)
## Ctrl/Cmd click without drag: set arranger time-range start (same as beat ruler).
signal selection_start_requested(ticks: int)
## Ctrl/Cmd drag: begin full-height box select at timeline content X.
signal box_select_started(content_x: float)

@export var default_marker_beats: int = DEFAULT_MARKER_BEATS
@export var bg_color: Color = Color(0.15, 0.15, 0.15, 1.0)

var grid_helper: GridHelper = null
var project: Project = null
## Arranger selection; its time range (when both edges are set) becomes the new marker's range.
var selection_manager: ClipSelectionManager = null

var _marker_items: Dictionary = {}  # SongMarker -> MarkerItem
var _last_click_time: float = 0.0
var _additive_pending: bool = false
var _additive_press_pos: Vector2 = Vector2.ZERO
var _lane_menu: PopupMenu = null
var _lane_menu_x: float = 0.0
var _marker_menu: MarkerContextMenu = null

## Marker being placed by a double-click drag: in the project for display, not yet in history.
var _placing_marker: SongMarker = null
var _place_resizing: bool = false
## Mouse X and marker range where the current place mode (move or Shift-resize) began.
var _place_origin_x: float = 0.0
var _place_origin_start: int = 0
var _place_origin_duration: int = 0


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.y = 24
	if not resized.is_connected(_on_grid_changed):
		resized.connect(_on_grid_changed)

	_lane_menu = PopupMenu.new()
	_lane_menu.add_item("Add Marker", 0)
	_lane_menu.id_pressed.connect(func(_id: int): _create_marker_at_x(_lane_menu_x))
	add_child(_lane_menu)

	_marker_menu = MarkerContextMenuScene.instantiate() as MarkerContextMenu
	_marker_menu.visible = false
	add_child(_marker_menu)
	_marker_menu.add_marker_requested.connect(_on_add_marker_requested)
	_marker_menu.split_requested.connect(_on_split_requested)
	_marker_menu.delete_requested.connect(_on_delete_requested)
	_marker_menu.rename_requested.connect(_on_rename_requested)


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
	_placing_marker = null
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
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if _is_pointer_over_marker():
		return

	if event.button_index == MOUSE_BUTTON_RIGHT:
		_lane_menu_x = event.position.x
		_lane_menu.popup(Rect2(get_global_mouse_position() - Vector2.ONE * 10, Vector2.ZERO))
		accept_event()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	if event.ctrl_pressed or event.meta_pressed:
		start_additive_gesture(event.position.x)
		accept_event()
		return

	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_click_time < DOUBLE_CLICK_THRESHOLD:
		_last_click_time = 0.0
		_begin_place_marker(event.position.x)
		accept_event()
	else:
		_last_click_time = now


func _input(event: InputEvent) -> void:
	if _placing_marker:
		_handle_place_input(event)
	elif _additive_pending:
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


## Range (start, duration) for a new marker at track-local X: the arranger time range when set
## and X falls inside it, else the default length from the snapped position.
func _new_marker_range(local_x: float) -> Vector2i:
	var start_ticks := _snapped_ticks_from_local(local_x)
	var duration := default_marker_beats * grid_helper.get_ticks_per_beat()
	if selection_manager:
		var time_range := selection_manager.get_full_range()
		var click_ticks := grid_helper.pixels_to_ticks(_content_x_from_local(local_x))
		if time_range.y > time_range.x and click_ticks >= time_range.x and click_ticks < time_range.y:
			start_ticks = time_range.x
			duration = time_range.y - time_range.x
	return Vector2i(start_ticks, duration)


## Create a marker at track-local X (or over the arranger time range when X is inside it).
func _create_marker_at_x(local_x: float) -> void:
	if project == null or grid_helper == null:
		return
	var r := _new_marker_range(local_x)
	_on_marker_created(MarkerActions.create_marker(project, r.x, r.y))


## Show a new marker at track-local X that follows the mouse until the button is released.
func _begin_place_marker(local_x: float) -> void:
	var r := _new_marker_range(local_x)
	var marker := project.create_marker(r.x, r.y, MarkerActions.unique_name(project, MarkerActions.DEFAULT_NAME))
	project.add_marker(marker)
	_placing_marker = marker
	_rebase_place_drag(local_x)


func _handle_place_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_finish_place_marker()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_place_marker()
		get_viewport().set_input_as_handled()
	elif not is_visible_in_tree():
		_finish_place_marker()
	elif event is InputEventMouseMotion or (event is InputEventKey and event.keycode == KEY_SHIFT):
		_update_place_drag()
		get_viewport().set_input_as_handled()


## Start a move (or Shift-resize) segment from the current mouse X and marker range.
func _rebase_place_drag(local_x: float) -> void:
	_place_origin_x = local_x
	_place_origin_start = _placing_marker.start_ticks
	_place_origin_duration = _placing_marker.duration_ticks
	_place_resizing = Input.is_key_pressed(KEY_SHIFT)


## Move the placed marker with the mouse, or drag only its end while Shift is held.
## Overlaps are allowed until release, when the range is carved out of the other markers.
func _update_place_drag() -> void:
	var local_x := get_local_mouse_position().x
	if Input.is_key_pressed(KEY_SHIFT) != _place_resizing:
		_rebase_place_drag(local_x)
	var tick_delta := grid_helper.pixels_to_ticks(local_x - _place_origin_x)
	var min_duration := grid_helper.get_ticks_per_beat()
	if _place_resizing:
		var end_ticks := grid_helper.snap_ticks(_place_origin_start + _place_origin_duration + tick_delta)
		_placing_marker.set_range(_place_origin_start, end_ticks - _place_origin_start, min_duration)
	else:
		# Snap the delta so a time-range marker keeps its offset from the grid.
		var new_start := _place_origin_start + grid_helper.snap_ticks(tick_delta)
		_placing_marker.set_range(new_start, _place_origin_duration, min_duration)


func _finish_place_marker() -> void:
	var marker := _placing_marker
	_placing_marker = null
	MarkerActions.commit_marker(project, marker)
	_on_marker_created(marker)


func _cancel_place_marker() -> void:
	var marker := _placing_marker
	_placing_marker = null
	project.remove_marker(marker)


func _on_marker_created(marker: SongMarker) -> void:
	if marker == null:
		return
	marker_created.emit(marker)
	if Settings.get_value(RENAME_ON_CREATE_SETTING):
		call_deferred("_begin_edit_for_marker", marker)


func _on_item_context_menu_requested(marker: SongMarker, global_pos: Vector2) -> void:
	if marker == null or grid_helper == null:
		return
	var local_x := global_pos.x - get_global_rect().position.x
	_marker_menu.bind_to_marker(marker, _snapped_ticks_from_local(local_x))
	# Nudge so the cursor sits inside the panel; a corner popup closes on mouse-up.
	_marker_menu.popup(Rect2(global_pos - Vector2(8, 8), _marker_menu.get_contents_minimum_size()))


func _on_add_marker_requested(marker: SongMarker, tick: int) -> void:
	_on_marker_created(MarkerActions.add_marker_at_split(project, marker, tick))


func _on_split_requested(marker: SongMarker, tick: int) -> void:
	MarkerActions.split_marker(project, marker, tick)


func _on_rename_requested(marker: SongMarker, new_name: String) -> void:
	MarkerActions.rename_marker(project, marker, new_name)


func _on_delete_requested(marker: SongMarker) -> void:
	MarkerActions.delete_marker(project, marker)


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
	if not item.context_menu_requested.is_connected(_on_item_context_menu_requested):
		item.context_menu_requested.connect(_on_item_context_menu_requested)
	_marker_items[marker] = item


func _remove_marker_ui(marker: SongMarker) -> void:
	var item: MarkerItem = _marker_items.get(marker)
	if item == null:
		return
	_marker_items.erase(marker)
	if item.range_gesture_finished.is_connected(_on_item_range_gesture_finished):
		item.range_gesture_finished.disconnect(_on_item_range_gesture_finished)
	if item.context_menu_requested.is_connected(_on_item_context_menu_requested):
		item.context_menu_requested.disconnect(_on_item_context_menu_requested)
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


## Clamp a move keeping duration fixed: the marker stays inside the gap it occupied at gesture
## start (between the lane start / previous marker end and the next marker start).
func clamp_marker_move(marker: SongMarker, new_start: int, gesture_start: int, duration: int) -> int:
	if grid_helper:
		new_start = grid_helper.snap_ticks(new_start)
	var left_limit := nearest_marker_end_left(marker, gesture_start)
	var right_limit := nearest_marker_start_right(marker, gesture_start + duration)
	new_start = mini(new_start, right_limit - duration)
	return maxi(new_start, left_limit)


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
