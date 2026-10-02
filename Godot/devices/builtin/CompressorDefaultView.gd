## Panel view of the built-in Compressor. The layout lives in `CompressorDefaultView.tscn` (box and
## flow containers, so it can be tuned in the editor); this script wires it to the device.
##
## Main page, left to right: Threshold and Ratio faders, the visualization (the transfer curve or
## the scope, chosen with the `Curve | Scope` control), the In / GR / Out meters with a
## `Peak | RMS` metering switch, and the Output (Makeup) fader. Knee, Mix, Attack, Release, Style
## and Auto Release sit in a strip below. The Detector page (a second header tab) has Detection,
## Channels, Stereo Link, SC Low Cut, Range and SC Listen.
##
## Curve / Scope and Peak / RMS are view state, not parameters: they live in the app config
## (`CONFIG_KEY`) and are the same for every compressor.
##
## The view subscribes to the device's `"dynamics"` stream while it is shown and unsubscribes
## when hidden. It talks to the engine only through `DeviceInstance.set_parameter_real` and
## references autoloads by name, so the tests can drive it headless.
class_name CompressorDefaultView extends DeviceView

const CONFIG_KEY := "devices/compressor/view"
enum Display { CURVE, SCOPE }
enum Metering { PEAK, RMS }
enum Page { MAIN, DETECTOR }

static var logger := Log.make("CompressorView")

## Read and write the view state. Default: the app config (Sonara autoload); tests replace them.
var load_config := Callable(self, "_load_app_config")
var save_config := Callable(self, "_save_app_config")

var display := Display.CURVE
var metering := Metering.PEAK

@onready var curve: CompressorCurve = %Curve
@onready var scope_top: CompressorScope = %ScopeTop
@onready var scope_bottom: CompressorScope = %ScopeBottom
@onready var scope_stack: Control = %ScopeStack
@onready var main_page: Control = %MainPage
@onready var detector_page: Control = %DetectorPage

@onready var threshold_fader: Fader = %ThresholdFader
@onready var ratio_fader: Fader = %RatioFader
@onready var output_fader: Fader = %OutputFader
@onready var in_meter: LevelMeter = %InMeter
@onready var gr_meter: LevelMeter = %GrMeter
@onready var out_meter: LevelMeter = %OutMeter
@onready var display_control: SegmentedControl = %DisplayControl
@onready var metering_control: SegmentedControl = %MeteringControl
@onready var style_control: SegmentedControl = %StyleControl
@onready var detection_control: SegmentedControl = %DetectionControl
@onready var channels_control: SegmentedControl = %ChannelsControl
@onready var auto_gain: CheckBox = %AutoGain
@onready var auto_release: CheckBox = %AutoRelease
@onready var sc_listen: CheckBox = %ScListen

var _faders: Array[Dictionary] = []
var _sliders: Array[Dictionary] = []
var _knobs: Array[Dictionary] = []
var _toggles: Array[Dictionary] = []
var _page := Page.MAIN
var _built := false
var _sample_rate := 48_000.0
var _logged_first_blob := false
var _subscribed := false
var _shown := false


func _ready() -> void:
	_build()
	if device != null:
		_setup()


## The Window view gets more room; the panel's size comes from the scene.
func _get_minimum_size() -> Vector2:
	return Vector2(900, 360) if is_type(Device.ViewType.Window) else Vector2.ZERO


