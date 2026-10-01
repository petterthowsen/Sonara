## Panel view of the built-in EQ: a toolbar for the analyser mode and dB range, the curve editor
## (`EqCurveEditor`), and the knobs (type, Freq, Gain, Q) of the selected band plus Output gain.
## As the Window view it is the full editor with the piano strip; the Companion view
## (`EqBandsCompanionView`) then has the knobs of every band.
##
## Analyser mode, range, resolution, speed and tilt are view state, not parameters: they live in
## the app config (`EqViewState.CONFIG_KEY`) and are the same for every EQ. The view subscribes to
## the device's `"spectrum"` stream while shown (and the analyser isn't off) and unsubscribes when
## hidden. Resolution and speed are engine options (`data/configure`), sent after subscribing and
## whenever they change; tilt is applied only when drawing.
class_name EqDefaultView extends DeviceView

const STRIP_HEIGHT := 78.0
const RESOLUTION_LABELS: Array[String] = ["Low", "Medium", "High", "Max"]
const SPEED_LABELS: Array[String] = ["Fast", "Medium", "Slow"]
## Item ids in the Display menu: resolution, speed and tilt items start at these.
const MENU_RESOLUTION := 0
const MENU_SPEED := 10
const MENU_TILT := 20

var editor: EqCurveEditor = null
## Read and write the view state. Default: the app config (Sonara autoload); tests replace them.
var load_config := Callable(self, "_load_app_config")
var save_config := Callable(self, "_save_app_config")

var _analyser_option: OptionButton = null
var _range_option: OptionButton = null
var _display_menu: MenuButton = null
var _band_label: Label = null
var _type_option: OptionButton = null
var _freq_knob: LabeledKnob = null
var _gain_knob: LabeledKnob = null
var _q_knob: LabeledKnob = null
var _output_knob: LabeledKnob = null
var _band := -1
## Views subscribed per device path. The engine keeps one subscription per device, not one per
## view, so the panel and window views share it: the last one to unsubscribe cancels it.
static var _subscriber_counts := {}
var _subscribed := false
var _shown := false
## The analyser options last sent to the engine (-1: none since subscribing).
var _sent_resolution := -1
var _sent_speed := -1


func _ready() -> void:
	_build()


## True for the Window view: the same editor, with the piano strip and without the knob row (the
## companion view in the device panel has the knobs).
func _is_window() -> bool:
	return is_type(Device.ViewType.Window)


func _get_minimum_size() -> Vector2:
	return Vector2(640, 380) if _is_window() else Vector2(420, 250)


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
	_display_menu = MenuButton.new()
	_display_menu.text = "Display"
	_display_menu.flat = false
	_display_menu.tooltip_text = "Analyser resolution, speed and tilt"
	_build_display_menu(_display_menu.get_popup())
	toolbar.add_child(_display_menu)

	editor = EqCurveEditor.new()
	editor.show_piano = _is_window()
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.view_state_changed.connect(_on_editor_view_state_changed)
	editor.selection_changed.connect(_on_selection_changed)
	root.add_child(editor)

	# The selected band's knobs. No scrolling: the row is as wide as its content and the device
	# grows horizontally with it.
	var bottom := HBoxContainer.new()
	bottom.custom_minimum_size.y = STRIP_HEIGHT
	bottom.visible = not _is_window()
	bottom.add_theme_constant_override("separation", 10)
	root.add_child(bottom)
	_band_label = Label.new()
	_band_label.custom_minimum_size.x = 18
	bottom.add_child(_band_label)
	_type_option = OptionButton.new()
	_type_option.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for type_name in EqResponse.TYPE_NAMES:
		_type_option.add_item(type_name)
	_type_option.item_selected.connect(_on_type_selected)
	bottom.add_child(_type_option)
	_freq_knob = EqKnobs.make_knob("Freq", _on_band_knob_changed.bind(EqResponse.P_FREQ))
	_gain_knob = EqKnobs.make_knob("Gain", _on_band_knob_changed.bind(EqResponse.P_GAIN))
	_q_knob = EqKnobs.make_knob("Q", _on_band_knob_changed.bind(EqResponse.P_Q))
	for knob in [_freq_knob, _gain_knob, _q_knob]:
		bottom.add_child(knob)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	_output_knob = EqKnobs.make_knob("Out", _on_param_knob_changed.bind(EqResponse.OUTPUT_GAIN))
	bottom.add_child(_output_knob)

	_apply_state(_read_state())
	_refresh_band_controls()


