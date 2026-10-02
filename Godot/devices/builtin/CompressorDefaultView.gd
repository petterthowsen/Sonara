## Panel view of the built-in Compressor: the transfer curve with a live dot over the input
## history, input/output/gain-reduction meters, the main row of knobs, a Style segmented control
## and a collapsible Detector pane (Detection, Stereo Link, Channels, SC Low Cut, SC Listen,
## Range).
##
## The view subscribes to the device's `"dynamics"` stream while it is shown and unsubscribes
## when hidden. It talks to the engine only through `DeviceInstance.set_parameter_real` and
## references autoloads by name, so the tests can drive it headless.
class_name CompressorDefaultView extends DeviceView

const METER_WIDTH := 34.0
const KNOB_SIZE := Vector2(30, 30)
const KNOB_LABEL_WIDTH := 36.0

var curve: CompressorCurve = null
var history: CompressorHistory = null
var meters: Control = null
static var logger := Log.make("CompressorView")
var _sample_rate := 48_000.0
var _logged_first_blob := false

var _threshold_knob: LabeledKnob = null
var _ratio_knob: LabeledKnob = null
var _attack_knob: LabeledKnob = null
var _release_knob: LabeledKnob = null
var _knee_knob: LabeledKnob = null
var _makeup_knob: LabeledKnob = null
var _mix_knob: LabeledKnob = null
var _range_knob: LabeledKnob = null
var _link_knob: LabeledKnob = null
var _sc_cut_knob: LabeledKnob = null

var _style_buttons: Array[Button] = []
var _auto_release: CheckBox = null
var _auto_gain: CheckBox = null
var _sc_listen: CheckBox = null
var _detection_option: OptionButton = null
var _channels_option: OptionButton = null
var _detector_pane: Control = null
var _detector_button: Button = null

var _subscribed := false
var _shown := false


## Input/output/gain-reduction meters, with a peak hold on each.
class Meters extends Control:
	const BAR_WIDTH := 9.0
	const GAP := 4.0
	const LEVEL_MIN_DB := -60.0
	const LEVEL_MAX_DB := 12.0
	const GR_MAX_DB := 24.0
	const HOLD_FALL_DB_PER_SECOND := 24.0
	const ATTACK_SECONDS := 0.03
	const FALL_DB_PER_SECOND := 60.0

	var input_db := -160.0
	var output_db := -160.0
	var reduction_db := 0.0
	var input_hold := -160.0
	var output_hold := -160.0
	var reduction_hold := 0.0
	var _input_target := -160.0
	var _output_target := -160.0
	var _reduction_target := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(BAR_WIDTH * 3.0 + GAP * 2.0, 80)
		set_process(false)
		clip_contents = true

	## Blobs arrive at about 12 Hz, so `push` only sets targets; `_process` eases the bars every
	## frame (fast attack, steady fall) and lets the holds fall.
	func push(input_level: float, output_level: float, reduction: float, _delta: float) -> void:
		_input_target = input_level
		_output_target = output_level
		_reduction_target = maxf(reduction, 0.0)
		set_process(true)

	func reset() -> void:
		input_db = -160.0
		output_db = -160.0
		reduction_db = 0.0
		input_hold = -160.0
		output_hold = -160.0
		reduction_hold = 0.0
		_input_target = -160.0
		_output_target = -160.0
		_reduction_target = 0.0
		queue_redraw()

	func _process(delta: float) -> void:
		var attack := 1.0 - exp(-delta / ATTACK_SECONDS)
		var fall := FALL_DB_PER_SECOND * delta
		input_db = _ease(input_db, _input_target, attack, fall)
		output_db = _ease(output_db, _output_target, attack, fall)
		reduction_db = _ease(reduction_db, _reduction_target, attack, fall)
		var hold_fall := HOLD_FALL_DB_PER_SECOND * delta
		input_hold = maxf(input_hold - hold_fall, input_db)
		output_hold = maxf(output_hold - hold_fall, output_db)
		reduction_hold = maxf(reduction_hold - hold_fall, reduction_db)
		queue_redraw()
		var settled := absf(input_db - _input_target) < 0.05 and absf(output_db - _output_target) < 0.05 \
				and absf(reduction_db - _reduction_target) < 0.05 and input_hold <= input_db + 0.05 \
				and output_hold <= output_db + 0.05 and reduction_hold <= reduction_db + 0.05
		if settled:
			set_process(false)

	func _ease(current: float, target: float, attack: float, fall: float) -> float:
		if target > current:
			return current + (target - current) * attack
		return maxf(current - fall, target)

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var bar := Rect2(0, 0, BAR_WIDTH, size.y)
		MeterDraw.draw_level(self, bar, input_db, LEVEL_MIN_DB, LEVEL_MAX_DB, input_hold)
		bar.position.x += BAR_WIDTH + GAP
		MeterDraw.draw_level(self, bar, output_db, LEVEL_MIN_DB, LEVEL_MAX_DB, output_hold)
		bar.position.x += BAR_WIDTH + GAP
		MeterDraw.draw_reduction(self, bar, reduction_db, GR_MAX_DB)
		var hold_y := bar.position.y + bar.size.y * clampf(reduction_hold / GR_MAX_DB, 0.0, 1.0)
		draw_line(
			Vector2(bar.position.x, hold_y),
			Vector2(bar.end.x, hold_y),
			MeterDraw.COLOR_HOLD,
			1.0
		)
		draw_string(font, Vector2(0, size.y - 2.0), "in", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.4))
		draw_string(font, Vector2(BAR_WIDTH + GAP, size.y - 2.0), "out", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.4))
		draw_string(font, Vector2((BAR_WIDTH + GAP) * 2.0, size.y - 2.0), "GR", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.4))


