## Panel view of the built-in Saturator: one page, no tabs, all 17 parameters on it.
##
## Top row: the Type and Quality selectors and Auto Gain. Middle row: Drive, Bias, Dynamics and
## Input knobs, the transfer curve with its harmonic bars, then Mix and Output faders. Bottom
## row: the tone group (Low Cut, High Cut, Tone) and the tape group (HF Loss, Head Bump, Squash,
## Wow, Noise), dimmed unless Type is Tape — the engine gates those stages behind the Tape type.
##
## The controls are built in `_build` (the scene is just the root) and bound through
## `DeviceInstance` only. The view subscribes to the device's `"curve"` stream while it is shown
## and unsubscribes when hidden. No autoload is referenced by name (looked up through the scene
## tree), so tests can drive it headless.
class_name SaturatorDefaultView extends DeviceView

const DIMMED_ALPHA := 0.4
## Fader and knob geometry.
const KNOB_SIZE := Vector2(30, 30)

static var logger := Log.make("SaturatorView")

## View-local state is not needed beyond what the device exposes (the tape group's dimming
## follows the Type parameter), so there is no SaturatorViewState.

var curve := SaturatorCurve.new()

## How the view finds the AudioEngineOSC autoload. Default: the scene tree (tests inject a fake).
var load_osc := Callable(self, "_autoload")

## [caption] per knob, keyed by parameter name.
const KNOBS_DRIVE_ROW := [["Drive", "Drive"], ["Bias", "Bias"], ["Dynamics", "Dyn"], ["Input", "In"]]
const KNOBS_TONE := [["Low Cut", "Low Cut"], ["High Cut", "High Cut"], ["Tone", "Tone"]]
const KNOBS_TAPE := [["HF Loss", "HF Loss"], ["Head Bump", "Bump"], ["Squash", "Squash"], ["Wow", "Wow"], ["Noise", "Noise"]]

var type_control: SegmentedControl
var quality_control: SegmentedControl
var auto_gain: CheckBox
var mix_fader: Fader
var mix_value: Label
var output_fader: Fader
var output_value: Label
## The tape group's container, dimmed unless Type is Tape.
var tape_row: Control

var _knobs: Dictionary[String, LabeledKnob] = {}
var _main_page: VBoxContainer
var _built := false
var _subscribed := false
var _shown := false
var _logged_first_blob := false


func _ready() -> void:
	_build()
	if device != null:
		_setup()


## The scene is just the root; everything is built in code so the layout is testable headless.
func _build() -> void:
	if _built:
		return
	_built = true
	_main_page = VBoxContainer.new()
	_main_page.name = "MainPage"
	_main_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_main_page.add_theme_constant_override("separation", 4)
	add_child(_main_page)

	# Row 0: Type, Quality, Auto Gain.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	type_control = _segment("Type", SaturatorData.TYPE_NAMES)
	quality_control = _segment("Quality", SaturatorData.QUALITY_NAMES)
	auto_gain = CheckBox.new()
	auto_gain.text = "Auto Gain"
	auto_gain.add_theme_font_size_override("font_size", 10)
	auto_gain.toggled.connect(_on_check_toggled.bind("Auto Gain"))
	top.add_child(type_control)
	top.add_child(quality_control)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	top.add_child(auto_gain)
	_main_page.add_child(top)

	# Row 1: Drive/Bias/Dynamics/Input knobs, the curve, Mix and Output faders.
	var middle := HBoxContainer.new()
	middle.add_theme_constant_override("separation", 10)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_child(_knob_row(KNOBS_DRIVE_ROW))
	curve.custom_minimum_size = Vector2(240, 130)
	curve.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	curve.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_child(curve)
	middle.add_child(_fader_pair())
	_main_page.add_child(middle)

	# Row 2: tone group and tape group.
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	bottom.add_child(_group("Tone", [_knob_row(KNOBS_TONE)]))
	tape_row = _group("Tape", [_knob_row(KNOBS_TAPE)])
	bottom.add_child(tape_row)
	_main_page.add_child(bottom)