func _build_display_menu(popup: PopupMenu) -> void:
	popup.hide_on_checkable_item_selection = false
	popup.add_separator("Resolution")
	for i in RESOLUTION_LABELS.size():
		popup.add_radio_check_item(RESOLUTION_LABELS[i], MENU_RESOLUTION + i)
	popup.add_separator("Speed")
	for i in SPEED_LABELS.size():
		popup.add_radio_check_item(SPEED_LABELS[i], MENU_SPEED + i)
	popup.add_separator("Tilt")
	for i in EqViewState.TILTS.size():
		var tilt := EqViewState.TILTS[i]
		popup.add_radio_check_item("Flat" if tilt == 0.0 else "%s dB/oct" % str(tilt), MENU_TILT + i)
	popup.id_pressed.connect(_on_display_item)


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(1, 1, 1, 0.6)
	return label


# ============================================================================
# BINDING
# ============================================================================

func _on_bind() -> void:
	_build()
	editor.device = device
	var audio_config := _autoload("AudioConfig")
	if audio_config != null and audio_config.config.has("sample_rate"):
		editor.sample_rate = float(audio_config.config["sample_rate"])
	EqKnobs.configure(_output_knob.knob, device, EqResponse.OUTPUT_GAIN, "%+.1f", " dB")
	_band = editor.selected_band
	_configure_band_knobs()
	_refresh_band_controls()
	_refresh_output()


func _on_unbind() -> void:
	_shown = false
	_sync_subscription()
	if editor != null:
		editor.device = null


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	if editor == null:
		return
	if param_id < EqResponse.BAND_COUNT * EqResponse.BAND_STRIDE:
		if param_id / EqResponse.BAND_STRIDE == _band:
			_refresh_band_controls()
	elif param_id == EqResponse.OUTPUT_GAIN:
		_refresh_output()


func _on_selection_changed(band: int) -> void:
	_band = band
	_configure_band_knobs()
	_refresh_band_controls()


## Aim the three knobs at the selected band's parameters.
func _configure_band_knobs() -> void:
	if device == null or _band < 0:
		return
	var base := _band * EqResponse.BAND_STRIDE
	EqKnobs.configure(_freq_knob.knob, device, base + EqResponse.P_FREQ, "%.0f", " Hz")
	EqKnobs.configure(_gain_knob.knob, device, base + EqResponse.P_GAIN, "%+.1f", " dB")
	EqKnobs.configure(_q_knob.knob, device, base + EqResponse.P_Q, "%.2f", "")


## Show the selected band's values; the whole row dims when no band is enabled.
func _refresh_band_controls() -> void:
	if _band_label == null:
		return
	var has_band := device != null and _band >= 0
	for control in [_band_label, _type_option, _freq_knob, _gain_knob, _q_knob]:
		control.modulate.a = 1.0 if has_band else 0.25
		control.mouse_filter = Control.MOUSE_FILTER_PASS if has_band else Control.MOUSE_FILTER_IGNORE
	_type_option.disabled = not has_band
	_freq_knob.knob.mouse_filter = Control.MOUSE_FILTER_STOP if has_band else Control.MOUSE_FILTER_IGNORE
	_q_knob.knob.mouse_filter = _freq_knob.knob.mouse_filter
	if not has_band:
		_band_label.text = ""
		return
	var base := _band * EqResponse.BAND_STRIDE
	var type := int(device.get_parameter_real(base + EqResponse.P_TYPE))
	_band_label.text = str(_band + 1)
	_band_label.add_theme_color_override("font_color", EqCurveEditor.band_color(_band))
	_type_option.select(type)
	_freq_knob.knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_FREQ))
	_gain_knob.knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_GAIN))
	_q_knob.knob.set_value_no_signal(device.get_parameter_real(base + EqResponse.P_Q))
	EqKnobs.dim_gain(_gain_knob, type)


