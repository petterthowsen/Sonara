## Companion view of the built-in EQ, shown in the device panel while the window view (the full
## analyser) is open: one vertical strip per band with an on/off toggle, the type
## icon and Freq, Gain and Q knobs. It holds the exact-entry and automation targets the panel view
## has no room for (it shows only the selected band).
class_name EqBandsCompanionView extends DeviceView

var _items: Array[Dictionary] = []
var _built := false
var _row: HBoxContainer = null


func _ready() -> void:
	_build()


## The strips' own size, so the device panel grows to fit them instead of the row overflowing it.
func _get_minimum_size() -> Vector2:
	return _row.get_combined_minimum_size() if _row != null else Vector2.ZERO


func _build() -> void:
	if _built:
		return
	_built = true
	_row = HBoxContainer.new()
	_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_row.add_theme_constant_override("separation", 8)
	_row.minimum_size_changed.connect(update_minimum_size)
	add_child(_row)
	for band in EqResponse.BAND_COUNT:
		_items.append(_build_strip(band, _row))
	update_minimum_size()


func _build_strip(band: int, parent: Control) -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	parent.add_child(box)
	var toggle := CheckBox.new()
	toggle.text = str(band + 1)
	toggle.add_theme_color_override("font_color", EqCurveEditor.band_color(band))
	toggle.toggled.connect(_on_toggled.bind(band))
	box.add_child(toggle)
	var icon := EqTypeIcon.new()
	icon.color = EqCurveEditor.band_color(band)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(icon)
	var item := {"box": box, "toggle": toggle, "icon": icon}
	for entry in [["freq", "Freq", EqResponse.P_FREQ], ["gain", "Gain", EqResponse.P_GAIN], ["q", "Q", EqResponse.P_Q]]:
		var knob := EqKnobs.make_knob(entry[1], _on_knob_changed.bind(band * EqResponse.BAND_STRIDE + int(entry[2])))
		knob.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(knob)
		item[entry[0]] = knob
	return item


func _on_bind() -> void:
	_build()
	for band in EqResponse.BAND_COUNT:
		var base := band * EqResponse.BAND_STRIDE
		EqKnobs.configure(_items[band]["freq"].knob, device, base + EqResponse.P_FREQ, "%.0f", " Hz")
		EqKnobs.configure(_items[band]["gain"].knob, device, base + EqResponse.P_GAIN, "%+.1f", " dB")
		EqKnobs.configure(_items[band]["q"].knob, device, base + EqResponse.P_Q, "%.2f", "")
		_refresh_band(band)


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	if _built and param_id < EqResponse.BAND_COUNT * EqResponse.BAND_STRIDE:
		_refresh_band(param_id / EqResponse.BAND_STRIDE)


func _refresh_band(band: int) -> void:
	if device == null:
		return
	var item := _items[band]
	var base := band * EqResponse.BAND_STRIDE
	var enabled := device.get_parameter_real(base + EqResponse.P_ENABLED) >= 0.5
	var type := int(device.get_parameter_real(base + EqResponse.P_TYPE))
	item["toggle"].set_pressed_no_signal(enabled)
	item["icon"].type = type
	item["freq"].knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_FREQ))
	item["gain"].knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_GAIN))
	item["q"].knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_Q))
	# A disabled band stays editable (set it up, then switch it on), only dimmed.
	item["box"].modulate.a = 1.0 if enabled else 0.55
	EqKnobs.dim_gain(item["gain"], type)


func _on_toggled(pressed: bool, band: int) -> void:
	if device != null:
		device.set_parameter_real(band * EqResponse.BAND_STRIDE + EqResponse.P_ENABLED, 1.0 if pressed else 0.0)


func _on_knob_changed(value: float, param_id: int) -> void:
	if device != null:
		device.set_parameter_real(param_id, value)
