# AutomationLaneRow.gd
# The timeline-side row for one automation lane: draws the lane's curve and points (the Timeline
# draws its fill, grid and border along with every other row's), and owns the direct-manipulation input - double-click to insert
# (and keep dragging the new point), drag to move, shift-click / shift-drag to add or remove
# points, drag on empty space to box-select, ctrl-drag to select a grid-snapped time range,
# right-click for the point menu (REQ-013, REQ-018, REQ-019, REQ-020).
#
# Built in code rather than from a .tscn, like TimelineTrack, which Timeline also instantiates
# with `.new()`.
#
# Value <-> pixel mapping: value 1.0 sits at `V_PADDING` from the top and 0.0 at `V_PADDING` from
# the bottom, so a point at either extreme is still fully drawn inside the row.
class_name AutomationLaneRow extends Control

var logger: Log = Log.make("AutomationLaneRow")

## Row fill and bottom border, drawn by Timeline._draw. The fill is only a fallback: the Timeline
## paints the lane in its track's lane color. The grid uses the Timeline's grid colors.
@export var bg_color: Color = Color(0.09, 0.09, 0.09, 1.0)
@export var border_color: Color = Color(0, 0, 0, 1)

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
enum BoxMode {
	FREE,    ## Plain drag: select the points inside the rectangle.
	RANGE,   ## Ctrl-drag: full-height, grid-snapped time range, like the clip range gesture.
	TOGGLE,  ## Shift-drag: flip the points inside the rectangle in the existing selection.
}
var _box_active: bool = false
var _box_mode: BoxMode = BoxMode.FREE
var _box_start: Vector2 = Vector2.ZERO
var _box_current: Vector2 = Vector2.ZERO
var _box_base_ids: Array = []              # TOGGLE: the selection when the gesture began
var _box_click_point_id: int = -1          # RANGE: point under a ctrl-press, toggled if it never moves

var _hover_point_id: int = -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	clip_contents = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_set_hover(-1)
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
	if lane:
		_draw_range()
		_draw_curve()
		_draw_points()
		if not lane.resolved:
			_draw_unresolved_overlay()

	if _box_active and _box_moved():
		var box := _box_rect()
		draw_rect(box, Color(0.4, 0.8, 1.0, 0.15), true)
		draw_rect(box, Color(0.4, 0.8, 1.0, 0.6), false, 1.0)


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


## The committed time range from a ctrl-drag, while it belongs to this lane.
func _draw_range() -> void:
	if selection_manager == null or selection_manager.lane != lane or _box_active:
		return
	var full := selection_manager.get_full_range()
	if full == Vector2i.ZERO:
		return
	var x0 := tick_to_x(full.x)
	var x1 := tick_to_x(full.y)
	draw_rect(Rect2(x0, 0.0, x1 - x0, size.y), Color(0.4, 0.8, 1.0, 0.08), true)
	draw_line(Vector2(x0, 0.0), Vector2(x0, size.y), Color(0.4, 0.8, 1.0, 0.5), 1.0)
	draw_line(Vector2(x1, 0.0), Vector2(x1, size.y), Color(0.4, 0.8, 1.0, 0.5), 1.0)


func _draw_points() -> void:
	var visible_range := _visible_x_range()
	for point in lane.points:
		var x := tick_to_x(point.tick)
		if x < visible_range.x - POINT_RADIUS or x > visible_range.y + POINT_RADIUS:
			continue
		var centre := Vector2(x, value_to_y(point.value))
		var selected := selection_manager != null and selection_manager.is_selected(lane, point.id)
		var hovered := point.id == _hover_point_id
		var fill := Color.WHITE if selected else lane.color
		if hovered and not selected:
			fill = fill.lightened(0.4)
		if lane.bypassed:
			fill.a = 0.45
		draw_circle(centre, POINT_RADIUS + (1.0 if hovered else 0.0), fill)
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
		_on_lane_pressed(pos)
		var hit := _point_at(pos)

		if event.double_click:
			# Empty space inserts a point and keeps it under the cursor for dragging; on a point it
			# only re-arms the drag, so it can't stack two points on one spot.
			if hit == null:
				hit = _insert_point_at(pos)
			if hit != null:
				_begin_point_drag(hit, pos)
			accept_event()
			return

		if event.ctrl_pressed or event.meta_pressed:
			_begin_box(pos, BoxMode.RANGE)
			_box_click_point_id = hit.id if hit else -1
		elif event.shift_pressed:
			if hit != null:
				if selection_manager:
					selection_manager.toggle(lane, hit.id)
				# Drag what is still selected, but never a point the click just dropped.
				if selection_manager == null or selection_manager.is_selected(lane, hit.id):
					_begin_point_drag(hit, pos)
				queue_redraw()
			else:
				_begin_box(pos, BoxMode.TOGGLE)
		elif hit != null:
			if selection_manager and not selection_manager.is_selected(lane, hit.id):
				selection_manager.select_only(lane, hit.id)
			_begin_point_drag(hit, pos)
		else:
			_begin_box(pos, BoxMode.FREE)
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
		if _box_moved():
			_apply_box_select()
		queue_redraw()
		return
	if _drag_pending and pos.distance_to(_drag_start_pos) > DRAG_THRESHOLD:
		_drag_pending = false
		_drag_active = true
	if _drag_active:
		_apply_point_drag(pos)
		return
	var hover := _point_at(pos)
	_set_hover(hover.id if hover else -1)