func _refresh_output() -> void:
	if device != null:
		_output_knob.knob.set_value_no_signal(device.get_parameter_real(EqResponse.OUTPUT_GAIN))


func _on_band_knob_changed(value: float, offset: int) -> void:
	if device != null and _band >= 0:
		device.set_parameter_real(_band * EqResponse.BAND_STRIDE + offset, value)


func _on_type_selected(index: int) -> void:
	if device != null and _band >= 0:
		device.set_parameter_real(_band * EqResponse.BAND_STRIDE + EqResponse.P_TYPE, float(index))


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
	_refresh_display_menu()
	_sync_subscription()


## Tick the current resolution, speed and tilt in the Display menu.
func _refresh_display_menu() -> void:
	var popup := _display_menu.get_popup()
	var state := editor.state
	for i in RESOLUTION_LABELS.size():
		popup.set_item_checked(popup.get_item_index(MENU_RESOLUTION + i), i == state.resolution)
	for i in SPEED_LABELS.size():
		popup.set_item_checked(popup.get_item_index(MENU_SPEED + i), i == state.speed)
	for i in EqViewState.TILTS.size():
		popup.set_item_checked(popup.get_item_index(MENU_TILT + i), is_equal_approx(EqViewState.TILTS[i], state.tilt_db))


func _on_display_item(id: int) -> void:
	if id >= MENU_TILT:
		editor.set_tilt_db(EqViewState.TILTS[id - MENU_TILT])
	elif id >= MENU_SPEED:
		editor.set_speed(id - MENU_SPEED)
	else:
		editor.set_resolution(id - MENU_RESOLUTION)


func _on_analyser_selected(index: int) -> void:
	editor.set_analyser_mode(index)


func _on_range_selected(index: int) -> void:
	editor.set_range_db(DbGrid.EQ_RANGES[index])


func _on_editor_view_state_changed() -> void:
	save_config.call(EqViewState.CONFIG_KEY, editor.state.to_dict())
	_refresh_display_menu()
	_sync_subscription()
	_send_analyser_options()


## Subscribe while shown and the analyser is on; unsubscribe otherwise.
func _sync_subscription() -> void:
	var want := _shown and device != null and editor != null and editor.state.analyser != EqViewState.Analyser.OFF
	if want == _subscribed:
		return
	_sent_resolution = -1
	_sent_speed = -1
	var osc := _autoload("AudioEngineOSC")
	if osc == null:
		return
	var path: String = device.osc_path()
	var count: int = _subscriber_counts.get(path, 0)
	if want:
		_subscriber_counts[path] = count + 1
		if count == 0:
			osc.subscribe_device_data(path, "spectrum")
		if not osc.device_spectrum_received.is_connected(_on_spectrum_received):
			osc.device_spectrum_received.connect(_on_spectrum_received)
	else:
		_subscriber_counts[path] = maxi(count - 1, 0)
		if count <= 1:
			_subscriber_counts.erase(path)
			osc.unsubscribe_device_data(path, "spectrum")
		if osc.device_spectrum_received.is_connected(_on_spectrum_received):
			osc.device_spectrum_received.disconnect(_on_spectrum_received)
	_subscribed = want
	_send_analyser_options()


## Send resolution and speed to the engine when subscribed and they changed since the last send.
## The engine ignores a resolution it already has, so a second view resending is harmless.
func _send_analyser_options() -> void:
	if not _subscribed or device == null:
		return
	var osc := _autoload("AudioEngineOSC")
	if osc == null:
		return
	var path: String = device.osc_path()
	if editor.state.resolution != _sent_resolution:
		_sent_resolution = editor.state.resolution
		osc.configure_device_data(path, "spectrum", "resolution", float(_sent_resolution))
	if editor.state.speed != _sent_speed:
		_sent_speed = editor.state.speed
		osc.configure_device_data(path, "spectrum", "speed", float(_sent_speed))


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