func _knob_row(entries: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for entry in entries:
		var knob := LabeledKnob.new()
		knob.text = entry[1]
		knob.label_width = 44.0
		knob.knob_size = KNOB_SIZE
		knob.label.add_theme_font_size_override("font_size", 10)
		knob.knob.value_changed.connect(_on_knob_changed.bind(entry[0]))
		knob.knob.reset_requested.connect(_on_knob_reset.bind(entry[0]))
		row.add_child(knob)
		_knobs[entry[0]] = knob
	return row


func _segment(param_name: String, labels: Array) -> SegmentedControl:
	var segment := SegmentedControl.new()
	segment.set_items(PackedStringArray(labels))
	segment.font_size = 10
	segment.selected_changed.connect(_on_segment_selected.bind(param_name))
	return segment


## A caption + fader + value column; the value label is returned for the view to fill.
func _fader_column(caption: String, param_name: String) -> Array:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	var caption_label := Label.new()
	caption_label.text = caption
	caption_label.modulate = Color(1, 1, 1, 0.6)
	caption_label.add_theme_font_size_override("font_size", 10)
	caption_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(caption_label)
	var fader := Fader.new()
	fader.custom_minimum_size = Vector2(36, 70)
	fader.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fader.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	fader.value_changed.connect(_on_fader_changed.bind(param_name))
	fader.reset_requested.connect(_on_knob_reset.bind(param_name))
	column.add_child(fader)
	var value_label := Label.new()
	value_label.modulate = Color(1, 1, 1, 0.6)
	value_label.add_theme_font_size_override("font_size", 10)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(value_label)
	return [column, fader, value_label]


func _fader_pair() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var mix := _fader_column("MIX", "Mix")
	var out := _fader_column("OUT", "Output")
	row.add_child(mix[0])
	row.add_child(out[0])
	mix_fader = mix[1]
	mix_value = mix[2]
	output_fader = out[1]
	output_value = out[2]
	return row


func _group(title: String, children: Array) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color(0.62, 0.62, 0.68))
	header.add_child(label)
	box.add_child(header)
	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	for child in children:
		inner.add_child(child)
	box.add_child(inner)
	return box


# ============================================================================
# BINDING
# ============================================================================

func _on_bind() -> void:
	if is_node_ready():
		_setup()


func _setup() -> void:
	_configure_knobs()
	for knob_name in _knobs:
		ModAssign.attach(_knobs[knob_name].knob, device, device.get_parameter_id_by_name(knob_name))
	_configure_fader(mix_fader, "Mix", "%d %%")
	_configure_fader(output_fader, "Output", "%+.1f dB")
	ModAssign.attach(mix_fader, device, device.get_parameter_id_by_name("Mix"))
	ModAssign.attach(output_fader, device, device.get_parameter_id_by_name("Output"))
	# A first curve from the static soft shaper, so the panel is never blank before the first
	# `"curve"` record arrives.
	if not curve.has_record():
		_fallback_curve()
	_refresh()


func _on_unbind() -> void:
	curve.clear()


func _configure_knobs() -> void:
	for knob_name in _knobs:
		var param := device.get_parameter(device.get_parameter_id_by_name(knob_name))
		if param == null:
			continue
		var knob: RotaryKnob = _knobs[knob_name].knob
		knob.min_value = param.min_value
		knob.max_value = param.max_value
		knob.logarithmic = param.is_logarithmic
		knob.value_default = param.default_value
		knob.value_text_callback = _knob_text.bind(knob_name)


func _configure_fader(fader: Fader, param_name: String, format: String) -> void:
	var param := device.get_parameter(device.get_parameter_id_by_name(param_name))
	if param == null:
		return
	fader.min_value = param.min_value
	fader.max_value = param.max_value
	fader.value_default = param.default_value
	fader.value_text_callback = func(value: float) -> String: return format % value


func _knob_text(value: float, param_name: String) -> String:
	match param_name:
		"Drive":
			return "%.1f dB" % value
		"Bias":
			return "%+.2f" % value
		"Dynamics", "HF Loss", "Squash", "Wow":
			return "%d %%" % roundi(value)
		"Input", "Output":
			return "%+.1f dB" % value
		"Low Cut":
			return "Off" if value <= 0.5 else "%.0f Hz" % value
		"High Cut":
			return "Off" if value >= 19999.5 else "%.1f kHz" % (value / 1000.0)
		"Tone", "Head Bump":
			return "%+.1f dB" % value
		"Noise":
			return "Off" if value <= -89.5 else "%.0f dB" % value
	return "%.2f" % value


func _on_device_parameter_changed(_param_id: int, _value: float) -> void:
	if is_node_ready():
		_refresh()


