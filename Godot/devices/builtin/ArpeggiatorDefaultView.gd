## Panel view of the built-in Arpeggiator (spec 027 REQ-037, REQ-039): a held-notes strip above
## the generated Simple View. The Simple View gives every parameter (and disables Repeat Ends
## while Ping-Pong is off, through `ParamRules`). The strip lights the held keys and the key
## sounding now, from the device's `"note_state"` stream: subscribed while the view is shown,
## unsubscribed when hidden.
class_name ArpeggiatorDefaultView extends DeviceView

const DATA_TYPE := "note_state"
const SIMPLE_VIEW_SCENE := preload("res://devices/simple_view/SimpleView.tscn")

var strip: NoteStrip
var simple: DeviceView
var _subscribed_path := ""


func _init() -> void:
	custom_minimum_size = Vector2(200, 100)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
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


func _on_bind() -> void:
	simple.set_view_type(view_type)
	simple.bind_to_device(device)


func _on_unbind() -> void:
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
