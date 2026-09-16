# AutomationLaneMenu.gd
# Dropdown opened from a track header's automation button (REQ-014): one checkbox per existing
# lane driving `lane.visible`, plus a `+ Add new` entry that opens the parameter picker.
#
# Unchecking a lane only hides its row - the lane, its points and its effect on the engine are
# untouched. That is deliberately different from the header's delete button.
class_name AutomationLaneMenu extends PopupMenu

signal add_lane_requested(track: Track)

const ADD_NEW_ID := 1 << 20  # PopupMenu auto-assigns ids for negative values, so keep this positive.

var track: Track = null
var _lanes: Array[AutomationLane] = []


func _ready() -> void:
	hide_on_checkable_item_selection = false
	if not id_pressed.is_connected(_on_id_pressed):
		id_pressed.connect(_on_id_pressed)


## Rebuild the menu for `p_track` and pop it up at `global_position`.
func open_for(p_track: Track, global_position: Vector2) -> void:
	track = p_track
	_rebuild()
	popup(Rect2(global_position, Vector2.ZERO))


func _rebuild() -> void:
	clear()
	_lanes.clear()
	if track == null:
		return

	for lane in track.automation_lanes:
		if lane == null:
			continue
		var index := _lanes.size()
		_lanes.append(lane)
		var channel: Channel = track.get_linked_channel()
		var label := lane.target.display_name(channel) if lane.target else "Unknown"
		if not lane.resolved:
			label = "%s (missing)" % label
		add_check_item(label, index)
		set_item_checked(get_item_index(index), lane.visible)

	if not _lanes.is_empty():
		add_separator()
	add_item("+ Add new", ADD_NEW_ID)


func _on_id_pressed(id: int) -> void:
	if id == ADD_NEW_ID:
		hide()
		add_lane_requested.emit(track)
		return
	if id < 0 or id >= _lanes.size():
		return
	var lane := _lanes[id]
	lane.set_visible(not lane.visible)
	set_item_checked(get_item_index(id), lane.visible)