func _ready() -> void:
	_build()


func _get_minimum_size() -> Vector2:
	return Vector2(520, 300)


func _build() -> void:
	if curve != null:
		return
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	var top := HBoxContainer.new()
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.add_theme_constant_override("separation", 6)
	root.add_child(top)

	var graphs := VBoxContainer.new()
	graphs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graphs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graphs.add_theme_constant_override("separation", 3)
	top.add_child(graphs)
	curve = CompressorCurve.new()
	curve.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graphs.add_child(curve)
	history = CompressorHistory.new()
	history.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graphs.add_child(history)

	meters = Meters.new()
	meters.custom_minimum_size.x = METER_WIDTH
	top.add_child(meters)

	root.add_child(_build_main_row())
	root.add_child(_build_detector())


func _build_main_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var knobs := HBoxContainer.new()
	knobs.add_theme_constant_override("separation", 2)
	knobs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(knobs)
	_threshold_knob = _add_knob(knobs, "Thresh", CompressorData.P_THRESHOLD, "%.1f", " dB")
	_ratio_knob = _add_knob(knobs, "Ratio", CompressorData.P_RATIO, "", "")
	_attack_knob = _add_knob(knobs, "Attack", CompressorData.P_ATTACK, "%.2f", " ms")
	_release_knob = _add_knob(knobs, "Release", CompressorData.P_RELEASE, "%.0f", " ms")
	_knee_knob = _add_knob(knobs, "Knee", CompressorData.P_KNEE, "%.1f", " dB")
	_makeup_knob = _add_knob(knobs, "Makeup", CompressorData.P_MAKEUP, "%+.1f", " dB")
	_mix_knob = _add_knob(knobs, "Mix", CompressorData.P_MIX, "%.0f", " %")

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	row.add_child(column)
	column.add_child(_build_style_control())
	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 6)
	column.add_child(toggles)
	_auto_release = _add_toggle(toggles, "Auto Rel", CompressorData.P_AUTO_RELEASE)
	_auto_gain = _add_toggle(toggles, "Auto Gain", CompressorData.P_AUTO_GAIN)
	return row


func _build_style_control() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var caption := Label.new()
	caption.text = "Style"
	caption.add_theme_font_size_override("font_size", 10)
	caption.modulate = Color(1, 1, 1, 0.6)
	box.add_child(caption)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	box.add_child(row)
	var group := ButtonGroup.new()
	for i in CompressorData.STYLE_NAMES.size():
		var button := Button.new()
		button.text = CompressorData.STYLE_NAMES[i]
		button.toggle_mode = true
		button.button_group = group
		button.add_theme_font_size_override("font_size", 10)
		button.pressed.connect(_on_style_pressed.bind(i))
		row.add_child(button)
		_style_buttons.append(button)
	return box


