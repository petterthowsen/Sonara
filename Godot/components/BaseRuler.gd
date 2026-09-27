# BaseRuler.gd
# Shared chrome and interaction for timeline rulers, used by the arranger and the note editor:
# background, colours, GridHelper binding, context regions, the selection band, the
# start-position arrow, click-drag scrubbing and the Ctrl/Cmd time-range gestures.
# Subclasses draw their own lines in _draw_ruler() and choose how a click snaps in
# _snapped_ticks_from_local().
#
# All ticks here are in the ruler's own space: song ticks in the arranger and the note
# editor's track mode, clip-content ticks in its clip mode. Owners convert.
@tool
class_name BaseRuler extends Control

## Click or drag on the ruler to move start position (and playhead, via listeners).
signal start_position_requested(ticks: int)
## Ctrl/Cmd click without drag: set the time-range start.
signal selection_start_requested(ticks: int)
## Ctrl/Cmd drag: begin a full-height box select at timeline content X.
signal box_select_started(content_x: float)

enum VerticalAlignment { TOP, BOTTOM }

const ADDITIVE_DRAG_THRESHOLD := 6.0

# Visual settings
@export var bg_color: Color = Color(0.15, 0.15, 0.15):
	set(value):
		if bg_color != value:
			bg_color = value
			queue_redraw()

@export var text_color: Color = Color(0.9, 0.9, 0.9):
	set(value):
		if text_color != value:
			text_color = value
			queue_redraw()

@export var start_position_color: Color = Color(0.2, 0.6, 1.0):  # Blue for start position arrow
	set(value):
		if start_position_color != value:
			start_position_color = value
			queue_redraw()

## Fill and edge colour of the time-range selection band.
@export var selection_color: Color = Color(0.4, 0.8, 1.0, 0.18):
	set(value):
		if selection_color != value:
			selection_color = value
			queue_redraw()

@export var selection_edge_color: Color = Color(0.4, 0.8, 1.0, 0.85):
	set(value):
		if selection_edge_color != value:
			selection_edge_color = value
			queue_redraw()

@export var font_size: int = 12:
	set(value):
		if font_size != value:
			font_size = value
			queue_redraw()

@export var offset_x: float = 0.0:  # Horizontal draw offset (e.g., for piano keyboard width)
	set(value):
		if offset_x != value:
			offset_x = value
			queue_redraw()

## Which edge the shorter tick lines hang from.
@export var vertical_alignment = VerticalAlignment.BOTTOM:
	set(value):
		if vertical_alignment != value:
			vertical_alignment = value
			queue_redraw()

## When true, Ctrl/Cmd click sets the range start and Ctrl/Cmd drag starts a box select.
@export var enable_time_range_gestures: bool = false

# Grid helper for calculations
var grid_helper: GridHelper = GridHelper.new()
var start_position_ticks: int = 0
## Hide the start arrow (e.g. an owner with nothing to point at).
var show_start_position: bool = true:
	set(value):
		if show_start_position != value:
			show_start_position = value
			queue_redraw()

## Coloured background spans, e.g. the edited clip or the tracks' clips. Each entry is
## {start: int, end: int, color: Color, edges: bool}; `edges` adds solid boundary lines.
var regions: Array = []

## Time-range selection, drawn as a band. selection_start < 0 hides it; an end at or
## before the start draws only the start line.
var selection_start: int = -1
var selection_end: int = -1

var _additive_pending: bool = false
var _additive_press_pos: Vector2 = Vector2.ZERO
var _scrubbing: bool = false
var _last_scrub_ticks: int = -1


func _ready() -> void:
	if not grid_helper:
		grid_helper = GridHelper.new()


## Use a shared GridHelper and redraw whenever it changes.
func set_grid_helper(gh: GridHelper) -> void:
	if grid_helper and grid_helper.changed.is_connected(queue_redraw):
		grid_helper.changed.disconnect(queue_redraw)
	grid_helper = gh
	if grid_helper:
		grid_helper.changed.connect(queue_redraw)


