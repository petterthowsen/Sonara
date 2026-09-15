# BaseRuler.gd
# Shared chrome for timeline rulers: background, colors, GridHelper binding, the start-position
# arrow and tick-line placement. Subclasses implement _draw_ruler() and their click handling.
@tool
class_name BaseRuler extends Control

## Click or drag on the ruler to move start position (and playhead, via listeners).
signal start_position_requested(ticks: int)

enum VerticalAlignment { TOP, BOTTOM }

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

# Grid helper for calculations
var grid_helper: GridHelper = GridHelper.new()
var start_position_ticks: int = 0


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


func _draw() -> void:
	var sb_normal := get_theme_stylebox("normal", "Ruler")
	if sb_normal:
		draw_style_box(sb_normal, Rect2(0, 0, size.x, size.y))
	else:
		draw_rect(Rect2(0, 0, size.x, size.y), bg_color)

	if grid_helper:
		_draw_ruler()
		_draw_start_position_arrow()


## Draw the ruler's lines and labels. Override in subclasses.
func _draw_ruler() -> void:
	pass


## Draw a tick line at `x` covering `height_fraction` of the ruler, hanging from `vertical_alignment`.
func _draw_tick_line(x: float, height_fraction: float, color: Color) -> void:
	var line_height := size.y * height_fraction
	var start_y := 0.0 if vertical_alignment == VerticalAlignment.TOP else size.y - line_height
	draw_line(Vector2(x, start_y), Vector2(x, start_y + line_height), color, 1.0, true)


## Draw the start-position arrow (pointing up from the bottom edge) with a short stem.
func _draw_start_position_arrow() -> void:
	var start_arrow_color := get_theme_color("start_arrow_color", "Ruler")
	if not has_theme_color("start_arrow_color", "Ruler"):
		start_arrow_color = start_position_color

	var start_pixel_x := grid_helper.ticks_to_pixels(start_position_ticks) - grid_helper.scroll_position + offset_x
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
