# AutomationLaneRow.gd
# The timeline-side row for one automation lane: draws the grid the way TimelineTrack does, draws
# the lane's curve and points, and owns the direct-manipulation input - double-click to insert,
# drag to move, ctrl-click and box-select, right-click for the point menu
# (REQ-013, REQ-018, REQ-019, REQ-020).
#
# Built in code rather than from a .tscn, like TimelineTrack, which Timeline also instantiates
# with `.new()`.
#
# Value <-> pixel mapping: value 1.0 sits at `V_PADDING` from the top and 0.0 at `V_PADDING` from
# the bottom, so a point at either extreme is still fully drawn inside the row.
class_name AutomationLaneRow extends Control

var logger: Log = Log.make("AutomationLaneRow")

## Grid colors, matching TimelineTrack so the two row kinds line up visually.
@export var grid_color_bar: Color = Color("#000")
@export var grid_color_beat: Color = Color("#151515")
@export var grid_color_tick: Color = Color("#353535")
@export var bg_color: Color = Color(0.09, 0.09, 0.09, 1.0)
@export var border_color: Color = Color(0.15, 0.15, 0.15, 0.3)

const V_PADDING := 5.0
const POINT_RADIUS := 4.0
const POINT_HIT_RADIUS := 7.0
const CURVE_WIDTH := 1.5
## Pixels a tension-warped segment is sampled at. A straight linear segment needs no sampling.
const CURVE_SAMPLE_PX := 6.0
const DRAG_THRESHOLD := 3.0

var lane: AutomationLane = null
var track: Track = null
var timeline: Timeline = null

## Shared with the clip lanes so a point drag and a clip drag snap identically.
var selection_manager: AutomationPointSelectionManager = null

var _context_menu: AutomationPointContextMenu = null

# --- point drag state ---
var _drag_active: bool = false
var _drag_pending: bool = false
var _drag_point_id: int = -1
var _drag_start_pos: Vector2 = Vector2.ZERO
var _drag_before: Dictionary = {}          # point id -> {tick, value, curve, tension}
var _drag_anchor_tick: int = 0
var _drag_anchor_value: float = 0.0

# --- box select state ---
var _box_active: bool = false
var _box_start: Vector2 = Vector2.ZERO
var _box_current: Vector2 = Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	clip_contents = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
	elif what == NOTIFICATION_PREDELETE:
		_unbind()


# ============================================================================
# BINDING
# ============================================================================

func bind_to_lane(p_lane: AutomationLane, p_track: Track, p_timeline: Timeline) -> void:
	_unbind()

	lane = p_lane
	track = p_track
	timeline = p_timeline
	if timeline:
		selection_manager = timeline.automation_selection_manager

	if lane:
		lane.point_added.connect(_on_lane_changed_point)
		lane.point_changed.connect(_on_lane_changed_point)
		lane.point_removed.connect(_on_lane_point_removed)
		lane.bypass_changed.connect(_on_lane_flag_changed)
		lane.height_changed.connect(_on_lane_height_changed)
		lane.resolved_changed.connect(_on_lane_flag_changed)
		custom_minimum_size.y = lane.height

	queue_redraw()


func _unbind() -> void:
	if lane:
		if lane.point_added.is_connected(_on_lane_changed_point):
			lane.point_added.disconnect(_on_lane_changed_point)
		if lane.point_changed.is_connected(_on_lane_changed_point):
			lane.point_changed.disconnect(_on_lane_changed_point)
		if lane.point_removed.is_connected(_on_lane_point_removed):
			lane.point_removed.disconnect(_on_lane_point_removed)
		if lane.bypass_changed.is_connected(_on_lane_flag_changed):
			lane.bypass_changed.disconnect(_on_lane_flag_changed)
		if lane.height_changed.is_connected(_on_lane_height_changed):
			lane.height_changed.disconnect(_on_lane_height_changed)
		if lane.resolved_changed.is_connected(_on_lane_flag_changed):
			lane.resolved_changed.disconnect(_on_lane_flag_changed)
	lane = null
	track = null
	timeline = null


