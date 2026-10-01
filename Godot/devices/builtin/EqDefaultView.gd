## Panel view of the built-in EQ: the curve editor (`EqCurveEditor`) over a strip of Freq, Gain and
## Q knobs for each enabled band (exact entry, and targets for automation), a toolbar for the
## analyser mode and dB range, and the Output gain.
##
## Analyser mode and range are view state, not parameters: they live in the app config
## (`EqViewState.CONFIG_KEY`) and are the same for every EQ. The view subscribes to the device's
## `"spectrum"` stream while shown (and the analyser isn't off) and unsubscribes when hidden.
class_name EqDefaultView extends DeviceView

const STRIP_HEIGHT := 74.0
const KNOB_SIZE := Vector2(28, 28)
const KNOB_LABEL_WIDTH := 34.0

var editor: EqCurveEditor = null
## Read and write the view state. Default: the app config (Sonara autoload); tests replace them.
var load_config := Callable(self, "_load_app_config")
var save_config := Callable(self, "_save_app_config")

var _analyser_option: OptionButton = null
var _range_option: OptionButton = null
var _strip: HBoxContainer = null
var _items: Array[Dictionary] = []
var _output_knob: LabeledKnob = null
var _subscribed := false
var _shown := false


func _ready() -> void:
	_build()


func _get_minimum_size() -> Vector2:
	return Vector2(480, 250)


func _build() -> void:
	if editor != null:
		return
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 3)
	add_child(root)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	root.add_child(toolbar)
	toolbar.add_child(_caption("Analyser"))
	_analyser_option = OptionButton.new()
	for name in ["Post", "Pre", "Off"]:
		_analyser_option.add_item(name)
	_analyser_option.item_selected.connect(_on_analyser_selected)
	toolbar.add_child(_analyser_option)
	toolbar.add_child(_caption("Range"))
	_range_option = OptionButton.new()
	for range_db in DbGrid.EQ_RANGES:
		_range_option.add_item("±%d dB" % int(range_db))
	_range_option.item_selected.connect(_on_range_selected)
	toolbar.add_child(_range_option)

	editor = EqCurveEditor.new()
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.view_state_changed.connect(_on_editor_view_state_changed)
	root.add_child(editor)

	var bottom := HBoxContainer.new()
	bottom.custom_minimum_size.y = STRIP_HEIGHT
	bottom.add_theme_constant_override("separation", 8)
	root.add_child(bottom)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bottom.add_child(scroll)
	_strip = HBoxContainer.new()
	_strip.add_theme_constant_override("separation", 10)
	scroll.add_child(_strip)
	for i in EqResponse.BAND_COUNT:
		_items.append(_build_band_item(i))

	_output_knob = LabeledKnob.new()
	_output_knob.text = "Out"
	_output_knob.knob_size = KNOB_SIZE
	_output_knob.label_width = KNOB_LABEL_WIDTH
	_output_knob.knob.value_changed.connect(_on_param_knob_changed.bind(EqResponse.OUTPUT_GAIN))
	bottom.add_child(_output_knob)

	_apply_state(_read_state())


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(1, 1, 1, 0.6)
	return label


func _build_band_item(band: int) -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	_strip.add_child(box)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	box.add_child(header)
	var number := Label.new()
	number.text = str(band + 1)
	number.add_theme_color_override("font_color", EqCurveEditor.band_color(band))
	header.add_child(number)
	var icon := EqTypeIcon.new()
	icon.color = EqCurveEditor.band_color(band)
	header.add_child(icon)
	var knobs := HBoxContainer.new()
	knobs.add_theme_constant_override("separation", 2)
	box.add_child(knobs)
	var item := {"root": box, "icon": icon}
	for entry in [["freq", "Freq", EqResponse.P_FREQ], ["gain", "Gain", EqResponse.P_GAIN], ["q", "Q", EqResponse.P_Q]]:
		var knob := LabeledKnob.new()
		knob.text = entry[1]
		knob.knob_size = KNOB_SIZE
		knob.label_width = KNOB_LABEL_WIDTH
		knob.knob.value_changed.connect(_on_param_knob_changed.bind(band * EqResponse.BAND_STRIDE + int(entry[2])))
		knobs.add_child(knob)
		item[entry[0]] = knob
	return item


# ============================================================================
# BINDING
# ============================================================================

func _on_bind() -> void:
	_build()
	editor.device = device
	var audio_config := _autoload("AudioConfig")
	if audio_config != null and audio_config.config.has("sample_rate"):
		editor.sample_rate = float(audio_config.config["sample_rate"])
	_configure_knobs()
	_refresh_strip()


func _on_unbind() -> void:
	if editor != null:
		editor.device = null


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	if editor == null:
		return
	if param_id < EqResponse.BAND_COUNT * EqResponse.BAND_STRIDE:
		_refresh_band(param_id / EqResponse.BAND_STRIDE)
	elif param_id == EqResponse.OUTPUT_GAIN:
		_refresh_output()


