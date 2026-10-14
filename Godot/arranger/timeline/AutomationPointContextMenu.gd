# AutomationPointContextMenu.gd
# Right-click menu on an automation point or the current point selection (REQ-019), modelled on
# ClipContextMenu: the menu reports what was asked for and the caller applies it, so the history
# entry is created in one place.
class_name AutomationPointContextMenu extends PopupMenu

signal curve_requested(points: Array, curve: int)
signal neighbor_value_requested(points: Array, next: bool)
signal delete_requested(points: Array)

const ID_LINEAR := 0
const ID_STEP := 1
const ID_SET_PREV := 2
const ID_SET_NEXT := 3
const ID_DELETE := 4

## The points the menu acts on, captured at popup time.
var points: Array = []


func _ready() -> void:
	theme_type_variation = &"ContextMenuList"
	if not id_pressed.is_connected(_on_id_pressed):
		id_pressed.connect(_on_id_pressed)


## Bind to `p_points` and pop up at `global_position`. Curve entries show as radio-checked when
## every bound point already has that shape; the neighbour-value entries are disabled when no
## bound point has a previous/next point to take a value from.
func open_for(p_points: Array, global_position: Vector2, can_set_prev: bool = true, can_set_next: bool = true) -> void:
	points = p_points.duplicate()
	if points.is_empty():
		return

	clear()
	var all_linear := true
	var all_step := true
	for point in points:
		if point.curve == AutomationPoint.CurveType.STEP:
			all_linear = false
		else:
			all_step = false

	add_radio_check_item("Linear", ID_LINEAR)
	set_item_checked(get_item_index(ID_LINEAR), all_linear)
	add_radio_check_item("Step", ID_STEP)
	set_item_checked(get_item_index(ID_STEP), all_step)
	add_separator()
	add_item("Set to Previous Point Value", ID_SET_PREV)
	set_item_disabled(get_item_index(ID_SET_PREV), not can_set_prev)
	add_item("Set to Next Point Value", ID_SET_NEXT)
	set_item_disabled(get_item_index(ID_SET_NEXT), not can_set_next)
	add_separator()
	add_item("Delete" if points.size() == 1 else "Delete %d Points" % points.size(), ID_DELETE)

	ContextMenuPopup.popup_at_point(self, global_position)


func _on_id_pressed(id: int) -> void:
	if points.is_empty():
		return
	var bound := points.duplicate()
	ContextMenuPopup.close(self)
	match id:
		ID_LINEAR:
			curve_requested.emit(bound, AutomationPoint.CurveType.LINEAR)
		ID_STEP:
			curve_requested.emit(bound, AutomationPoint.CurveType.STEP)
		ID_SET_PREV:
			neighbor_value_requested.emit(bound, false)
		ID_SET_NEXT:
			neighbor_value_requested.emit(bound, true)
		ID_DELETE:
			delete_requested.emit(bound)