## Utility for callers without a GridHelper; the helper's `changed` signal triggers the redraw.
func update(scroll: float, zoom: float) -> void:
	grid_helper.pixels_per_beat = zoom
	grid_helper.scroll_position = scroll


## Update start position and redraw.
func set_start_position(ticks: int) -> void:
	if start_position_ticks != ticks:
		start_position_ticks = ticks
		queue_redraw()


## Replace the background regions (see `regions`).
func set_regions(new_regions: Array) -> void:
	if regions != new_regions:
		regions = new_regions
		queue_redraw()


## Show a time-range band from start to end, or only a start line when end <= start.
## Pass start < 0 to hide it.
func set_selection_range(start: int, end: int) -> void:
	if selection_start != start or selection_end != end:
		selection_start = start
		selection_end = end
		queue_redraw()


func _draw() -> void:
	var sb_normal := get_theme_stylebox("normal", "Ruler")
	if sb_normal:
		draw_style_box(sb_normal, Rect2(0, 0, size.x, size.y))
	else:
		draw_rect(Rect2(0, 0, size.x, size.y), bg_color)

	if grid_helper:
		_draw_regions()
		_draw_selection()
		_draw_ruler()
		if show_start_position:
			_draw_start_position_arrow()


## Draw the ruler's lines and labels. Override in subclasses.
func _draw_ruler() -> void:
	pass


## Ruler-local X of a tick in the ruler's space.
func _tick_to_local_x(ticks: int) -> float:
	return grid_helper.ticks_to_pixels(ticks) - grid_helper.scroll_position + offset_x


## Fill each region's visible span; clipped to the drawable area right of offset_x.
func _draw_regions() -> void:
	for r in regions:
		var x0 := maxf(_tick_to_local_x(int(r.start)), maxf(offset_x, 0.0))
		var x1 := minf(_tick_to_local_x(int(r.end)), size.x)
		if x1 <= x0:
			continue
		var color: Color = r.color
		draw_rect(Rect2(x0, 0.0, x1 - x0, size.y), color, true)
		if r.get("edges", false):
			var edge := Color(color.r, color.g, color.b, 1.0)
			for ex in [_tick_to_local_x(int(r.start)), _tick_to_local_x(int(r.end))]:
				if ex >= offset_x and ex <= size.x:
					draw_rect(Rect2(roundf(ex) - 1.0, 0.0, 2.0, size.y), edge, true)


func _draw_selection() -> void:
	if selection_start < 0:
		return
	var sx := _tick_to_local_x(selection_start)
	if selection_end > selection_start:
		var ex := _tick_to_local_x(selection_end)
		var x0 := maxf(sx, offset_x)
		var x1 := minf(ex, size.x)
		if x1 > x0:
			draw_rect(Rect2(x0, 0.0, x1 - x0, size.y), selection_color, true)
		if ex >= offset_x and ex <= size.x:
			draw_line(Vector2(ex, 0.0), Vector2(ex, size.y), selection_edge_color, 2.0)
	if sx >= offset_x and sx <= size.x:
		draw_line(Vector2(sx, 0.0), Vector2(sx, size.y), selection_edge_color, 2.0)


## Draw a tick line at `x` covering `height_fraction` of the ruler, hanging from `vertical_alignment`.
func _draw_tick_line(x: float, height_fraction: float, color: Color) -> void:
	var line_height := size.y * height_fraction
	var start_y := 0.0 if vertical_alignment == VerticalAlignment.TOP else size.y - line_height
	# Pixel-snapped like GridRenderer so ruler ticks sit over the grid lines below.
	draw_rect(Rect2(roundf(x), start_y, 1.0, line_height), color, true, -1.0, false)