func _on_lane_changed_point(_point: AutomationPoint) -> void:
	queue_redraw()


func _on_lane_point_removed(point_id: int) -> void:
	if selection_manager:
		selection_manager.forget_point(lane, point_id)
	queue_redraw()


func _on_lane_flag_changed(_value: bool) -> void:
	queue_redraw()


func _on_lane_height_changed(new_height: int) -> void:
	custom_minimum_size.y = new_height
	size.y = new_height
	queue_redraw()


# ============================================================================
# GEOMETRY
# ============================================================================

## Vertical span the 0.0..1.0 value range maps onto.
func _value_span() -> float:
	return maxf(1.0, size.y - V_PADDING * 2.0)


func value_to_y(value: float) -> float:
	return V_PADDING + (1.0 - clampf(value, 0.0, 1.0)) * _value_span()


func y_to_value(y: float) -> float:
	return clampf(1.0 - (y - V_PADDING) / _value_span(), 0.0, 1.0)


func tick_to_x(tick: int) -> float:
	return timeline.ticks_to_pixels(tick) if timeline else 0.0


func x_to_tick(x: float) -> int:
	return timeline.pixels_to_ticks(x) if timeline else 0


func _snap_tick(tick: int) -> int:
	if timeline and timeline.grid_helper:
		return timeline.grid_helper.snap_ticks(tick)
	return tick


## The point whose drawn handle contains `local_pos`, or null. Searched back to front so the
## topmost of two overlapping points wins.
func _point_at(local_pos: Vector2) -> AutomationPoint:
	if lane == null:
		return null
	for i in range(lane.points.size() - 1, -1, -1):
		var point: AutomationPoint = lane.points[i]
		var centre := Vector2(tick_to_x(point.tick), value_to_y(point.value))
		if centre.distance_to(local_pos) <= POINT_HIT_RADIUS:
			return point
	return null


# ============================================================================
# DRAWING (REQ-013, REQ-018)
# ============================================================================

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)
	_draw_grid()

	if lane:
		_draw_curve()
		_draw_points()
		if not lane.resolved:
			_draw_unresolved_overlay()

	if _box_active:
		var box := Rect2(_box_start, Vector2.ZERO).expand(_box_current).abs()
		draw_rect(box, Color(0.4, 0.8, 1.0, 0.15), true)
		draw_rect(box, Color(0.4, 0.8, 1.0, 0.6), false, 1.0)

	draw_line(Vector2(0, size.y - 1), Vector2(size.x, size.y - 1), border_color, 1.0)


## Vertical grid lines, clipped to the visible scroll range exactly like
## `TimelineTrack._draw_grid()` - the row is as wide as the whole scrollable timeline, so drawing
## 0..size.x would redraw the entire song on every scroll.
func _draw_grid() -> void:
	if timeline == null or timeline.grid_helper == null:
		return
	var helper := timeline.grid_helper
	var viewport_width := timeline.get_viewport_width()
	var start_x := clampf(helper.scroll_position, 0.0, size.x)
	var end_x := clampf(helper.scroll_position + viewport_width, 0.0, size.x)
	if end_x <= start_x:
		return

	for line in helper.get_visible_grid_lines(start_x, end_x, 0.0, false):
		var x: float = line.x
		if x < 0.0 or x > size.x:
			continue
		match line.type:
			GridHelper.GridLineType.BAR:
				draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color_bar, 2.0)
			GridHelper.GridLineType.BEAT:
				draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color_beat, 1.0)
			GridHelper.GridLineType.SUBDIVISION:
				draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color_tick, 1.0)


