## Panel view of the built-in Arpeggiator (spec 027 REQ-037, REQ-039): a held-notes strip above
## the generated Simple View. The Simple View gives every parameter (and disables Repeat Ends
## while Ping-Pong is off, through `ParamRules`). The strip lights the held keys and the key
## sounding now, from the device's `"note_state"` stream: subscribed while the view is shown,
## unsubscribed when hidden.
class_name ArpeggiatorDefaultView extends DeviceView

const DATA_TYPE := "note_state"
const OCTAVES_PARAM_ID := 4
const SIMPLE_VIEW_SCENE := preload("res://devices/simple_view/SimpleView.tscn")

var strip: NoteStrip
var simple: DeviceView
var _subscribed_path := ""
var _box: VBoxContainer


func _init() -> void:
	custom_minimum_size = Vector2(200, 100)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box = VBoxContainer.new()
	var box := _box
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 4)
	add_child(box)
	strip = NoteStrip.new()
	box.add_child(strip)
	simple = SIMPLE_VIEW_SCENE.instantiate() as DeviceView
	simple.size_flags_vertical = Control.SIZE_EXPAND_FILL
	simple.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(simple)
	simple.header_tabs_changed.connect(func() -> void: header_tabs_changed.emit())
	# A plain Control doesn't size to its children, so report the box's minimum or the panel clips
	# the Simple View's right edge.
	box.minimum_size_changed.connect(update_minimum_size)


func _get_minimum_size() -> Vector2:
	return _box.get_combined_minimum_size() if _box else Vector2.ZERO


func _on_bind() -> void:
	simple.set_view_type(view_type)
	simple.bind_to_device(device)
	if not device.parameter_changed.is_connected(_on_parameter_changed):
		device.parameter_changed.connect(_on_parameter_changed)
	_update_octaves()


func _on_parameter_changed(param_id: int, _value: float) -> void:
	if param_id == OCTAVES_PARAM_ID:
		_update_octaves()


func _update_octaves() -> void:
	if device and device.get_parameter(OCTAVES_PARAM_ID):
		strip.octaves = roundi(device.get_parameter_real(OCTAVES_PARAM_ID))


func _on_unbind() -> void:
	if device and device.parameter_changed.is_connected(_on_parameter_changed):
		device.parameter_changed.disconnect(_on_parameter_changed)
	if is_instance_valid(simple):
		simple.call("_unbind")


func get_header_tabs() -> PackedStringArray:
	return simple.get_header_tabs()


func get_header_tab() -> int:
	return simple.get_header_tab()


func select_header_tab(index: int) -> void:
	simple.select_header_tab(index)


func _on_view_shown() -> void:
	simple.show_view()
	if device == null:
		return
	_subscribed_path = device.osc_path()
	AudioEngineOSC.subscribe_device_data(_subscribed_path, DATA_TYPE)
	if not AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.connect(_on_data)


func _on_view_hidden() -> void:
	simple.hide_view()
	if AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.disconnect(_on_data)
	if _subscribed_path != "":
		AudioEngineOSC.unsubscribe_device_data(_subscribed_path, DATA_TYPE)
		_subscribed_path = ""
	strip.clear()


func _on_data(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type == DATA_TYPE and osc_path == _subscribed_path:
		strip.set_state(NoteStrip.decode(blob))
