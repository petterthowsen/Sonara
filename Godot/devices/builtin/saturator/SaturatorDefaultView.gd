## Panel view of the built-in Saturator: one page, no tabs, all 19 parameters on it.
##
## Top row: the Type and Quality selectors and Auto Gain. Middle row: Drive, Bias, Dynamics and
## Input knobs, the transfer curve with its harmonic bars, then Mix and Output faders. Bottom
## row: the tone group (Low Cut, High Cut, Tone) and the tape group (HF Loss, Head Bump, Squash,
## Wow, Flutter, Drift, Noise), dimmed unless Type is Tape — the engine gates those stages behind
## the Tape type.
##
## The layout lives in `SaturatorDefaultView.tscn`. Each parameter control carries its parameter
## name as `metadata/param`; `_build` collects and wires them. The view talks to the device
## through `DeviceInstance` only, subscribes to the device's `"curve"` stream while it is shown
## and unsubscribes when hidden. No autoload is referenced by name (looked up through the scene
## tree), so tests can drive it headless.
class_name SaturatorDefaultView extends DeviceView

const DIMMED_ALPHA := 0.4
## Caption font size of the knobs (the caption label is built by LabeledKnob, not the scene).
const KNOB_FONT_SIZE := 10

static var logger := Log.make("SaturatorView")

## View-local state is not needed beyond what the device exposes (the tape group's dimming
## follows the Type parameter), so there is no SaturatorViewState.

## How the view finds the AudioEngineOSC autoload. Default: the scene tree (tests inject a fake).
var load_osc := Callable(self, "_autoload")

@onready var curve: SaturatorCurve = %Curve
@onready var type_control: SegmentedControl = %TypeControl
@onready var quality_control: SegmentedControl = %QualityControl
@onready var auto_gain: CheckBox = %AutoGain
@onready var mix_fader: Fader = %MixFader
@onready var mix_value: Label = %MixValue
@onready var output_fader: Fader = %OutputFader
@onready var output_value: Label = %OutputValue
## The tape group's container, dimmed unless Type is Tape.
@onready var tape_row: Control = %TapeGroup
@onready var _main_page: VBoxContainer = %MainPage

## The scene's knobs, keyed by parameter name.
var _knobs: Dictionary[String, LabeledKnob] = {}
var _built := false
var _subscribed := false
var _shown := false
var _logged_first_blob := false


func _ready() -> void:
	_build()
	if device != null:
		_setup()


## Wire every control tagged with `metadata/param` to its parameter, once. Nothing here needs
## the device.
func _build() -> void:
	if _built:
		return
	_built = true
	for node in _main_page.find_children("*", "", true, false):
		if not node.has_meta("param"):
			continue
		var param_name := String(node.get_meta("param"))
		if node is LabeledKnob:
			var knob := node as LabeledKnob
			knob.label.add_theme_font_size_override("font_size", KNOB_FONT_SIZE)
			knob.knob.value_changed.connect(_on_knob_changed.bind(param_name))
			knob.knob.reset_requested.connect(_on_knob_reset.bind(param_name))
			_knobs[param_name] = knob
		elif node is Fader:
			node.value_changed.connect(_on_fader_changed.bind(param_name))
			node.reset_requested.connect(_on_knob_reset.bind(param_name))
		elif node is SegmentedControl:
			node.selected_changed.connect(_on_segment_selected.bind(param_name))
		elif node is CheckBox:
			node.toggled.connect(_on_check_toggled.bind(param_name))



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
	if is_node_ready():
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
		knob.skew = param.skew
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
			return "%+d %%" % roundi(value)
		"Dynamics", "HF Loss", "Squash", "Wow", "Flutter", "Drift":
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
			return "Off" if value <= -89.5 else "%.0f dBFS" % value
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
	if not is_node_ready() or not bool(decoded.get("valid", false)):
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
