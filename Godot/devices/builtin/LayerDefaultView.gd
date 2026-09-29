## Layer custom UI: vertical list of slot rows (light, name, separate output, volume knob) in their
## slot colors, and a "Mapping…" button that opens the Layer mapping window.
## Clicking a row shows or hides that layer's slot in the device lane (one open at a time).
class_name LayerDefaultView extends DeviceView

var _rows: Dictionary = {}  # instance id -> LayerSlotRow


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
		if not device.slots_changed.is_connected(_on_slots_changed):
			device.slots_changed.connect(_on_slots_changed)
	_rebuild()


## Disconnect the child-list signals connected in _on_bind().
func _on_unbind() -> void:
	if device.child_added.is_connected(_on_children_changed):
		device.child_added.disconnect(_on_children_changed)
	if device.child_removed.is_connected(_on_children_changed):
		device.child_removed.disconnect(_on_children_changed)
	if device.child_moved.is_connected(_on_children_changed):
		device.child_moved.disconnect(_on_children_changed)
	if device.slots_changed.is_connected(_on_slots_changed):
		device.slots_changed.disconnect(_on_slots_changed)


## Highlight the rows whose slot is open, in their (possibly new) colors.
func _on_slots_changed() -> void:
	for row in _rows.values():
		row.refresh_slot()


## Rebuild the slot list when Layer children are added, removed, or reordered.
func _on_children_changed(_a = null, _b = null) -> void:
	_rebuild()


## Recreate one LayerSlotRow per child on this VBox, followed by the Mapping… button.
func _rebuild() -> void:
	for child in get_children():
		child.queue_free()
	_rows.clear()
	if device == null:
		return
	var mapping := Button.new()
	mapping.text = "Mapping…"
	mapping.tooltip_text = "Choose which notes each layer plays, and remap them"
	mapping.focus_mode = Control.FOCUS_NONE
	mapping.pressed.connect(func() -> void: LayerMappingWindow.open_for(device))
	add_child(mapping)
	for child in device.children:
		var row := LayerSlotRow.new()
		add_child(row)
		row.setup(device, child)
		row.activated.connect(_on_row_activated.bind(child))
		row.context_requested.connect(child_context_menu_requested.emit.bind(child))
		_rows[child.id] = row


## Show or hide the activated layer's slot.
func _on_row_activated(child: DeviceInstance) -> void:
	device.toggle_slot(device.slot_key_for(child))
