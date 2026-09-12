# Draws a ruler with vertical lines at grid positions (beats, bars, ticks)
# Shows bar numbers and beat markers
@tool
class_name Ruler extends Control

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

# Grid helper for calculations
var grid_helper: GridHelper = GridHelper.new()
var start_position_ticks: int = 0

## Click or drag on the ruler to move start position (and playhead, via listeners).
signal start_position_requested(ticks: int)
## Ctrl/Cmd click without drag: set the arranger time-range start.
signal selection_start_requested(ticks: int)
## Ctrl/Cmd drag: begin a full-height box select at timeline content X.
signal box_select_started(content_x: float)

const ADDITIVE_DRAG_THRESHOLD := 6.0
## When true, Ctrl/Cmd click-drag on this ruler drives arranger time-range selection.
@export var enable_time_range_gestures: bool = false
var _additive_pending: bool = false
var _additive_press_pos: Vector2 = Vector2.ZERO
var _scrubbing: bool = false
var _last_scrub_ticks: int = -1

enum VerticalAlignment { TOP, BOTTOM }

@export var vertical_alignment = VerticalAlignment.BOTTOM:
	set(value):
		if vertical_alignment != value:
			vertical_alignment = value
			queue_redraw()

func _ready() -> void:
	if not grid_helper:
		grid_helper = GridHelper.new()

func set_grid_helper(gh: GridHelper) -> void:
	"""Set the grid helper and connect to its signals."""
	if grid_helper and grid_helper.changed.is_connected(queue_redraw):
		grid_helper.changed.disconnect(queue_redraw)
	
	grid_helper = gh
	
	if grid_helper:
		grid_helper.changed.connect(queue_redraw)

# Utility function that delegates to GridHelper in case caller doesn't have the GridHelper
func update(scroll: float, zoom: float) -> void:
	grid_helper.pixels_per_beat = zoom
	grid_helper.scroll_position = scroll
	# We don't need to redraw here, GridHelper will emit a signal when it changes

func set_start_position(ticks: int) -> void:
	"""Update start position and redraw."""
	if start_position_ticks != ticks:
		start_position_ticks = ticks
		queue_redraw()

func _draw():
	# Draw background
	var sb_normal = get_theme_stylebox("normal", "Ruler")
	draw_style_box(sb_normal, Rect2(0, 0, size.x, size.y))

	# Draw ruler markings
	if grid_helper:
		_draw_ruler()
		_draw_start_position_arrow()

func _draw_ruler() -> void:
	"""Draw ruler with bar numbers and beat markers."""
	
	var bar_line_color = get_theme_color("bar_line_color", "Ruler")
	var beat_line_color = get_theme_color("beat_line_color", "Ruler")
	var subdivision_line_color = get_theme_color("subdivision_line_color", "Ruler")
	
	# Calculate visible range (no need to adjust for scroll - GridHelper handles it)
	var start_x = 0.0
	var end_x = size.x - offset_x
	
	# Get grid lines from helper
	var grid_lines = grid_helper.get_visible_grid_lines(start_x, end_x, offset_x)
	
	# Draw each grid line
	for line in grid_lines:
		# GridHelper already accounts for scroll position, so use line.x directly
		var x = line.x
		
		# Only draw if within visible bounds
		if x >= offset_x and x <= size.x:
			match line.type:
				GridHelper.GridLineType.BAR:
					# Draw bar line (full height)
					draw_line(Vector2(x, 0), Vector2(x, size.y), bar_line_color, 2.0, true)
					# Draw bar number
					var text = str(line.bar_number)
					draw_string(ThemeDB.fallback_font, Vector2(x + 4, size.y - 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)
				
				GridHelper.GridLineType.BEAT:
					# Draw beat line (half height)
					var line_height = size.y * 0.5
					var start_y: float
					var end_y: float
					
					match vertical_alignment:
						VerticalAlignment.TOP:
							start_y = 0.0
							end_y = line_height
						VerticalAlignment.BOTTOM:
							start_y = size.y - line_height
							end_y = size.y
					
					draw_line(Vector2(x, start_y), Vector2(x, end_y), beat_line_color, 1.0, true)
				
				GridHelper.GridLineType.SUBDIVISION:
					# Draw subdivision line (quarter height)
					var line_height = size.y * 0.25
					var start_y: float
					var end_y: float
					
					match vertical_alignment:
						VerticalAlignment.TOP:
							start_y = 0.0
							end_y = line_height
						VerticalAlignment.BOTTOM:
							start_y = size.y - line_height
							end_y = size.y
					
					draw_line(Vector2(x, start_y), Vector2(x, end_y), subdivision_line_color, 1.0, true)

func _draw_start_position_arrow() -> void:
	"""Draw blue arrow indicating the start position."""
	if not grid_helper:
		return
	
	# theme vars
	var start_arrow_color = get_theme_color("start_arrow_color", "Ruler")

	# Calculate start position x in pixels (GridHelper handles scroll position)
	var start_pixel_x = grid_helper.ticks_to_pixels(start_position_ticks) - grid_helper.scroll_position + offset_x

	# Only draw if visible in viewport
	if start_pixel_x >= offset_x and start_pixel_x <= size.x:
		# Draw a small blue triangle arrow at the bottom of the ruler (pointing up)
		var arrow_width = 8.0
		var arrow_height = 10.0

		# Create triangle points (pointing up from bottom)
		var points = PackedVector2Array([
			Vector2(start_pixel_x, size.y),  # Bottom point (tip)
			Vector2(start_pixel_x - arrow_width / 2.0, size.y - arrow_height),  # Top left
			Vector2(start_pixel_x + arrow_width / 2.0, size.y - arrow_height),  # Top right
		])

		draw_colored_polygon(points, start_arrow_color)

		# Draw a thin vertical line from arrow base to top of ruler
		# Constrain height to max(10, 50% of ruler height)
		var line_height = maxf(10.0, size.y * 0.5)
		draw_line(Vector2(start_pixel_x, size.y - arrow_height), Vector2(start_pixel_x, size.y - line_height), start_position_color, 1.0, true)

## Handle ruler clicks to set start position, or Ctrl/Cmd for time-range gestures.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not grid_helper:
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


## Convert a ruler-local X into timeline content pixels (scroll + offset accounted for).
func _content_x_from_local(local_x: float) -> float:
	return grid_helper.scroll_position + local_x - offset_x


## Snap a ruler-local X to the nearest grid tick, never before 0.
func _snapped_ticks_from_local(local_x: float) -> int:
	if not grid_helper:
		return 0
	return maxi(grid_helper.snap_ticks(grid_helper.pixels_to_ticks(_content_x_from_local(local_x))), 0)