## The lane's curve: a flat hold before the first point and after the last (REQ-006), a
## hold-then-jump for a STEP segment, and a tension-sampled ramp for a warped LINEAR one.
func _draw_curve() -> void:
	if lane.points.is_empty():
		return

	var colour := lane.color
	colour.a = 0.35 if lane.bypassed else 1.0
	var visible_range := _visible_x_range()

	var first: AutomationPoint = lane.points[0]
	var first_x := tick_to_x(first.tick)
	var first_y := value_to_y(first.value)
	if first_x > visible_range.x:
		draw_line(Vector2(visible_range.x, first_y), Vector2(first_x, first_y), colour, CURVE_WIDTH)

	for i in range(lane.points.size() - 1):
		_draw_segment(lane.points[i], lane.points[i + 1], colour, visible_range)

	var last: AutomationPoint = lane.points[lane.points.size() - 1]
	var last_x := tick_to_x(last.tick)
	var last_y := value_to_y(last.value)
	if last_x < visible_range.y:
		draw_line(Vector2(last_x, last_y), Vector2(visible_range.y, last_y), colour, CURVE_WIDTH)


func _draw_segment(left: AutomationPoint, right: AutomationPoint, colour: Color, visible_range: Vector2) -> void:
	var x0 := tick_to_x(left.tick)
	var x1 := tick_to_x(right.tick)
	if x1 < visible_range.x or x0 > visible_range.y:
		return
	var y0 := value_to_y(left.value)
	var y1 := value_to_y(right.value)

	if left.curve == AutomationPoint.CurveType.STEP:
		# Hold the left value to the right point's tick, then jump.
		draw_line(Vector2(x0, y0), Vector2(x1, y0), colour, CURVE_WIDTH)
		draw_line(Vector2(x1, y0), Vector2(x1, y1), colour, CURVE_WIDTH)
		return

	if left.tension == 0.0:
		draw_line(Vector2(x0, y0), Vector2(x1, y1), colour, CURVE_WIDTH)
		return

	# A warped ramp is sampled through the SHARED evaluator, so the drawn shape is the one the
	# engine plays (REQ-005). No phase-1 gesture writes tension, but a hand-edited file can.
	var steps := clampi(int((x1 - x0) / CURVE_SAMPLE_PX), 2, 128)
	var previous := Vector2(x0, y0)
	for step in range(1, steps + 1):
		var t := float(step) / float(steps)
		var tick := int(round(lerpf(float(left.tick), float(right.tick), t)))
		var next := Vector2(tick_to_x(tick), value_to_y(AutomationCurve.evaluate(left, right, tick)))
		draw_line(previous, next, colour, CURVE_WIDTH)
		previous = next


func _draw_points() -> void:
	var visible_range := _visible_x_range()
	for point in lane.points:
		var x := tick_to_x(point.tick)
		if x < visible_range.x - POINT_RADIUS or x > visible_range.y + POINT_RADIUS:
			continue
		var centre := Vector2(x, value_to_y(point.value))
		var selected := selection_manager != null and selection_manager.is_selected(lane, point.id)
		var fill := Color.WHITE if selected else lane.color
		if lane.bypassed:
			fill.a = 0.45
		draw_circle(centre, POINT_RADIUS, fill)
		if selected:
			draw_arc(centre, POINT_RADIUS + 2.0, 0.0, TAU, 12, Color(0.4, 0.8, 1.0), 1.5)


## A lane whose target no longer resolves keeps every point but drives nothing (REQ-024); the
## hatch says so without hiding the data.
func _draw_unresolved_overlay() -> void:
	var range_x := _visible_x_range()
	draw_rect(Rect2(range_x.x, 0.0, range_x.y - range_x.x, size.y), Color(0.6, 0.15, 0.1, 0.18), true)


## (left, right) x pixels currently on screen, so drawing and hit-culling share one definition.
func _visible_x_range() -> Vector2:
	if timeline == null or timeline.grid_helper == null:
		return Vector2(0.0, size.x)
	var start_x := clampf(timeline.grid_helper.scroll_position, 0.0, size.x)
	var end_x := clampf(start_x + timeline.get_viewport_width(), 0.0, size.x)
	return Vector2(start_x, end_x)