## Point each knob at its parameter's range and curve (real units; the device converts).
func _configure_knobs() -> void:
	for band in EqResponse.BAND_COUNT:
		var item := _items[band]
		var base := band * EqResponse.BAND_STRIDE
		_configure_knob(item["freq"].knob, base + EqResponse.P_FREQ, "%.0f", " Hz")
		_configure_knob(item["gain"].knob, base + EqResponse.P_GAIN, "%+.1f", " dB")
		_configure_knob(item["q"].knob, base + EqResponse.P_Q, "%.2f", "")
	_configure_knob(_output_knob.knob, EqResponse.OUTPUT_GAIN, "%+.1f", " dB")


func _configure_knob(knob: RotaryKnob, param_id: int, format: String, unit_suffix: String) -> void:
	var param := device.get_parameter(param_id)
	if param == null:
		return
	knob.min_value = param.min_value
	knob.max_value = param.max_value
	knob.logarithmic = param.is_logarithmic
	knob.value_default = param.default_value
	knob.value_format = format
	knob.value_text_callback = func(value: float) -> String:
		if param_id % EqResponse.BAND_STRIDE == EqResponse.P_FREQ and param_id < EqResponse.OUTPUT_GAIN:
			return FreqAxis.format_hz(value) + " Hz"
		return (format % value) + unit_suffix


func _refresh_strip() -> void:
	for band in EqResponse.BAND_COUNT:
		_refresh_band(band)
	_refresh_output()


func _refresh_band(band: int) -> void:
	if device == null or band < 0 or band >= _items.size():
		return
	var item := _items[band]
	var base := band * EqResponse.BAND_STRIDE
	var enabled := device.get_parameter_real(base + EqResponse.P_ENABLED) >= 0.5
	var type := int(device.get_parameter_real(base + EqResponse.P_TYPE))
	item["root"].visible = enabled
	item["icon"].type = type
	item["freq"].knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_FREQ))
	item["gain"].knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_GAIN))
	item["q"].knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_Q))
	# Gain means nothing for cuts, notches and band passes: dim it rather than shifting the row.
	var uses_gain := EqResponse.type_uses_gain(type)
	item["gain"].modulate.a = 1.0 if uses_gain else 0.25
	item["gain"].mouse_filter = Control.MOUSE_FILTER_PASS if uses_gain else Control.MOUSE_FILTER_IGNORE
	item["gain"].knob.mouse_filter = Control.MOUSE_FILTER_STOP if uses_gain else Control.MOUSE_FILTER_IGNORE


func _refresh_output() -> void:
	if device != null:
		_output_knob.knob.set_value_no_signal(device.get_parameter_real(EqResponse.OUTPUT_GAIN))


func _on_param_knob_changed(value: float, param_id: int) -> void:
	if device != null:
		device.set_parameter_real(param_id, value)


# ============================================================================
# VIEW STATE AND ANALYSER
# ============================================================================

func _read_state() -> EqViewState:
	var data: Variant = load_config.call(EqViewState.CONFIG_KEY)
	return EqViewState.from_dict(data)


## Show `state` in the editor and the toolbar.
func _apply_state(state: EqViewState) -> void:
	editor.state = state
	_analyser_option.select(state.analyser)
	_range_option.select(maxi(DbGrid.EQ_RANGES.find(state.range_db), 0))
	_sync_subscription()


func _on_analyser_selected(index: int) -> void:
	editor.set_analyser_mode(index)


func _on_range_selected(index: int) -> void:
	editor.set_range_db(DbGrid.EQ_RANGES[index])


func _on_editor_view_state_changed() -> void:
	save_config.call(EqViewState.CONFIG_KEY, editor.state.to_dict())
	_sync_subscription()


## Subscribe while shown and the analyser is on; unsubscribe otherwise.
func _sync_subscription() -> void:
	var want := _shown and device != null and editor != null and editor.state.analyser != EqViewState.Analyser.OFF
	if want == _subscribed:
		return
	var osc := _autoload("AudioEngineOSC")
	if osc == null:
		return
	if want:
		osc.subscribe_device_data(device.osc_path(), "spectrum")
		if not osc.device_spectrum_received.is_connected(_on_spectrum_received):
			osc.device_spectrum_received.connect(_on_spectrum_received)
	else:
		osc.unsubscribe_device_data(device.osc_path(), "spectrum")
		if osc.device_spectrum_received.is_connected(_on_spectrum_received):
			osc.device_spectrum_received.disconnect(_on_spectrum_received)
	_subscribed = want


func _on_view_shown() -> void:
	_shown = true
	_sync_subscription()


func _on_view_hidden() -> void:
	_shown = false
	_sync_subscription()
	if editor != null:
		editor.end_interaction()
		editor.clear_analyser()


func _on_spectrum_received(osc_path: String, frame: PackedFloat32Array) -> void:
	if device != null and osc_path == device.osc_path() and editor != null:
		editor.on_spectrum_frame(frame)


# ============================================================================
# APP CONFIG (Sonara autoload, looked up by name so the script also loads without it)
# ============================================================================

func _autoload(autoload_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(autoload_name) if tree != null else null


func _load_app_config(key: String) -> Variant:
	var sonara := _autoload("Sonara")
	return sonara.get_config(key, {}) if sonara != null else {}


func _save_app_config(key: String, value: Variant) -> void:
	var sonara := _autoload("Sonara")
	if sonara == null:
		return
	sonara.set_config(key, value)
	sonara.save_config()
