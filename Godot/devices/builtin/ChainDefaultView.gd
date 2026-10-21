## Chain panel: the slot button that shows or hides the chained devices beside the Chain in the
## device lane, the dry/wet Mix knob (0 = dry, 1 = wet) and the post-chain Volume knob.
class_name ChainDefaultView extends DeviceView

const VOLUME_PARAM := "Volume"
const MIX_PARAM := "Mix"

var slot_button: DeviceSlotButton = null
var volume_knob: LabeledKnob = null
var mix_knob: LabeledKnob = null
var _volume_id := -1
var _mix_id := -1


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

	var knobs := HBoxContainer.new()
	knobs.alignment = BoxContainer.ALIGNMENT_CENTER
	knobs.add_theme_constant_override("separation", 12)
	box.add_child(knobs)

	mix_knob = LabeledKnob.new()
	mix_knob.text = "MIX"
	mix_knob.knob_size = Vector2(44, 44)
	mix_knob.knob.value_changed.connect(_on_mix_changed)
	mix_knob.knob.value_text_callback = _format_mix
	knobs.add_child(mix_knob)

	volume_knob = LabeledKnob.new()
	volume_knob.text = "VOL"
	volume_knob.knob_size = Vector2(44, 44)
	volume_knob.knob.value_changed.connect(_on_knob_changed)
	volume_knob.knob.value_text_callback = _format_volume
	knobs.add_child(volume_knob)


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
	_mix_id = device.get_parameter_id_by_name(MIX_PARAM)
	var mix_param := device.get_parameter(_mix_id)
	mix_knob.visible = mix_param != null
	if mix_param:
		mix_knob.knob.value_default = mix_param.value_to_normalized(mix_param.default_value)
		mix_knob.knob.set_value_no_signal(device.get_parameter_normalized(_mix_id))


func _on_unbind() -> void:
	slot_button.bind_to_slot(null, "")


func _on_device_parameter_changed(param_id: int, value: float) -> void:
	if param_id == _volume_id and volume_knob:
		volume_knob.knob.set_value_no_signal(value)
	elif param_id == _mix_id and mix_knob:
		mix_knob.knob.set_value_no_signal(value)


func _on_knob_changed(normalized: float) -> void:
	if device and _volume_id >= 0:
		ParameterActions.set_normalized(device, _volume_id, normalized)


func _format_volume(normalized: float) -> String:
	var param := device.get_parameter(_volume_id) if device else null
	return param.format_value(param.normalized_to_value(normalized)) if param else ""


func _on_mix_changed(normalized: float) -> void:
	if device and _mix_id >= 0:
		ParameterActions.set_normalized(device, _mix_id, clampf(normalized, 0.0, 1.0))


func _format_mix(normalized: float) -> String:
	var param := device.get_parameter(_mix_id) if device else null
	return param.format_value(param.normalized_to_value(normalized)) if param else ""