# ============================================================================
# INPUT (REQ-018, REQ-019, REQ-020)
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if lane == null:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	var pos: Vector2 = event.position

	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_open_context_menu(pos)
		accept_event()
		return

	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	if event.pressed:
		if selection_manager:
			selection_manager.set_anchor(_snap_tick(x_to_tick(pos.x)))

		var hit := _point_at(pos)

		if event.double_click:
			# A double-click on empty space inserts; on a point it does nothing extra (the press
			# already selected it), so it can't accidentally stack two points on one spot.
			if hit == null:
				_insert_point_at(pos)
			accept_event()
			return

		if hit != null:
			_begin_point_drag(hit, pos, event.ctrl_pressed or event.meta_pressed)
		else:
			# Empty space: start a box select. A press that never moves clears the selection.
			_box_active = true
			_box_start = pos
			_box_current = pos
			queue_redraw()
		accept_event()
		return

	# Release.
	if _box_active:
		_finish_box_select(pos)
		accept_event()
	elif _drag_active or _drag_pending:
		_finish_point_drag()
		accept_event()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var pos: Vector2 = event.position
	if _box_active:
		_box_current = pos
		_apply_box_select()
		queue_redraw()
		return
	if _drag_pending and pos.distance_to(_drag_start_pos) > DRAG_THRESHOLD:
		_drag_pending = false
		_drag_active = true
	if _drag_active:
		_apply_point_drag(pos)


## Double-click insert: snapped tick, value straight off the cursor (REQ-018).
func _insert_point_at(pos: Vector2) -> void:
	var tick := maxi(0, _snap_tick(x_to_tick(pos.x)))
	var value := y_to_value(pos.y)
	var point: Object = AutomationActions.add_point(lane, tick, value)
	if point and selection_manager:
		selection_manager.select_only(lane, point.id)
	logger.info("Inserted point at tick %d value %.3f on lane %s" % [tick, value, lane.id])
	queue_redraw()


# ---------------------------------------------------------------------------
# Point drag
# ---------------------------------------------------------------------------

## Press on a point: update the selection, then arm a drag. The drag only becomes real past
## DRAG_THRESHOLD so a plain click stays a click.
func _begin_point_drag(point: AutomationPoint, pos: Vector2, additive: bool) -> void:
	if selection_manager:
		if additive:
			selection_manager.toggle(lane, point.id)
		elif not selection_manager.is_selected(lane, point.id):
			selection_manager.select_only(lane, point.id)

	# A ctrl-click that deselected the point must not then drag it.
	if selection_manager and not selection_manager.is_selected(lane, point.id):
		queue_redraw()
		return

	_drag_pending = true
	_drag_active = false
	_drag_point_id = point.id
	_drag_start_pos = pos
	_drag_anchor_tick = point.tick
	_drag_anchor_value = point.value
	_drag_before = AutomationActions.capture_point_states(_dragged_points())
	queue_redraw()


## The points a drag moves: the whole selection when the grabbed point is part of it.
func _dragged_points() -> Array:
	if selection_manager and selection_manager.has_selection() and selection_manager.lane == lane:
		return selection_manager.get_selected_points()
	var point := _find_point(_drag_point_id)
	return [point] if point else []


func _find_point(point_id: int) -> AutomationPoint:
	for point in lane.points:
		if point.id == point_id:
			return point
	return null