func _refresh() -> void:
	if device == null or not is_node_ready():
		return
	for knob_name in _knobs:
		var id := device.get_parameter_id_by_name(knob_name)
		if id >= 0:
			_knobs[knob_name].knob.set_value_no_signal(device.get_parameter_real(id))
	type_control.set_selected_no_signal(int(device.get_parameter_real(SaturatorData.P_TYPE)))
	quality_control.set_selected_no_signal(int(device.get_parameter_real(SaturatorData.P_QUALITY)))
	auto_gain.set_pressed_no_signal(device.get_parameter_real(SaturatorData.P_AUTO_GAIN) >= 0.5)
	mix_fader.set_value_no_signal(device.get_parameter_real_by_name("Mix"))
	output_fader.set_value_no_signal(device.get_parameter_real_by_name("Output"))
	mix_value.text = "%d %%" % roundi(device.get_parameter_real_by_name("Mix"))
	output_value.text = "%+.1f dB" % device.get_parameter_real_by_name("Output")
	_update_tape_dim()


## The tape stages are gated behind the Tape type: dim the group otherwise.
func _update_tape_dim() -> void:
	var is_tape := int(device.get_parameter_real(SaturatorData.P_TYPE)) == SaturatorData.TYPE_TAPE
	tape_row.modulate.a = 1.0 if is_tape else DIMMED_ALPHA


# ============================================================================
# EDITS
# ============================================================================

func _param_id(param_name: String) -> int:
	return device.get_parameter_id_by_name(param_name)


func _on_knob_changed(value: float, param_name: String) -> void:
	if device != null:
		ParameterActions.set_real(device, _param_id(param_name), value)


func _on_knob_reset(param_name: String) -> void:
	if device == null:
		return
	var param := device.get_parameter(_param_id(param_name))
	if param != null:
		ParameterActions.set_real(device, _param_id(param_name), param.default_value)


func _on_fader_changed(value: float, param_name: String) -> void:
	_on_knob_changed(value, param_name)


func _on_check_toggled(pressed: bool, param_name: String) -> void:
	if device != null:
		ParameterActions.set_real(device, _param_id(param_name), 1.0 if pressed else 0.0)


func _on_segment_selected(index: int, param_name: String) -> void:
	if device != null:
		ParameterActions.set_real(device, _param_id(param_name), float(index))


# ============================================================================
# DATA STREAM
# ============================================================================

func _on_view_shown() -> void:
	_shown = true
	_sync_subscription()
	if is_node_ready() and not curve.has_record():
		_fallback_curve()


func _on_view_hidden() -> void:
	_shown = false
	_sync_subscription()
	if not is_node_ready():
		return
	curve.clear()


func _sync_subscription() -> void:
	var want := _shown and device != null
	if want == _subscribed:
		return
	var osc = load_osc.call("AudioEngineOSC")
	if osc == null:
		return
	logger.debug("%s curve path=%s" % ["subscribe" if want else "unsubscribe", device.osc_path()])
	if want:
		_logged_first_blob = false
		osc.subscribe_device_data(device.osc_path(), "curve")
		if not osc.device_data_received.is_connected(_on_curve_received):
			osc.device_data_received.connect(_on_curve_received)
	else:
		osc.unsubscribe_device_data(device.osc_path(), "curve")
		if osc.device_data_received.is_connected(_on_curve_received):
			osc.device_data_received.disconnect(_on_curve_received)
	_subscribed = want


func _on_curve_received(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type != "curve":
		return
	if device == null or osc_path != device.osc_path():
		return
	if not _logged_first_blob:
		_logged_first_blob = true
		logger.debug("first curve blob: %d bytes, visible=%s" % [blob.size(), is_visible_in_tree()])
	_apply_curve(SaturatorData.decode(blob))


func _apply_curve(decoded: Dictionary) -> void:
	if not bool(decoded.get("valid", false)):
		return
	curve.set_record(decoded)


## The static soft curve at the current Drive, before the engine streams a real record.
func _fallback_curve() -> void:
	var drive_db := device.get_parameter_real(SaturatorData.P_DRIVE) if device != null else 6.0
	var curve_points := PackedFloat32Array()
	curve_points.resize(SaturatorData.CURVE_POINTS)
	for i in SaturatorData.CURVE_POINTS:
		curve_points[i] = SaturatorData.soft_curve_at(SaturatorData.curve_input(i), drive_db)
	curve.set_record(SaturatorData.decode(SaturatorData.build_record(drive_db, NAN, curve_points, PackedFloat32Array())))


func _autoload(autoload_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(autoload_name) if tree != null else null
