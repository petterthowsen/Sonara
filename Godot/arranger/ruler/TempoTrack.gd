# TempoTrack.gd
# Tempo automation lane in the ruler area. Double-click empty space to add a point, drag a point to
# move it (time snaps to the grid, tempo to whole BPM), right-click for the point menu. With no
# points it draws the project's static tempo as a flat line.
class_name TempoTrack extends Control

const POINT_RADIUS := 4.0
const POINT_HIT_RADIUS := 8.0
const V_PADDING := 8.0
## The value axis always spans at least this many BPM, so a flat tempo does not fill the lane.
const MIN_SPAN_BPM := 40.0
const LINE_COLOR := Color("#e8a33d")

@export var bg_color: Color = Color(0.10, 0.10, 0.10, 1.0)

var grid_helper: GridHelper = null
var project: Project = null

var _menu: PopupMenu = null
var _menu_point_id: int = -1
var _menu_local_pos: Vector2 = Vector2.ZERO
var _hover_id: int = -1

var _drag_id: int = -1
var _drag_before: Array[Dictionary] = []
var _drag_moved: bool = false
## Value axis frozen at the start of a drag, so the lane does not rescale under the cursor.
var _frozen_range: Vector2 = Vector2.ZERO


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.y = 56

	_menu = PopupMenu.new()
	_menu.theme_type_variation = &"ContextMenuList"
	_menu.id_pressed.connect(_on_menu_id_pressed)
	add_child(_menu)


func set_grid_helper(gh: GridHelper) -> void:
	if grid_helper and grid_helper.changed.is_connected(queue_redraw):
		grid_helper.changed.disconnect(queue_redraw)
	grid_helper = gh
	if grid_helper and not grid_helper.changed.is_connected(queue_redraw):
		grid_helper.changed.connect(queue_redraw)
	queue_redraw()


## Bind to a project's tempo map; pass null to clear.
func bind_project(p: Project) -> void:
	if project and project.tempo_map.changed.is_connected(queue_redraw):
		project.tempo_map.changed.disconnect(queue_redraw)
	project = p
	if project and not project.tempo_map.changed.is_connected(queue_redraw):
		project.tempo_map.changed.connect(queue_redraw)
	_drag_id = -1
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT and _drag_id < 0:
		_set_hover(-1)


# ============================================================================
# COORDINATES
# ============================================================================

## BPM range shown by the lane: the tempo points plus the static tempo, with headroom.
func _value_range() -> Vector2:
	if _drag_id >= 0:
		return _frozen_range
	var lo := project.tempo
	var hi := project.tempo
	for p in project.tempo_map.points:
		lo = minf(lo, p["bpm"])
		hi = maxf(hi, p["bpm"])
	var pad := maxf((MIN_SPAN_BPM - (hi - lo)) * 0.5, (hi - lo) * 0.2)
	return Vector2(maxf(0.0, lo - pad), hi + pad)


func _bpm_to_y(bpm: float, r: Vector2) -> float:
	var t := (bpm - r.x) / maxf(r.y - r.x, 0.001)
	return lerpf(size.y - V_PADDING, V_PADDING, t)


func _y_to_bpm(y: float, r: Vector2) -> float:
	var t := (size.y - V_PADDING - y) / maxf(size.y - 2.0 * V_PADDING, 1.0)
	return snappedf(TempoMap.clamp_bpm(lerpf(r.x, r.y, t)), 1.0)


func _tick_to_x(tick: int) -> float:
	return grid_helper.ticks_to_pixels(tick) - grid_helper.scroll_position


func _x_to_tick(x: float) -> int:
	return maxi(0, grid_helper.pixels_to_ticks(x + grid_helper.scroll_position))


func _point_at(pos: Vector2) -> int:
	var r := _value_range()
	var best := -1
	var best_dist := POINT_HIT_RADIUS
	for p in project.tempo_map.points:
		var d := Vector2(_tick_to_x(p["tick"]), _bpm_to_y(p["bpm"], r)).distance_to(pos)
		if d <= best_dist:
			best_dist = d
			best = p["id"]
	return best


# ============================================================================
# DRAWING
# ============================================================================

