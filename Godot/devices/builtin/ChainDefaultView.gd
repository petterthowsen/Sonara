## Chain panel: the slot button that shows or hides the chained devices beside the Chain in the
## device lane, and the Volume knob (MIX).
class_name ChainDefaultView extends DeviceView

const VOLUME_PARAM := "Volume"

var slot_button: DeviceSlotButton = null
var volume_knob: LabeledKnob = null
var _volume_id := -1


func _ready() -> void:
	_build()


func _build() -> void:
	if slot_button:
		return
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 24)
	add_child(box)

	slot_button = DeviceSlotButton.new()
	slot_button.custom_minimum_size = Vector2(140, 80)
	slot_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(slot_button)

	volume_knob = LabeledKnob.new()
	volume_knob.text = "MIX"
	volume_knob.knob_size = Vector2(44, 44)
	volume_knob.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	volume_knob.knob.value_changed.connect(_on_knob_changed)
	volume_knob.knob.value_text_callback = _format_volume
	box.add_child(volume_knob)


func _get_minimum_size() -> Vector2:
	return Vector2(168, 200)


func _on_bind() -> void:
	_build()
	slot_button.bind_to_slot(device, DeviceInstance.CHAIN_SLOT)
	_volume_id = device.get_parameter_id_by_name(VOLUME_PARAM)
	var param := device.get_parameter(_volume_id)
	volume_knob.visible = param != null
	if param:
		volume_knob.knob.value_default = param.value_to_normalized(param.default_value)
		volume_knob.knob.set_value_no_signal(device.get_parameter_normalized(_volume_id))


func _on_unbind() -> void:
	slot_button.bind_to_slot(null, "")


func _on_device_parameter_changed(param_id: int, value: float) -> void:
	if param_id == _volume_id and volume_knob:
		volume_knob.knob.set_value_no_signal(value)


func _on_knob_changed(normalized: float) -> void:
	if device and _volume_id >= 0:
		device.set_parameter_normalized(_volume_id, normalized)


func _format_volume(normalized: float) -> String:
	var param := device.get_parameter(_volume_id) if device else null
	return param.format_value(param.normalized_to_value(normalized)) if param else ""
