## Layer custom UI: vertical list of slot rows (light, name, separate output, volume knob) in their
## slot colors, and a "Mapping…" button that opens the Layer mapping window.
## Clicking a row shows or hides that layer's slot in the device lane (one open at a time).
## The button, the `%Rows` box and the Mix knob live in `LayerDefaultView.tscn`; only the rows,
## one per child, are made here.
class_name LayerDefaultView extends DeviceView

const MIX_PARAM := "Mix"
## Seconds a device drag has to rest on a row before that layer opens in the lane.
const HOVER_OPEN_SECONDS := 1.0
const SLOT_ROW_SCENE: PackedScene = preload("res://devices/builtin/layer/LayerSlotRow.tscn")

@onready var mapping_button: Button = %MappingButton
@onready var rows_box: VBoxContainer = %Rows
@onready var mix_knob: LabeledKnob = %MixKnob
var _rows: Dictionary = {}  # instance id -> LayerSlotRow
var _mix_id := -1

## Drag hover (#159): the row under the pointer and for how long, the slots that were open when
## the drag began and the layer's device count then. Opening is a view state only; the chain and
## the engine don't change.
var _hover_child: DeviceInstance = null
var _hover_time := 0.0
var _hover_opened := false
var _open_before := PackedStringArray()
var _drag: Variant = null


## Prefer a compact column so Layer can sit beside parameter lists.
func _get_minimum_size() -> Vector2:
	return Vector2(180, 80)


## Hook the Mapping… button and the Mix knob, then build if a device arrived before the tree.
func _ready() -> void:
	set_process(false)
	mapping_button.pressed.connect(_on_mapping_pressed)
	mix_knob.knob.value_changed.connect(_on_mix_changed)
	mix_knob.knob.value_text_callback = _format_mix
	
	# rows
	for row in rows_box.get_children():
		row.queue_free()
		rows_box.remove_child(row)
	
	if device != null:
		_rebuild()


## Listen for child list changes, then rebuild the slot rows.
func _on_bind() -> void:
	if not device.child_added.is_connected(_on_children_changed):
		device.child_added.connect(_on_children_changed)
	if not device.child_removed.is_connected(_on_children_changed):
		device.child_removed.connect(_on_children_changed)
	if not device.child_moved.is_connected(_on_children_changed):
		device.child_moved.connect(_on_children_changed)
	if not device.slots_changed.is_connected(_on_slots_changed):
		device.slots_changed.connect(_on_slots_changed)
	if is_node_ready():
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


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_DRAG_BEGIN:
			_drag = DragDrop.current_drag(self)
			if device != null and DeviceDropTarget.accepts(_drag):
				_open_before = device.open_slot_keys()
				_hover_child = null
				_hover_time = 0.0
				_hover_opened = false
				set_process(true)
		NOTIFICATION_DRAG_END:
			_end_drag_hover()


func _process(delta: float) -> void:
	if device == null or not is_visible_in_tree():
		return
	var child := _child_under_mouse()
	if child != _hover_child:
		_hover_child = child
		_hover_time = 0.0
		return
	if child == null:
		return
	_hover_time += delta
	if _hover_time >= HOVER_OPEN_SECONDS:
		var key := device.slot_key_for(child)
		if not device.is_slot_open(key):
			_hover_opened = true
			device.set_slot_open(key, true)
		_hover_time = -INF  # once per hover


func _child_under_mouse() -> DeviceInstance:
	var mouse := get_global_mouse_position()
	for child_id in _rows:
		var row: LayerSlotRow = _rows[child_id]
		if is_instance_valid(row) and DragDrop.is_point_visible(row, mouse):
			return row.instance
	return null


## The drag ended: a layer opened by hover closes again (the earlier open slots come back) unless
## the drop landed in it.
func _end_drag_hover() -> void:
	set_process(false)
	var dropped := _drag is DeviceDrag and (_drag as DeviceDrag).did_commit
	_drag = null
	_hover_child = null
	if device == null or not _hover_opened:
		return
	_hover_opened = false
	if dropped:
		return
	for key in device.open_slot_keys():
		if not _open_before.has(key):
			device.set_slot_open(key, false)
	for key in _open_before:
		device.set_slot_open(key, true)


## Highlight the rows whose slot is open, in their (possibly new) colors.
func _on_slots_changed() -> void:
	for row in _rows.values():
		row.refresh_slot()


## Rebuild the slot list when Layer children are added, removed, or reordered.
func _on_children_changed(_a = null, _b = null) -> void:
	_rebuild()


func _on_mapping_pressed() -> void:
	if device:
		LayerMappingWindow.open_for(device)


## Refill `%Rows` with one LayerSlotRow per child, and sync the Mix knob.
func _rebuild() -> void:
	if rows_box == null:
		return
	for row in rows_box.get_children():
		rows_box.remove_child(row)
		row.queue_free()
	_rows.clear()
	if device == null:
		return
	for child in device.children:
		var row: LayerSlotRow = SLOT_ROW_SCENE.instantiate()
		rows_box.add_child(row)
		row.setup(device, child)
		row.activated.connect(_on_row_activated.bind(child))
		row.context_requested.connect(child_context_menu_requested.emit.bind(child))
		_rows[child.id] = row
	_sync_mix_knob()


## Dry/wet Mix knob below the slot rows (0 = dry input only, 1 = fully layered); hidden when the
## device has no Mix parameter.
func _sync_mix_knob() -> void:
	_mix_id = device.get_parameter_id_by_name(MIX_PARAM)
	var param := device.get_parameter(_mix_id)
	mix_knob.visible = param != null
	if param == null:
		return
	mix_knob.knob.value_default = param.value_to_normalized(param.default_value)
	mix_knob.knob.set_value_no_signal(device.get_parameter_normalized(_mix_id))


func _on_device_parameter_changed(param_id: int, value: float) -> void:
	if param_id == _mix_id and mix_knob:
		mix_knob.knob.set_value_no_signal(value)


func _on_mix_changed(normalized: float) -> void:
	if device and _mix_id >= 0:
		ParameterActions.set_normalized(device, _mix_id, clampf(normalized, 0.0, 1.0))


func _format_mix(normalized: float) -> String:
	var param := device.get_parameter(_mix_id) if device else null
	return param.format_value(param.normalized_to_value(normalized)) if param else ""


## Show or hide the activated layer's slot.
func _on_row_activated(child: DeviceInstance) -> void:
	device.toggle_slot(device.slot_key_for(child))
