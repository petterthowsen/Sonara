## Knob setup shared by the EQ's panel view (selected band) and companion view (all bands). The
## knobs and sliders themselves live in `EqDefaultView.tscn` and `EqBandStrip.tscn`.
class_name EqKnobs extends RefCounted

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
	ModAssign.retarget(knob, device, param_id)
	# A value caption (LabeledKnob) re-reads the text with the new format.
	knob.value_set.emit()


## Point the footer's `slider` at `param_id`'s range and curve (real units; the device
## converts), the same binding `configure` gives a knob. Re-aiming a slider at another band re-points its modulation
## display too (`ModAssign.retarget`).
static func configure_compact(slider: CompactSlider, device: Object, param_id: int, format: String, unit_suffix: String) -> void:
	var param = device.get_parameter(param_id)
	if param == null:
		return
	slider.min_value = param.min_value
	slider.max_value = param.max_value
	slider.logarithmic = param.is_logarithmic
	slider.default_value = param.default_value
	slider.value_format = format
	var is_freq := param_id < EqResponse.OUTPUT_GAIN and param_id % EqResponse.BAND_STRIDE == EqResponse.P_FREQ
	slider.value_text_callback = func(value: float) -> String:
		if is_freq:
			return FreqAxis.format_hz(value) + " Hz"
		return (format % value) + unit_suffix
	ModAssign.retarget(slider, device, param_id)


## Gain means nothing for cuts, notches and band passes: dim it rather than shifting the layout.
## Works for a `LabeledKnob` (its inner knob takes the mouse filter too) and a `CompactSlider`.
static func dim_value_control(control: Control, type: int) -> void:
	var uses_gain := EqResponse.type_uses_gain(type)
	control.modulate.a = 1.0 if uses_gain else 0.25
	control.mouse_filter = Control.MOUSE_FILTER_PASS if uses_gain else Control.MOUSE_FILTER_IGNORE
	var inner: Variant = control.get("knob")
	if inner is Control:
		inner.mouse_filter = Control.MOUSE_FILTER_STOP if uses_gain else Control.MOUSE_FILTER_IGNORE