func _build_detector() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	_detector_button = Button.new()
	_detector_button.text = "Detector ▸"
	_detector_button.toggle_mode = true
	_detector_button.add_theme_font_size_override("font_size", 10)
	_detector_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_detector_button.toggled.connect(_on_detector_toggled)
	box.add_child(_detector_button)

	_detector_pane = HBoxContainer.new()
	_detector_pane.add_theme_constant_override("separation", 6)
	_detector_pane.visible = false
	box.add_child(_detector_pane)
	_detection_option = _add_option(_detector_pane, "Detection", CompressorData.DETECTION_NAMES, CompressorData.P_DETECTION)
	_channels_option = _add_option(_detector_pane, "Channels", CompressorData.CHANNELS_NAMES, CompressorData.P_CHANNELS)
	_link_knob = _add_knob(_detector_pane, "Link", CompressorData.P_STEREO_LINK, "%.0f", " %")
	_sc_cut_knob = _add_knob(_detector_pane, "SC Cut", CompressorData.P_SC_LOW_CUT, "%.0f", " Hz")
	_range_knob = _add_knob(_detector_pane, "Range", CompressorData.P_RANGE, "%.0f", " dB")
	_sc_listen = _add_toggle(_detector_pane, "SC Listen", CompressorData.P_SC_LISTEN)
	return box


func _add_knob(parent: Control, text: String, param_id: int, format: String, unit: String) -> LabeledKnob:
	var knob := LabeledKnob.new()
	knob.text = text
	knob.knob_size = KNOB_SIZE
	knob.label_width = KNOB_LABEL_WIDTH
	knob.knob.value_changed.connect(_on_knob_changed.bind(param_id))
	parent.add_child(knob)
	knob.set_meta("param_id", param_id)
	knob.set_meta("format", format)
	knob.set_meta("unit", unit)
	return knob


func _add_toggle(parent: Control, text: String, param_id: int) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	check.add_theme_font_size_override("font_size", 10)
	check.toggled.connect(_on_toggle_toggled.bind(param_id))
	parent.add_child(check)
	check.set_meta("param_id", param_id)
	return check


func _add_option(parent: Control, caption: String, names: Array[String], param_id: int) -> OptionButton:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var label := Label.new()
	label.text = caption
	label.add_theme_font_size_override("font_size", 10)
	label.modulate = Color(1, 1, 1, 0.6)
	box.add_child(label)
	var option := OptionButton.new()
	for name in names:
		option.add_item(name)
	option.item_selected.connect(_on_option_selected.bind(param_id))
	option.set_meta("param_id", param_id)
	box.add_child(option)
	parent.add_child(box)
	return option


# ============================================================================
# BINDING
# ============================================================================

func _on_bind() -> void:
	_build()
	curve.device = device
	history.device = device
	var audio_config := _autoload("AudioConfig")
	if audio_config != null and audio_config.config.has("sample_rate"):
		_sample_rate = float(audio_config.config["sample_rate"])
		history.set_sample_rate(_sample_rate)
	_configure_controls()
	_refresh()


func _on_unbind() -> void:
	if curve != null:
		curve.device = null
	if history != null:
		history.device = null


func _on_device_parameter_changed(_param_id: int, _value: float) -> void:
	_refresh()


## Point each control at its parameter's range and curve (real units; the device converts).
func _configure_controls() -> void:
	for knob in [
		_threshold_knob, _ratio_knob, _attack_knob, _release_knob, _knee_knob,
		_makeup_knob, _mix_knob, _range_knob, _link_knob, _sc_cut_knob,
	]:
		if knob == null:
			continue
		_configure_knob(knob, int(knob.get_meta("param_id")), str(knob.get_meta("format")), str(knob.get_meta("unit")))


