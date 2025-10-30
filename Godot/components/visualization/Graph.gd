# Visualization/Graph.gd
# A flexible graph component for visualizing time-series data.
# Stores data values separately from screen positions, supporting rolling windows and auto-scaling.

@tool
class_name Graph extends Control

# ============================================================================
# DATA MANAGEMENT
# ============================================================================

## Maximum number of data points to keep (0 = unlimited)
@export var max_data_points: int = 500:
	set(val):
		max_data_points = val
		_prune_data()

## Data values (stored as floats, x-position is implicit based on index)
var _data: Array[float] = []

## Whether to auto-scale y-axis based on min/max values in data
@export var auto_scale: bool = true

## Manual value range (used when auto_scale is false)
@export var value_min: float = 0.0
@export var value_max: float = 1.0

## Tracked min/max for auto-scaling (updated as data is added)
var _auto_min: float = INF
var _auto_max: float = -INF

# ============================================================================
# STYLING
# ============================================================================

@export var background_color: Color = Color(0.1, 0.1, 0.1)
@export var line_color: Color = Color.WHITE
@export var line_width: float = 1.0

## Margin/padding around the graph area
@export var margin_left: float = 4.0
@export var margin_right: float = 4.0
@export var margin_top: float = 4.0
@export var margin_bottom: float = 4.0

## Whether to draw a grid
@export var show_grid: bool = false
@export var grid_color: Color = Color(0.3, 0.3, 0.3, 0.5)
@export var grid_lines_horizontal: int = 4
@export var grid_lines_vertical: int = 8

# ============================================================================
# COMPUTED PROPERTIES
# ============================================================================

## Get the current effective y-axis range
var value_range_min: float:
	get:
		if auto_scale and _data.size() > 0:
			# Add some padding (10% on each side)
			var padding = (_auto_max - _auto_min) * 0.1
			return _auto_min - padding if _auto_min != INF else 0.0
		return value_min

var value_range_max: float:
	get:
		if auto_scale and _data.size() > 0:
			var padding = (_auto_max - _auto_min) * 0.1
			return _auto_max + padding if _auto_max != -INF else 1.0
		return value_max

var graph_rect: Rect2:
	get:
		return Rect2(
			Vector2(margin_left, margin_top),
			Vector2(size.x - margin_left - margin_right, size.y - margin_top - margin_bottom)
		)

# ============================================================================
# LIFECYCLE
# ============================================================================

func _get_minimum_size() -> Vector2:
	return Vector2(64, 32)

func _ready() -> void:
	_data = []

# ============================================================================
# PUBLIC API
# ============================================================================

## Add a single data point (value). Data is stored and automatically pruned if max_data_points is set.
func add_point(value: float) -> void:
	_data.append(value)
	
	# Update auto-scaling min/max
	if auto_scale:
		if value < _auto_min or _auto_min == INF:
			_auto_min = value
		if value > _auto_max or _auto_max == -INF:
			_auto_max = value
	
	_prune_data()
	queue_redraw()

## Add multiple data points at once
func add_points(values: Array[float]) -> void:
	for value in values:
		_data.append(value)
		if auto_scale:
			if value < _auto_min or _auto_min == INF:
				_auto_min = value
			if value > _auto_max or _auto_max == -INF:
				_auto_max = value
	
	_prune_data()
	queue_redraw()

## Clear all data
func clear() -> void:
	_data.clear()
	_auto_min = INF
	_auto_max = -INF
	queue_redraw()

## Get current data size
func get_data_size() -> int:
	return _data.size()

## Get a copy of the current data
func get_data() -> Array[float]:
	return _data.duplicate()

# ============================================================================
# INTERNAL
# ============================================================================

func _prune_data() -> void:
	if max_data_points > 0 and _data.size() > max_data_points:
		var remove_count = _data.size() - max_data_points
		_data = _data.slice(remove_count)
		
		# Recalculate min/max if auto-scaling
		if auto_scale and _data.size() > 0:
			_auto_min = INF
			_auto_max = -INF
			for value in _data:
				if value < _auto_min:
					_auto_min = value
				if value > _auto_max:
					_auto_max = value

## Convert a data value to screen y-coordinate
func _value_to_y(value: float) -> float:
	var range_min = value_range_min
	var range_max = value_range_max
	var range_size = range_max - range_min
	
	if range_size <= 0.0:
		return graph_rect.position.y + graph_rect.size.y * 0.5
	
	var normalized = (value - range_min) / range_size
	# Invert: 0 at bottom, 1 at top (for typical graph display)
	normalized = 1.0 - normalized
	
	return graph_rect.position.y + normalized * graph_rect.size.y

## Convert data index to screen x-coordinate
func _index_to_x(index: int) -> float:
	if _data.size() <= 1:
		return graph_rect.position.x
	
	var normalized = float(index) / float(_data.size() - 1)
	return graph_rect.position.x + normalized * graph_rect.size.x

# ============================================================================
# DRAWING
# ============================================================================

func _draw() -> void:
	# Draw background
	draw_rect(Rect2(Vector2(0, 0), size), background_color, true, -1.0, true)
	
	if _data.size() == 0:
		return
	
	# Draw grid if enabled
	if show_grid:
		_draw_grid()
	
	# Draw data line
	if _data.size() == 1:
		# Single point: draw a small circle
		var x = _index_to_x(0)
		var y = _value_to_y(_data[0])
		draw_circle(Vector2(x, y), line_width * 2.0, line_color)
	else:
		# Multiple points: draw connected line
		for i in range(_data.size() - 1):
			var p1 = Vector2(_index_to_x(i), _value_to_y(_data[i]))
			var p2 = Vector2(_index_to_x(i + 1), _value_to_y(_data[i + 1]))
			draw_line(p1, p2, line_color, line_width, true)

func _draw_grid() -> void:
	var rect = graph_rect
	
	# Horizontal grid lines
	for i in range(grid_lines_horizontal + 1):
		var normalized = float(i) / float(grid_lines_horizontal)
		var y = rect.position.y + normalized * rect.size.y
		draw_line(
			Vector2(rect.position.x, y),
			Vector2(rect.position.x + rect.size.x, y),
			grid_color,
			1.0
		)
	
	# Vertical grid lines
	for i in range(grid_lines_vertical + 1):
		var normalized = float(i) / float(grid_lines_vertical)
		var x = rect.position.x + normalized * rect.size.x
		draw_line(
			Vector2(x, rect.position.y),
			Vector2(x, rect.position.y + rect.size.y),
			grid_color,
			1.0
		)