## Hook the scene's controls to their handlers, once. Nothing here needs the device.
func _build() -> void:
	if _built:
		return
	_built = true
	display_control.selected_changed.connect(_on_display_selected)
	metering_control.selected_changed.connect(_on_metering_selected)
	style_control.selected_changed.connect(_on_option_selected.bind(CompressorData.P_STYLE))
	detection_control.selected_changed.connect(_on_option_selected.bind(CompressorData.P_DETECTION))
	channels_control.selected_changed.connect(_on_option_selected.bind(CompressorData.P_CHANNELS))

	_add_fader(threshold_fader, %ThresholdValue, CompressorData.P_THRESHOLD, "%.1f dB")
	_add_fader(ratio_fader, %RatioValue, CompressorData.P_RATIO, "")
	_add_fader(output_fader, %OutputValue, CompressorData.P_MAKEUP, "%+.1f dB")

	_add_slider(%KneeSlider, %KneeValue, CompressorData.P_KNEE, "%.1f dB")
	_add_slider(%MixSlider, %MixValue, CompressorData.P_MIX, "%.0f %%")
	_add_slider(%AttackSlider, %AttackValue, CompressorData.P_ATTACK, "%.2f ms")
	_add_slider(%ReleaseSlider, %ReleaseValue, CompressorData.P_RELEASE, "%.0f ms")

	_add_knob(%LinkKnob, CompressorData.P_STEREO_LINK, "%.0f", "%")
	_add_knob(%ScCutKnob, CompressorData.P_SC_LOW_CUT, "%.0f", "Hz")
	_add_knob(%RangeKnob, CompressorData.P_RANGE, "%.0f", "dB")

	_add_toggle(auto_gain, CompressorData.P_AUTO_GAIN)
	_add_toggle(auto_release, CompressorData.P_AUTO_RELEASE)
	_add_toggle(sc_listen, CompressorData.P_SC_LISTEN)

	scope_top.corner_text = "≈4 s"
	for meter in [in_meter, out_meter]:
		meter.hold_time = 1.5
	_apply_state(CompressorViewState.from_dict(load_config.call(CONFIG_KEY)))


func _add_fader(fader: Fader, value_label: Label, param_id: int, format: String) -> void:
	fader.value_changed.connect(_on_fader_changed.bind(param_id))
	fader.reset_requested.connect(_on_reset_requested.bind(param_id))
	_faders.append({"fader": fader, "label": value_label, "id": param_id, "format": format})


func _add_slider(slider: HorSlider, value_label: Label, param_id: int, format: String) -> void:
	slider.value_changed.connect(_on_slider_changed.bind(param_id))
	slider.reset_requested.connect(_on_reset_requested.bind(param_id))
	_sliders.append({"slider": slider, "label": value_label, "id": param_id, "format": format})


func _add_knob(knob: LabeledKnob, param_id: int, format: String, unit: String) -> void:
	knob.knob.value_changed.connect(_on_fader_changed.bind(param_id))
	_knobs.append({"knob": knob, "id": param_id, "format": format, "unit": unit})


func _add_toggle(check: CheckBox, param_id: int) -> void:
	check.toggled.connect(_on_toggle_toggled.bind(param_id))
	_toggles.append({"check": check, "id": param_id})


# ============================================================================
# BINDING
# ============================================================================

func _on_bind() -> void:
	if is_node_ready():
		_setup()


## Everything that needs both the scene and the device.
func _setup() -> void:
	curve.device = device
	scope_top.device = device
	scope_bottom.device = device
	var audio_config := _autoload("AudioConfig")
	if audio_config != null and audio_config.config.has("sample_rate"):
		_sample_rate = float(audio_config.config["sample_rate"])
	scope_top.set_sample_rate(_sample_rate)
	scope_bottom.set_sample_rate(_sample_rate)
	_configure_controls()
	_refresh()


func _on_unbind() -> void:
	if not is_node_ready():
		return
	curve.device = null
	scope_top.device = null
	scope_bottom.device = null


func _on_device_parameter_changed(_param_id: int, _value: float) -> void:
	if is_node_ready():
		_refresh()


## Point each control at its parameter's range and curve (real units; the device converts).
func _configure_controls() -> void:
	for entry in _faders:
		var param := device.get_parameter(int(entry["id"]))
		if param == null:
			continue
		var fader: Fader = entry["fader"]
		fader.min_value = param.min_value
		fader.max_value = param.max_value
		fader.value_default = param.default_value
		if int(entry["id"]) == CompressorData.P_RATIO:
			# Reversed: 1:1 at the top, ∞:1 at the bottom.
			fader.to_position = func(v: float) -> float: return 1.0 - param.value_to_normalized(v)
			fader.from_position = func(n: float) -> float: return param.normalized_to_value(1.0 - n)
		fader.value_text_callback = _fader_text.bind(entry)
	for entry in _knobs:
		var param := device.get_parameter(int(entry["id"]))
		if param == null:
			continue
		var knob: RotaryKnob = (entry["knob"] as LabeledKnob).knob
		knob.min_value = param.min_value
		knob.max_value = param.max_value
		knob.logarithmic = param.is_logarithmic
		knob.value_default = param.default_value
		if int(entry["id"]) == CompressorData.P_SC_LOW_CUT:
			knob.value_text_callback = func(value: float) -> String:
				return "Off" if value <= 0.5 else "%.0f Hz" % value
		else:
			knob.value_format = entry["format"]
			knob.unit = entry["unit"]
	for entry in _sliders:
		var param := device.get_parameter(int(entry["id"]))
		if param != null:
			(entry["slider"] as HorSlider).default_value = param.value_to_normalized(param.default_value)


