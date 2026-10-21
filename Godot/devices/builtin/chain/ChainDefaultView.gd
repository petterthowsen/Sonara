## Chain panel: the slot button that shows or hides the chained devices beside the Chain in the
## device lane, the dry/wet Mix knob (0 = dry, 1 = wet) and the post-chain Volume knob.
class_name ChainDefaultView extends DeviceView

const VOLUME_PARAM := "Volume"
const MIX_PARAM := "Mix"

@onready var slot_button: DeviceSlotButton = %SlotButton
@onready var volume_knob: LabeledKnob = %VolumeKnob
@onready var mix_knob: LabeledKnob = %MixKnob
var _volume_id := -1
var _mix_id := -1


## Hook the scene's knobs to their handlers, then bind if a device arrived before the tree.
func _ready() -> void:
	mix_knob.knob.value_changed.connect(_on_mix_changed)
	mix_knob.knob.value_text_callback = _format_mix
	volume_knob.knob.value_changed.connect(_on_knob_changed)
	volume_knob.knob.value_text_callback = _format_volume
	if device != null:
		_setup()


func _get_minimum_size() -> Vector2:
	return Vector2(168, 200)


func _on_bind() -> void:
	if is_node_ready():
		_setup()


## Everything that needs both the scene and the device.
func _setup() -> void:
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
	if slot_button:
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