## Move every dragged point by the same tick/value delta, snapping the grabbed point horizontally
## so the group keeps its internal spacing (REQ-018).
func _apply_point_drag(pos: Vector2) -> void:
	var anchor := _find_point(_drag_point_id)
	if anchor == null:
		return

	var target_tick := maxi(0, _snap_tick(x_to_tick(pos.x)))
	var tick_delta := target_tick - _drag_anchor_tick
	var value_delta := y_to_value(pos.y) - _drag_anchor_value

	# Don't drag any point below tick 0.
	var lowest := 0
	var first := true
	for id in _drag_before:
		var start_tick: int = _drag_before[id]["tick"]
		if first or start_tick < lowest:
			lowest = start_tick
			first = false
	tick_delta = maxi(tick_delta, -lowest)

	for id in _drag_before:
		var before: Dictionary = _drag_before[id]
		lane.update_point(
			id,
			before["tick"] + tick_delta,
			clampf(before["value"] + value_delta, 0.0, 1.0)
		)
	queue_redraw()


## Commit the gesture as one mergeable history entry (REQ-022). A press that never moved just
## clears the drag state.
func _finish_point_drag() -> void:
	var was_dragging := _drag_active
	_drag_active = false
	_drag_pending = false

	if was_dragging and not _drag_before.is_empty():
		var moved: Array = []
		for id in _drag_before:
			var point := _find_point(id)
			if point:
				moved.append(point)
		if not moved.is_empty():
			AutomationActions.move_points(lane, moved, _drag_before.duplicate(), true)

	_drag_before.clear()
	_drag_point_id = -1
	queue_redraw()


# ---------------------------------------------------------------------------
# Box select
# ---------------------------------------------------------------------------

func _apply_box_select() -> void:
	if selection_manager == null:
		return
	var box := Rect2(_box_start, Vector2.ZERO).expand(_box_current).abs()
	var ids: Array = []
	for point in lane.points:
		if box.has_point(Vector2(tick_to_x(point.tick), value_to_y(point.value))):
			ids.append(point.id)
	selection_manager.select_ids(lane, ids)


## A box that never really moved is a click on empty space: clear the selection. Otherwise keep
## what the box caught and remember its grid-snapped span as the active time range (REQ-021).
func _finish_box_select(pos: Vector2) -> void:
	_box_active = false
	var moved := pos.distance_to(_box_start) > DRAG_THRESHOLD
	if selection_manager:
		if not moved:
			selection_manager.clear_selection()
			selection_manager.set_anchor(_snap_tick(x_to_tick(pos.x)))
		else:
			_apply_box_select()
			selection_manager.set_range(
				_snap_tick(x_to_tick(minf(_box_start.x, pos.x))),
				_snap_tick(x_to_tick(maxf(_box_start.x, pos.x)))
			)
	queue_redraw()


# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------

func _open_context_menu(pos: Vector2) -> void:
	var hit := _point_at(pos)
	if hit == null:
		if selection_manager:
			selection_manager.clear_selection()
		queue_redraw()
		return

	if selection_manager and not selection_manager.is_selected(lane, hit.id):
		selection_manager.select_only(lane, hit.id)

	var target_points: Array = [hit]
	if selection_manager and selection_manager.lane == lane and selection_manager.has_selection():
		target_points = selection_manager.get_selected_points()

	if _context_menu == null:
		_context_menu = AutomationPointContextMenu.new()
		add_child(_context_menu)
		_context_menu.curve_requested.connect(_on_curve_requested)
		_context_menu.delete_requested.connect(_on_delete_requested)
	_context_menu.open_for(target_points, get_global_mouse_position())


func _on_curve_requested(points: Array, curve: int) -> void:
	AutomationActions.set_curve(lane, points, curve)
	queue_redraw()


func _on_delete_requested(points: Array) -> void:
	AutomationActions.delete_points(lane, points)
	queue_redraw()


## Delete the current selection in this lane (REQ-018). Called by Timeline on the delete action.
func delete_selected_points() -> void:
	if selection_manager == null or selection_manager.lane != lane:
		return
	var points := selection_manager.get_selected_points()
	if points.is_empty():
		return
	AutomationActions.delete_points(lane, points)
	queue_redraw()