func _configure_knob(knob: LabeledKnob, param_id: int, format: String, unit: String) -> void:
	var param := device.get_parameter(param_id)
	if param == null:
		return
	knob.knob.min_value = param.min_value
	knob.knob.max_value = param.max_value
	knob.knob.logarithmic = param.is_logarithmic
	knob.knob.value_default = param.default_value
	if param_id == CompressorData.P_RATIO:
		knob.knob.value_text_callback = func(value: float) -> String:
			return CompressorData.format_ratio(value)
	elif param_id == CompressorData.P_SC_LOW_CUT:
		knob.knob.value_text_callback = func(value: float) -> String:
			return "Off" if value <= 0.5 else "%.0f Hz" % value
	else:
		knob.knob.value_format = format
		knob.knob.unit = unit.strip_edges()


func _refresh() -> void:
	if device == null:
		return
	for knob in [
		_threshold_knob, _ratio_knob, _attack_knob, _release_knob, _knee_knob,
		_makeup_knob, _mix_knob, _range_knob, _link_knob, _sc_cut_knob,
	]:
		if knob == null:
			continue
		var param_id := int(knob.get_meta("param_id"))
		knob.knob.set_value_no_signal(device.get_parameter_real(param_id))
	var style := int(device.get_parameter_real(CompressorData.P_STYLE))
	for i in _style_buttons.size():
		_style_buttons[i].set_pressed_no_signal(i == style)
	_auto_release.set_pressed_no_signal(device.get_parameter_real(CompressorData.P_AUTO_RELEASE) >= 0.5)
	_auto_gain.set_pressed_no_signal(device.get_parameter_real(CompressorData.P_AUTO_GAIN) >= 0.5)
	_sc_listen.set_pressed_no_signal(device.get_parameter_real(CompressorData.P_SC_LISTEN) >= 0.5)
	_detection_option.select(int(device.get_parameter_real(CompressorData.P_DETECTION)))
	_channels_option.select(int(device.get_parameter_real(CompressorData.P_CHANNELS)))
	if curve != null:
		curve.refresh()
	if history != null:
		history.refresh()


func _on_knob_changed(value: float, param_id: int) -> void:
	if device != null:
		device.set_parameter_real(param_id, value)


func _on_toggle_toggled(pressed: bool, param_id: int) -> void:
	if device != null:
		device.set_parameter_real(param_id, 1.0 if pressed else 0.0)


func _on_option_selected(index: int, param_id: int) -> void:
	if device != null:
		device.set_parameter_real(param_id, float(index))


func _on_style_pressed(index: int) -> void:
	if device != null:
		device.set_parameter_real(CompressorData.P_STYLE, float(index))


func _on_detector_toggled(pressed: bool) -> void:
	_detector_pane.visible = pressed
	_detector_button.text = "Detector ▾" if pressed else "Detector ▸"


# ============================================================================
# DATA STREAM
# ============================================================================

func _on_view_shown() -> void:
	_shown = true
	_sync_subscription()


func _on_view_hidden() -> void:
	_shown = false
	_sync_subscription()
	if curve != null:
		curve.dragging = false
	if history != null:
		history.clear()


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
		if not _logged_first_blob:
			logger.debug("dynamics blob for other path '%s' (want '%s')" % [osc_path, device.osc_path() if device else "null"])
		return
	if not _logged_first_blob:
		_logged_first_blob = true
		logger.debug("first dynamics blob: %d bytes, meters=%s, visible=%s, meters.size=%s" % [
			blob.size(), meters != null, is_visible_in_tree(), meters.size if meters != null else "n/a"])
	_apply_dynamics(CompressorData.decode(blob))


## Feed a decoded blob to the history and the meters.
func _apply_dynamics(decoded: Dictionary) -> void:
	var count := int(decoded.get("count", 0))
	if count <= 0:
		return
	if history != null:
		history.push_records(decoded)
	var input_peak := -160.0
	var output_peak := -160.0
	var reduction := 0.0
	for i in count:
		input_peak = maxf(input_peak, decoded["in_peak_db"][i])
		output_peak = maxf(output_peak, decoded["out_peak_db"][i])
		reduction = maxf(reduction, decoded["gr_db"][i])
	if curve != null:
		curve.push_live_level(input_peak)
	if meters != null:
		meters.push(input_peak, output_peak, reduction, 0.0)


func _autoload(autoload_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(autoload_name) if tree != null else null