func _fader_text(value: float, entry: Dictionary) -> String:
	if int(entry["id"]) == CompressorData.P_RATIO:
		return CompressorData.format_ratio(value)
	return String(entry["format"]) % value


func _refresh() -> void:
	if device == null or not is_node_ready():
		return
	# Toggles first: Auto Gain decides what the Output fader shows.
	for entry in _toggles:
		(entry["check"] as CheckBox).set_pressed_no_signal(device.get_parameter_real(int(entry["id"])) >= 0.5)
	for entry in _faders:
		var fader: Fader = entry["fader"]
		var value := device.get_parameter_real(int(entry["id"]))
		if int(entry["id"]) == CompressorData.P_MAKEUP and auto_gain.button_pressed:
			# Auto Gain replaces Makeup: show the gain it applies, read-only.
			value = clampf(_auto_makeup_db(), fader.min_value, fader.max_value)
		fader.set_value_no_signal(value)
		(entry["label"] as Label).text = _fader_text(value, entry) + (" auto" if fader == output_fader and auto_gain.button_pressed else "")
	for entry in _sliders:
		var param := device.get_parameter(int(entry["id"]))
		if param == null:
			continue
		var real := device.get_parameter_real(int(entry["id"]))
		(entry["slider"] as HorSlider).set_value_no_signal(param.value_to_normalized(real))
		(entry["label"] as Label).text = String(entry["format"]) % real
	for entry in _knobs:
		(entry["knob"] as LabeledKnob).knob.set_value_no_signal(device.get_parameter_real(int(entry["id"])))
	style_control.set_selected_no_signal(int(device.get_parameter_real(CompressorData.P_STYLE)))
	detection_control.set_selected_no_signal(int(device.get_parameter_real(CompressorData.P_DETECTION)))
	channels_control.set_selected_no_signal(int(device.get_parameter_real(CompressorData.P_CHANNELS)))

	var range_db := device.get_parameter_real(CompressorData.P_RANGE)
	gr_meter.max_db = 12.0 if range_db <= 12.0 else (24.0 if range_db <= 24.0 else 48.0)
	output_fader.editable = not auto_gain.button_pressed
	curve.refresh()
	scope_top.refresh()
	scope_bottom.refresh()


## The makeup Auto Gain adds with the current settings (what the engine computes).
func _auto_makeup_db() -> float:
	return CompressorData.auto_makeup_db(
		device.get_parameter_real(CompressorData.P_THRESHOLD),
		device.get_parameter_real(CompressorData.P_RATIO),
		device.get_parameter_real(CompressorData.P_KNEE),
		device.get_parameter_real(CompressorData.P_RANGE))


func _on_fader_changed(value: float, param_id: int) -> void:
	if device != null:
		device.set_parameter_real(param_id, value)


func _on_slider_changed(normalized: float, param_id: int) -> void:
	if device == null:
		return
	var param := device.get_parameter(param_id)
	if param != null:
		device.set_parameter_real(param_id, param.normalized_to_value(normalized))


func _on_reset_requested(param_id: int) -> void:
	if device == null:
		return
	var param := device.get_parameter(param_id)
	if param != null:
		device.set_parameter_real(param_id, param.default_value)


func _on_toggle_toggled(pressed: bool, param_id: int) -> void:
	if device != null:
		device.set_parameter_real(param_id, 1.0 if pressed else 0.0)


func _on_option_selected(index: int, param_id: int) -> void:
	if device != null:
		device.set_parameter_real(param_id, float(index))


# ============================================================================
# VIEW STATE
# ============================================================================

func _apply_state(state: CompressorViewState) -> void:
	display = state.display
	metering = state.metering
	display_control.set_selected_no_signal(display)
	metering_control.set_selected_no_signal(metering)
	curve.visible = display == Display.CURVE
	scope_stack.visible = display == Display.SCOPE
	var level_display := LevelMeter.Display.RMS if metering == Metering.RMS else LevelMeter.Display.PEAK
	in_meter.display = level_display
	out_meter.display = level_display


func _on_display_selected(index: int) -> void:
	_set_view_state(index, metering)


func _on_metering_selected(index: int) -> void:
	_set_view_state(display, index)


