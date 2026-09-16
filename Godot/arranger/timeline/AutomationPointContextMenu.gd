# AutomationPointContextMenu.gd
# Right-click menu on an automation point or the current point selection (REQ-019), modelled on
# ClipContextMenu: the menu reports what was asked for and the caller applies it, so the history
# entry is created in one place.
class_name AutomationPointContextMenu extends PopupMenu

signal curve_requested(points: Array, curve: int)
signal delete_requested(points: Array)

const ID_LINEAR := 0
const ID_STEP := 1
const ID_DELETE := 2

## The points the menu acts on, captured at popup time.
var points: Array = []


func _ready() -> void:
	if not id_pressed.is_connected(_on_id_pressed):
		id_pressed.connect(_on_id_pressed)


## Bind to `p_points` and pop up at `global_position`. Curve entries show as radio-checked when
## every bound point already has that shape.
func open_for(p_points: Array, global_position: Vector2) -> void:
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
	add_item("Delete" if points.size() == 1 else "Delete %d Points" % points.size(), ID_DELETE)

	popup(Rect2(global_position, Vector2.ZERO))


func _on_id_pressed(id: int) -> void:
	if points.is_empty():
		return
	var bound := points.duplicate()
	hide()
	match id:
		ID_LINEAR:
			curve_requested.emit(bound, AutomationPoint.CurveType.LINEAR)
		ID_STEP:
			curve_requested.emit(bound, AutomationPoint.CurveType.STEP)
		ID_DELETE:
			delete_requested.emit(bound)