## Draw the start-position arrow (pointing up from the bottom edge) with a short stem.
func _draw_start_position_arrow() -> void:
	var start_arrow_color := get_theme_color("start_arrow_color", "Ruler")
	if not has_theme_color("start_arrow_color", "Ruler"):
		start_arrow_color = start_position_color

	var start_pixel_x := _tick_to_local_x(start_position_ticks)
	if start_pixel_x < offset_x or start_pixel_x > size.x:
		return

	var arrow_width := 8.0
	var arrow_height := 10.0
	var points := PackedVector2Array([
		Vector2(start_pixel_x, size.y),  # Tip
		Vector2(start_pixel_x - arrow_width / 2.0, size.y - arrow_height),
		Vector2(start_pixel_x + arrow_width / 2.0, size.y - arrow_height),
	])
	draw_colored_polygon(points, start_arrow_color)

	# Stem from the arrow base up to max(10 px, half the ruler height)
	var line_height := maxf(10.0, size.y * 0.5)
	draw_line(Vector2(start_pixel_x, size.y - arrow_height), Vector2(start_pixel_x, size.y - line_height), start_position_color, 1.0, true)


## Convert a ruler-local X into timeline content pixels (scroll + offset accounted for).
func _content_x_from_local(local_x: float) -> float:
	return grid_helper.scroll_position + local_x - offset_x


## Ticks a ruler-local X snaps to when clicked. Subclasses pick their own grid.
func _snapped_ticks_from_local(local_x: float) -> int:
	if not grid_helper:
		return 0
	return maxi(grid_helper.snap_ticks(grid_helper.pixels_to_ticks(_content_x_from_local(local_x))), 0)


# ============================================================================
# INPUT: click-drag scrubs the start position; Ctrl/Cmd click or drag sets a time range
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not grid_helper or event.position.x < offset_x:
			return

		if enable_time_range_gestures and (event.ctrl_pressed or event.meta_pressed):
			_additive_pending = true
			_additive_press_pos = event.position
			get_tree().root.set_input_as_handled()
			return

		_begin_scrub(event.position.x)
		get_tree().root.set_input_as_handled()


## Finish a pending Ctrl/Cmd click, hand a drag to box-select, or scrub playhead/start.
func _input(event: InputEvent) -> void:
	if _additive_pending:
		_handle_additive_input(event)
		return

	if _scrubbing:
		_handle_scrub_input(event)


## Resolve a pending Ctrl/Cmd click or start a full-height box select after a drag.
func _handle_additive_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		selection_start_requested.emit(_snapped_ticks_from_local(_additive_press_pos.x))
		_additive_pending = false
		get_tree().root.set_input_as_handled()
		return

	if not is_visible_in_tree():
		_additive_pending = false
		return

	if event is InputEventMouseMotion:
		var local_pos := get_local_mouse_position()
		if local_pos.distance_to(_additive_press_pos) > ADDITIVE_DRAG_THRESHOLD:
			box_select_started.emit(_content_x_from_local(_additive_press_pos.x))
			_additive_pending = false
			get_tree().root.set_input_as_handled()


## Update start/playhead while the mouse is held, then end the scrub on release.
func _handle_scrub_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_scrubbing = false
		_last_scrub_ticks = -1
		get_tree().root.set_input_as_handled()
		return

	if not is_visible_in_tree():
		_scrubbing = false
		_last_scrub_ticks = -1
		return

	if event is InputEventMouseMotion:
		_emit_scrub_ticks(get_local_mouse_position().x)
		get_tree().root.set_input_as_handled()


## Start a click-drag that moves start position and playhead together.
func _begin_scrub(local_x: float) -> void:
	_scrubbing = true
	_last_scrub_ticks = -1
	_emit_scrub_ticks(local_x)


## Emit start_position_requested only when snapped ticks change.
func _emit_scrub_ticks(local_x: float) -> void:
	var ticks := _snapped_ticks_from_local(local_x)
	if ticks == _last_scrub_ticks:
		return
	_last_scrub_ticks = ticks
	start_position_requested.emit(ticks)