func _set_hover(point_id: int) -> void:
	if point_id == _hover_point_id:
		return
	_hover_point_id = point_id
	queue_redraw()


## Any press in the row makes this lane the target for paste and takes the clip selection away,
## so the keyboard shortcuts act on exactly one of the two.
func _on_lane_pressed(pos: Vector2) -> void:
	if selection_manager:
		selection_manager.focus(lane)
		selection_manager.set_anchor(_snap_tick(x_to_tick(pos.x)))
	if timeline and timeline.clip_selection_manager:
		timeline.clip_selection_manager.clear_selection()


## Double-click insert: snapped tick, value straight off the cursor (REQ-018). The new point
## becomes the only selected one.
func _insert_point_at(pos: Vector2) -> AutomationPoint:
	var tick := maxi(0, _snap_tick(x_to_tick(pos.x)))
	var value := y_to_value(pos.y)
	var point: Object = AutomationActions.add_point(lane, tick, value)
	if point and selection_manager:
		selection_manager.select_only(lane, point.id)
	logger.info("Inserted point at tick %d value %.3f on lane %s" % [tick, value, lane.id])
	queue_redraw()
	return point as AutomationPoint


# ---------------------------------------------------------------------------
# Point drag
# ---------------------------------------------------------------------------

## Arm a drag of `point` (and the rest of the selection). The drag only becomes real past
## DRAG_THRESHOLD so a plain click stays a click.
func _begin_point_drag(point: AutomationPoint, pos: Vector2) -> void:
	_set_hover(-1)
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
		# A range the points were picked with no longer describes where they are.
		if selection_manager:
			selection_manager.hide_range()

	_drag_before.clear()
	_drag_point_id = -1
	queue_redraw()


# ---------------------------------------------------------------------------
# Box select
# ---------------------------------------------------------------------------

func _begin_box(pos: Vector2, mode: BoxMode) -> void:
	_box_active = true
	_box_mode = mode
	_box_start = pos
	_box_current = pos
	_box_click_point_id = -1
	_box_base_ids = []
	if mode == BoxMode.TOGGLE and selection_manager and selection_manager.lane == lane:
		_box_base_ids = selection_manager.get_selected_ids()
	_set_hover(-1)
	queue_redraw()


func _box_moved() -> bool:
	return _box_current.distance_to(_box_start) > DRAG_THRESHOLD


## (start, end) ticks of a RANGE box, both snapped to the grid.
func _range_ticks() -> Vector2i:
	var a := maxi(0, _snap_tick(x_to_tick(_box_start.x)))
	var b := maxi(0, _snap_tick(x_to_tick(_box_current.x)))
	return Vector2i(mini(a, b), maxi(a, b))


## The rectangle the box gesture covers: the raw drag for FREE/TOGGLE, and the snapped time span
## at full row height for RANGE.
func _box_rect() -> Rect2:
	if _box_mode == BoxMode.RANGE:
		var ticks := _range_ticks()
		var x0 := tick_to_x(ticks.x)
		return Rect2(x0, 0.0, tick_to_x(ticks.y) - x0, size.y)
	return Rect2(_box_start, Vector2.ZERO).expand(_box_current).abs()


## Ids of the points the box currently covers. RANGE uses the same half-open [start, end) tick
## test as `AutomationPointSelectionManager.get_operand()`, so what is highlighted is what a
## copy takes.
func _box_hit_ids() -> Array:
	var ids: Array = []
	if _box_mode == BoxMode.RANGE:
		var ticks := _range_ticks()
		for point in lane.points:
			if point.tick >= ticks.x and point.tick < ticks.y:
				ids.append(point.id)
		return ids
	var box := _box_rect()
	for point in lane.points:
		if box.has_point(Vector2(tick_to_x(point.tick), value_to_y(point.value))):
			ids.append(point.id)
	return ids


func _apply_box_select() -> void:
	if selection_manager == null:
		return
	if _box_mode == BoxMode.TOGGLE:
		selection_manager.select_toggled(lane, _box_base_ids, _box_hit_ids())
	else:
		selection_manager.select_ids(lane, _box_hit_ids())


## A box that never really moved is a click: on empty space it clears the selection (shift keeps
## it), and a ctrl-click on a point toggles it. A ctrl-drag also keeps its snapped span as the
## active time range (REQ-021).
func _finish_box_select(pos: Vector2) -> void:
	_box_active = false
	_box_current = pos
	if selection_manager:
		if not _box_moved():
			if _box_mode == BoxMode.RANGE and _box_click_point_id >= 0:
				selection_manager.toggle(lane, _box_click_point_id)
			elif _box_mode != BoxMode.TOGGLE:
				selection_manager.clear_selection()
		else:
			_apply_box_select()
			if _box_mode == BoxMode.RANGE:
				var ticks := _range_ticks()
				selection_manager.set_range(ticks.x, ticks.y)
	_box_click_point_id = -1
	_box_base_ids = []
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
