# DropZone.gd
# A reusable drop zone control that accepts drag data and provides visual feedback
@tool
class_name DropZone extends Control

enum Orientation { HORIZONTAL, VERTICAL }
enum LinePosition { START, CENTER, END }

# Signals
signal drop_accepted(data: Variant)
signal drag_entered(data: Variant)
signal drag_exited()

# Layout properties
@export var orientation: DropZone.Orientation = Orientation.HORIZONTAL:
	set(value):
		orientation = value
		_update_size()

@export var dropzone_size: float = 16.0:
	set(value):
		dropzone_size = value
		_update_size()

# Visual properties
@export var line_position: DropZone.LinePosition = LinePosition.CENTER:
	set(value):
		line_position = value
		queue_redraw()

@export_group("Idle State")
@export var idle_color: Color = Color(0.15, 0.15, 0.15, 0.2):
	set(value):
		idle_color = value
		queue_redraw()

@export var idle_thickness: float = 1.0:
	set(value):
		idle_thickness = value
		queue_redraw()

@export_group("Available State")
@export var available_color: Color = Color(0.3, 0.5, 0.8, 0.4):
	set(value):
		available_color = value
		queue_redraw()

@export var available_thickness: float = 2.0:
	set(value):
		available_thickness = value
		queue_redraw()

@export_group("Hover State")
@export var hover_color: Color = Color(0.5, 0.7, 1.0, 0.6):
	set(value):
		hover_color = value
		queue_redraw()

@export var hover_thickness: float = 3.0:
	set(value):
		hover_thickness = value
		queue_redraw()

@export_group("")

## If true, occupy layout space even when idle. If false, hide until a drag begins.
@export var always_show: bool = false

# State
var is_dragging: bool = false  # True during any drag operation
var is_hovered: bool = false   # True when hovering over this zone during drag
var accepts_data: Callable = func(_data): return true  # Override to filter data


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	_update_size()
	visible = always_show


func _update_size() -> void:
	"""Update custom_minimum_size based on orientation and dropzone_size."""
	if orientation == Orientation.HORIZONTAL:
		custom_minimum_size = Vector2(0, dropzone_size)
	else:
		custom_minimum_size = Vector2(dropzone_size, 0)
	queue_redraw()


func _draw() -> void:
	# Determine color and thickness based on state
	var line_color: Color
	var line_thickness: float
	
	if is_hovered:
		line_color = hover_color
		line_thickness = hover_thickness
	elif is_dragging:
		line_color = available_color
		line_thickness = available_thickness
	else:
		line_color = idle_color
		line_thickness = idle_thickness

	if line_thickness <= 0.0 or line_color.a <= 0.0:
		return
	
	# Calculate line position based on orientation and line_position
	var line_rect: Rect2
	
	if orientation == Orientation.HORIZONTAL:
		# Horizontal line
		var y_pos: float
		match line_position:
			LinePosition.START:
				y_pos = 0
			LinePosition.CENTER:
				y_pos = (size.y - line_thickness) / 2.0
			LinePosition.END:
				y_pos = size.y - line_thickness
		
		line_rect = Rect2(0, y_pos, size.x, line_thickness)
	else:
		# Vertical line
		var x_pos: float
		match line_position:
			LinePosition.START:
				x_pos = 0
			LinePosition.CENTER:
				x_pos = (size.x - line_thickness) / 2.0
			LinePosition.END:
				x_pos = size.x - line_thickness
		
		line_rect = Rect2(x_pos, 0, line_thickness, size.y)
	
	draw_rect(line_rect, line_color, true)


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	"""Check if this drop zone can accept the data."""
	var can_accept = accepts_data.call(data)
	
	if can_accept and not is_hovered:
		is_hovered = true
		queue_redraw()
		drag_entered.emit(data)
	
	return can_accept


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	"""Accept the drop and emit signal."""
	is_hovered = false
	queue_redraw()
	drop_accepted.emit(data)


func _notification(what: int) -> void:
	"""Handle drag notifications to show/hide and update state."""
	if what == NOTIFICATION_DRAG_BEGIN:
		is_dragging = true
		queue_redraw()
		if not always_show:
			show()
	
	elif what == NOTIFICATION_DRAG_END:
		is_dragging = false
		if is_hovered:
			is_hovered = false
			drag_exited.emit()
		queue_redraw()
		
		if not always_show:
			hide()


## Invisible layout spacer. `vertical` true is a column gap in an HBox; false is a row gap in a VBox.
static func create_insert_spacer(vertical: bool, gap: float) -> DropZone:
	var zone := DropZone.new()
	zone.orientation = Orientation.VERTICAL if vertical else Orientation.HORIZONTAL
	zone.dropzone_size = gap
	zone.always_show = true
	zone.line_position = LinePosition.CENTER
	zone.idle_thickness = 0.0
	zone.idle_color = Color(0, 0, 0, 0)
	zone.available_thickness = gap
	zone.hover_thickness = gap
	zone.available_color = Color(0.7, 0.7, 0.7, 0.5)
	zone.hover_color = Color(0.7, 0.7, 0.7, 0.7)
	if vertical:
		zone.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		zone.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		zone.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	return zone


## Rebuild `parent` as [zone][panel][zone]...[panel][zone]. `make_zone` receives the insert index.
static func rebuild_insert_layout(
	parent: Node,
	panels: Array,
	make_zone: Callable,
	empty_zone: bool = true
) -> Array[DropZone]:
	var existing_zones: Array[Node] = []
	for child in parent.get_children():
		if child is DropZone:
			existing_zones.append(child)
	for zone_node in existing_zones:
		parent.remove_child(zone_node)
		zone_node.queue_free()
	for panel in panels:
		if panel.get_parent() == parent:
			parent.remove_child(panel)
	var zones: Array[DropZone] = []
	if panels.is_empty() and not empty_zone:
		return zones
	for i in range(panels.size()):
		var zone := make_zone.call(i) as DropZone
		parent.add_child(zone)
		zones.append(zone)
		parent.add_child(panels[i])
	var end_zone := make_zone.call(panels.size()) as DropZone
	parent.add_child(end_zone)
	zones.append(end_zone)
	return zones
