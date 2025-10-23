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

# Grid helper for calculations
@export var grid_helper: GridHelper
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
					# Draw bar line (full height, thicker)
					draw_line(Vector2(x, 0), Vector2(x, size.y), bar_line_color, 1.5, true)
				
				GridHelper.GridLineType.BEAT:
					# Draw beat line (full height)
					draw_line(Vector2(x, 0), Vector2(x, size.y), beat_line_color, 1.0, true)
				
				GridHelper.GridLineType.SUBDIVISION:
					# Draw subdivision line (full height, thinner)
					draw_line(Vector2(x, 0), Vector2(x, size.y), subdivision_line_color, 0.5, true)
