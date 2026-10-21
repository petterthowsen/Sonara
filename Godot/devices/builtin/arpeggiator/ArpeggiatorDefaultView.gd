## Panel view of the built-in Arpeggiator (spec 027 REQ-037, REQ-039): a held-notes strip above
## the generated Simple View. The Simple View gives every parameter (and disables Repeat Ends
## while Ping-Pong is off, through `ParamRules`). The strip lights the held keys and the key
## sounding now, from the device's `"note_state"` stream: subscribed while the view is shown,
## unsubscribed when hidden. The strip and the Simple View live in `ArpeggiatorDefaultView.tscn`.
class_name ArpeggiatorDefaultView extends DeviceView

const DATA_TYPE := "note_state"
const OCTAVES_PARAM_ID := 4

@onready var strip: NoteStrip = %Strip
@onready var simple: DeviceView = %Simple
@onready var _box: VBoxContainer = %Box
var _subscribed_path := ""


## Relay the Simple View's header tabs and the box's minimum size, then bind if a device arrived
## before the tree.
func _ready() -> void:
	simple.header_tabs_changed.connect(func() -> void: header_tabs_changed.emit())
	# A plain Control doesn't size to its children, so report the box's minimum or the panel clips
	# the Simple View's right edge.
	_box.minimum_size_changed.connect(update_minimum_size)
	update_minimum_size()
	if device != null:
		_setup()


func _get_minimum_size() -> Vector2:
	return _box.get_combined_minimum_size() if _box else Vector2.ZERO


func _on_bind() -> void:
	if is_node_ready():
		_setup()


## Everything that needs both the scene and the device.
func _setup() -> void:
	simple.set_view_type(view_type)
	simple.bind_to_device(device)
	_update_octaves()


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	if param_id == OCTAVES_PARAM_ID:
		_update_octaves()


func _update_octaves() -> void:
	if strip and device and device.get_parameter(OCTAVES_PARAM_ID):
		strip.octaves = roundi(device.get_parameter_real(OCTAVES_PARAM_ID))


func _on_unbind() -> void:
	if is_instance_valid(simple):
		simple.call("_unbind")


func get_header_tabs() -> PackedStringArray:
	return simple.get_header_tabs() if simple else PackedStringArray()


func get_header_tab() -> int:
	return simple.get_header_tab() if simple else 0


func select_header_tab(index: int) -> void:
	if simple:
		simple.select_header_tab(index)


func _on_view_shown() -> void:
	if simple:
		simple.show_view()
	if device == null:
		return
	_subscribed_path = device.osc_path()
	AudioEngineOSC.subscribe_device_data(_subscribed_path, DATA_TYPE)
	if not AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.connect(_on_data)


func _on_view_hidden() -> void:
	if simple:
		simple.hide_view()
	if AudioEngineOSC.device_data_received.is_connected(_on_data):
		AudioEngineOSC.device_data_received.disconnect(_on_data)
	if _subscribed_path != "":
		AudioEngineOSC.unsubscribe_device_data(_subscribed_path, DATA_TYPE)
		_subscribed_path = ""
	if strip:
		strip.clear()


func _on_data(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type == DATA_TYPE and osc_path == _subscribed_path and strip:
		strip.set_state(NoteStrip.decode(blob))