func _draw() -> void:
	var sb := get_theme_stylebox("normal", "Ruler")
	if sb:
		draw_style_box(sb, Rect2(0, 0, size.x, size.y))
	else:
		draw_rect(Rect2(0, 0, size.x, size.y), bg_color)
	if project == null or grid_helper == null:
		return

	for line in grid_helper.get_visible_grid_lines(0.0, size.x):
		if line.type == GridHelper.GridLineType.BAR:
			draw_line(Vector2(line.x, 0), Vector2(line.x, size.y), Color(1, 1, 1, 0.08))

	var map := project.tempo_map
	var r := _value_range()
	var font := get_theme_default_font()
	var font_size := 10

	if map.is_empty():
		var y := _bpm_to_y(project.tempo, r)
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(LINE_COLOR, 0.45), 1.0)
		draw_string(font, Vector2(6, y - 4), "%s BPM" % _fmt(project.tempo),
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(LINE_COLOR, 0.7))
		return

	var pts := PackedVector2Array()
	pts.append(Vector2(0, _bpm_to_y(map.points[0]["bpm"], r)))
	for p in map.points:
		pts.append(Vector2(_tick_to_x(p["tick"]), _bpm_to_y(p["bpm"], r)))
	pts.append(Vector2(size.x, _bpm_to_y(map.points[map.points.size() - 1]["bpm"], r)))
	draw_polyline(pts, LINE_COLOR, 1.5, true)

	for p in map.points:
		var c := Vector2(_tick_to_x(p["tick"]), _bpm_to_y(p["bpm"], r))
		if c.x < -POINT_RADIUS or c.x > size.x + POINT_RADIUS:
			continue
		var active: bool = p["id"] == _hover_id or p["id"] == _drag_id
		draw_circle(c, POINT_RADIUS + (1.5 if active else 0.0), LINE_COLOR if active else Color("#2a2a2a"))
		draw_arc(c, POINT_RADIUS, 0.0, TAU, 16, LINE_COLOR, 1.5, true)
		if active:
			draw_string(font, c + Vector2(8, -6), _fmt(p["bpm"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


func _fmt(bpm: float) -> String:
	return "%d" % roundi(bpm) if is_equal_approx(bpm, roundf(bpm)) else "%.1f" % bpm


# ============================================================================
# INPUT
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if project == null or grid_helper == null:
		return
	if event is InputEventMouseMotion:
		if _drag_id >= 0:
			_drag_to(event.position)
		else:
			_set_hover(_point_at(event.position))
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_on_left_pressed(event)
			else:
				_end_drag()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_open_menu(event.position)
			accept_event()


func _on_left_pressed(event: InputEventMouseButton) -> void:
	var hit := _point_at(event.position)
	if hit < 0 and event.double_click:
		_begin_drag_new(event.position)
	elif hit >= 0:
		_begin_drag(hit)
	accept_event()


func _begin_drag(point_id: int) -> void:
	_frozen_range = _value_range()
	_drag_before = project.tempo_map.snapshot()
	_drag_id = point_id
	_drag_moved = false


func _begin_drag_new(pos: Vector2) -> void:
	var r := _value_range()
	var before := project.tempo_map.snapshot()
	var tick := grid_helper.snap_ticks(_x_to_tick(pos.x))
	var id := project.tempo_map.add_point(tick, _y_to_bpm(pos.y, r))
	_begin_drag(id)
	_drag_before = before
	_drag_moved = true


func _drag_to(pos: Vector2) -> void:
	var tick := grid_helper.snap_ticks(_x_to_tick(pos.x))
	project.tempo_map.update_point(_drag_id, tick, _y_to_bpm(pos.y, _frozen_range))
	_drag_moved = true


func _end_drag() -> void:
	if _drag_id < 0:
		return
	var label := "Move Tempo Point"
	_drag_id = -1
	if _drag_moved:
		var after := project.tempo_map.snapshot()
		if after != _drag_before:
			if after.size() > _drag_before.size():
				label = "Add Tempo Point"
			HistoryUtil.record(TempoMapStateCommand.new(label, project.tempo_map, _drag_before, after))
	queue_redraw()


func _set_hover(point_id: int) -> void:
	if _hover_id != point_id:
		_hover_id = point_id
		queue_redraw()


# ============================================================================
# CONTEXT MENU
# ============================================================================

func _open_menu(pos: Vector2) -> void:
	_menu_local_pos = pos
	_menu_point_id = _point_at(pos)
	_menu.clear()
	if _menu_point_id >= 0:
		_menu.add_item("Delete Point", 0)
	else:
		_menu.add_item("Add Point", 1)
	if not project.tempo_map.is_empty():
		_menu.add_item("Clear Tempo Automation", 2)
	_menu.popup(Rect2(get_global_mouse_position() - Vector2.ONE * 10, Vector2.ZERO))


func _on_menu_id_pressed(id: int) -> void:
	var map := project.tempo_map
	var before := map.snapshot()
	var label := ""
	match id:
		0:
			map.remove_point(_menu_point_id)
			label = "Delete Tempo Point"
		1:
			var tick := grid_helper.snap_ticks(_x_to_tick(_menu_local_pos.x))
			map.add_point(tick, _y_to_bpm(_menu_local_pos.y, _value_range()))
			label = "Add Tempo Point"
		2:
			map.restore([])
			label = "Clear Tempo Automation"
	HistoryUtil.record(TempoMapStateCommand.new(label, map, before, map.snapshot()))
