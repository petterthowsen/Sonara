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

# Signal when user clicks to set start position
signal start_position_requested(ticks: int)

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
					draw_line(Vector2(x, size.y - line_height), Vector2(x, size.y), beat_line_color, 1.0, true)
				
				GridHelper.GridLineType.SUBDIVISION:
					# Draw subdivision line (quarter height)
					var line_height = size.y * 0.25
					draw_line(Vector2(x, size.y - line_height), Vector2(x, size.y), subdivision_line_color, 1.0, true)

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

func _gui_input(event: InputEvent) -> void:
	"""Handle ruler clicks to set start position (snapped to grid)."""
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not grid_helper:
			return

		# Get click position relative to ruler
		var click_x = event.position.x


		# Convert from screen coordinates to timeline pixels (accounting for scroll)
		var timeline_pixel_x = grid_helper.scroll_position + click_x

		# TODO: Doesn't grid_helper have a snap function?
		# Get grid lines in a range around the click (±100 pixels for snapping)
		var snap_range = 100.0
		var start_x = timeline_pixel_x - snap_range
		var end_x = timeline_pixel_x + snap_range
		var grid_lines = grid_helper.get_visible_grid_lines(start_x, end_x)

		# Find the nearest grid line
		var nearest_grid_x = timeline_pixel_x
		var min_distance = snap_range + 1.0

		for grid_line in grid_lines:
			var distance = abs(grid_line.x - timeline_pixel_x)
			if distance < min_distance:
				min_distance = distance
				nearest_grid_x = grid_line.x

		# Convert snapped position to ticks
		var snapped_ticks = grid_helper.pixels_to_ticks(int(nearest_grid_x))

		# Emit signal to request start position change
		start_position_requested.emit(snapped_ticks)
		get_tree().root.set_input_as_handled()
