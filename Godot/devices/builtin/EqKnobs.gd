## Knob setup shared by the EQ's panel view (selected band) and window view (all bands).
class_name EqKnobs extends RefCounted

const KNOB_SIZE := Vector2(34, 34)
const KNOB_LABEL_WIDTH := 40.0


static func make_knob(text: String, on_changed: Callable) -> LabeledKnob:
	var knob := LabeledKnob.new()
	knob.text = text
	knob.knob_size = KNOB_SIZE
	knob.label_width = KNOB_LABEL_WIDTH
	knob.knob.value_changed.connect(on_changed)
	return knob


## Point `knob` at `param_id`'s range and curve (real units; the device converts).
static func configure(knob: RotaryKnob, device: Object, param_id: int, format: String, unit_suffix: String) -> void:
	var param = device.get_parameter(param_id)
	if param == null:
		return
	knob.min_value = param.min_value
	knob.max_value = param.max_value
	knob.logarithmic = param.is_logarithmic
	knob.value_default = param.default_value
	knob.value_format = format
	var is_freq := param_id < EqResponse.OUTPUT_GAIN and param_id % EqResponse.BAND_STRIDE == EqResponse.P_FREQ
	knob.value_text_callback = func(value: float) -> String:
		if is_freq:
			return FreqAxis.format_hz(value) + " Hz"
		return (format % value) + unit_suffix


## Gain means nothing for cuts, notches and band passes: dim it rather than shifting the layout.
static func dim_gain(gain_knob: LabeledKnob, type: int) -> void:
	var uses_gain := EqResponse.type_uses_gain(type)
	gain_knob.modulate.a = 1.0 if uses_gain else 0.25
	gain_knob.mouse_filter = Control.MOUSE_FILTER_PASS if uses_gain else Control.MOUSE_FILTER_IGNORE
	gain_knob.knob.mouse_filter = Control.MOUSE_FILTER_STOP if uses_gain else Control.MOUSE_FILTER_IGNORE
