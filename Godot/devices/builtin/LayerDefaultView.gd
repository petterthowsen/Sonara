## Layer custom UI: vertical list of slot rows (light, name, volume knob).
## Clicking a row asks DevicePanel to slide out that child only.
class_name LayerDefaultView extends DeviceView

var _rows: Dictionary = {}  # instance id -> LayerSlotRow
var _selected: DeviceInstance = null


## Prefer a compact column so Layer can sit beside parameter lists.
func _get_minimum_size() -> Vector2:
	return Vector2(180, 80)


## Listen for child list changes, then rebuild the slot rows.
func _on_bind() -> void:
	if not is_node_ready():
		await ready
	if device:
		if not device.child_added.is_connected(_on_children_changed):
			device.child_added.connect(_on_children_changed)
		if not device.child_removed.is_connected(_on_children_changed):
			device.child_removed.connect(_on_children_changed)
		if not device.child_moved.is_connected(_on_children_changed):
			device.child_moved.connect(_on_children_changed)
	_rebuild()


## Highlight the row whose child is currently shown in the folder.
func set_focused_child(child: DeviceInstance) -> void:
	_selected = child
	for row in _rows.values():
		if row is LayerSlotRow:
			row.set_selected(row.instance == child)


## Rebuild the slot list when Layer children are added, removed, or reordered.
func _on_children_changed(_a = null, _b = null) -> void:
	_rebuild()


## Recreate one LayerSlotRow per child on this VBox.
func _rebuild() -> void:
	for child in get_children():
		child.queue_free()
	_rows.clear()
	if device == null:
		return
	for child in device.children:
		var row := LayerSlotRow.new()
		add_child(row)
		row.setup(child)
		row.activated.connect(_on_row_activated.bind(child))
		row.set_selected(child == _selected)
		_rows[child.id] = row


## Open the activated child in the device folder.
func _on_row_activated(child: DeviceInstance) -> void:
	_selected = child
	set_focused_child(child)
	container_child_requested.emit(child)