func _set_view_state(new_display: int, new_metering: int) -> void:
	var state := CompressorViewState.new()
	state.display = new_display
	state.metering = new_metering
	_apply_state(state)
	save_config.call(CONFIG_KEY, state.to_dict())


# ============================================================================
# HEADER TABS
# ============================================================================

func get_header_tabs() -> PackedStringArray:
	return PackedStringArray(["Main", "Detector"])


func get_header_tab() -> int:
	return _page


func select_header_tab(index: int) -> void:
	if index == _page or index < 0 or index > Page.DETECTOR:
		return
	_page = index as Page
	main_page.visible = _page == Page.MAIN
	detector_page.visible = _page == Page.DETECTOR
	header_tabs_changed.emit()


# ============================================================================
# DATA STREAM
# ============================================================================

func _on_view_shown() -> void:
	_shown = true
	_sync_subscription()


func _on_view_hidden() -> void:
	_shown = false
	_sync_subscription()
	if not is_node_ready():
		return
	curve.dragging = false
	scope_top.clear()
	scope_bottom.clear()


func _sync_subscription() -> void:
	var want := _shown and device != null
	if want == _subscribed:
		return
	var osc := _autoload("AudioEngineOSC")
	if osc == null:
		return
	logger.debug("%s dynamics path=%s" % ["subscribe" if want else "unsubscribe", device.osc_path()])
	if want:
		_logged_first_blob = false
		osc.subscribe_device_data(device.osc_path(), "dynamics")
		if not osc.device_data_received.is_connected(_on_dynamics_received):
			osc.device_data_received.connect(_on_dynamics_received)
	else:
		osc.unsubscribe_device_data(device.osc_path(), "dynamics")
		if osc.device_data_received.is_connected(_on_dynamics_received):
			osc.device_data_received.disconnect(_on_dynamics_received)
	_subscribed = want


func _on_dynamics_received(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type != "dynamics":
		return
	if device == null or osc_path != device.osc_path():
		return
	if not _logged_first_blob:
		_logged_first_blob = true
		logger.debug("first dynamics blob: %d bytes, visible=%s" % [blob.size(), is_visible_in_tree()])
	_apply_dynamics(CompressorData.decode(blob))


## Feed a decoded blob to the scopes, the meters, the live dot and the Threshold fader's bar.
## Without a summary (an older engine) the meters show the records' peaks on both sides.
func _apply_dynamics(decoded: Dictionary) -> void:
	var count := int(decoded.get("count", 0))
	if count <= 0:
		return
	scope_top.push_records(decoded)
	scope_bottom.push_records(decoded)
	var summary: Dictionary = decoded.get("summary", {})
	if summary.is_empty():
		var input_peak := -160.0
		var output_peak := -160.0
		var reduction := 0.0
		for i in count:
			input_peak = maxf(input_peak, decoded["in_peak_db"][i])
			output_peak = maxf(output_peak, decoded["out_peak_db"][i])
			reduction = maxf(reduction, decoded["gr_db"][i])
		summary = {
			"in_peak_l": input_peak, "in_peak_r": input_peak,
			"out_peak_l": output_peak, "out_peak_r": output_peak,
			"in_rms_l": NAN, "in_rms_r": NAN, "out_rms_l": NAN, "out_rms_r": NAN,
			"detector_db": input_peak, "gr_max_db": reduction,
		}
	in_meter.push(0, summary["in_peak_l"], summary["in_rms_l"])
	in_meter.push(1, summary["in_peak_r"], summary["in_rms_r"])
	out_meter.push(0, summary["out_peak_l"], summary["out_rms_l"])
	out_meter.push(1, summary["out_peak_r"], summary["out_rms_r"])
	gr_meter.push(0, maxf(summary["gr_max_db"], 0.0))
	var detector: float = summary["detector_db"]
	curve.push_live_level(detector)
	threshold_fader.overlay_level = clampf(
		(detector - threshold_fader.min_value) / (threshold_fader.max_value - threshold_fader.min_value), 0.0, 1.0)


func _load_app_config(key: String) -> Variant:
	var sonara := _autoload("Sonara")
	return sonara.get_config(key, {}) if sonara != null else {}


func _save_app_config(key: String, value: Variant) -> void:
	var sonara := _autoload("Sonara")
	if sonara == null:
		return
	sonara.set_config(key, value)
	sonara.save_config()


func _autoload(autoload_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(autoload_name) if tree != null else null
