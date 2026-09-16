# Draws vertical lines at grid positions (beats, bars, ticks)
@tool
class_name GridRenderer extends Control

# Visual settings
@export var bar_line_color: Color = Color("777"):
	set(c):
		bar_line_color = c
		queue_redraw()

@export var beat_line_color: Color = Color("555"):
	set(blc):
		beat_line_color = blc
		queue_redraw()

@export var subdivision_line_color: Color = Color("444"):
	set(slc):
		subdivision_line_color = slc
		queue_redraw()

# Line widths in whole pixels. Bars read as heavier than beats through width,
# beats as heavier than subdivisions through colour: a sub-pixel width cannot be
# drawn crisply, so the hierarchy below one pixel is carried by the colours.
const BAR_LINE_WIDTH: float = 2.0
const BEAT_LINE_WIDTH: float = 1.0
const SUBDIVISION_LINE_WIDTH: float = 1.0

# Grid helper for calculations
var grid_helper: GridHelper = GridHelper.new()
@export var start_position_ticks: int = 0

func set_grid_helper(gh: GridHelper) -> void:
	"""Set the grid helper and connect to its signals."""
	if grid_helper and grid_helper.changed.is_connected(_on_grid_helper_changed):
		grid_helper.changed.disconnect(_on_grid_helper_changed)
	
	grid_helper = gh
	
	if grid_helper:
		grid_helper.changed.connect(_on_grid_helper_changed)

func set_start_position(ticks: int) -> void:
	"""Update start position and redraw."""
	if start_position_ticks != ticks:
		start_position_ticks = ticks
		queue_redraw()

func _on_grid_helper_changed():
	"""Handle GridHelper changes by redrawing."""
	queue_redraw()

func _draw():
	if grid_helper:
		_draw_ruler()

func _draw_ruler() -> void:
	"""Draw ruler with bar numbers and beat markers."""
	# Calculate visible range (no need to adjust for scroll - GridHelper handles it)
	var start_x = 0.0
	var end_x = size.x
	
	# Get grid lines from helper
	var grid_lines = grid_helper.get_visible_grid_lines(start_x, end_x)
	
	# Draw each grid line
	for line in grid_lines:
		# GridHelper already accounts for scroll position, so use line.x directly
		var x = line.x

		# Only draw if within visible bounds
		if x >= 0 and x <= size.x:
			match line.type:
				GridHelper.GridLineType.BAR:
					_draw_grid_line(x, BAR_LINE_WIDTH, bar_line_color)

				GridHelper.GridLineType.BEAT:
					_draw_grid_line(x, BEAT_LINE_WIDTH, beat_line_color)

				GridHelper.GridLineType.SUBDIVISION:
					_draw_grid_line(x, SUBDIVISION_LINE_WIDTH, subdivision_line_color)


## Draw one vertical line snapped to the pixel grid.
##
## Grid positions come out of GridHelper at fractional x, and an antialiased
## draw_line() there spreads the line over two columns of pixels at partial alpha,
## so neighbouring lines of the same kind come out at visibly different strengths
## (and a sub-pixel width nearly disappears). Drawing a whole-pixel rect at a
## rounded x instead makes every line of a kind identical at any zoom or scroll.
## Wider lines stay centred on the grid position, the way draw_line() had them.
func _draw_grid_line(x: float, width: float, color: Color) -> void:
	var left := roundf(x) - floorf(width * 0.5)
	draw_rect(Rect2(left, 0.0, width, size.y), color, true, -1.0, false)
