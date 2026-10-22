## Panel view of the built-in Reverb (spec 050): the decay map and a live envelope strip in the
## middle, every parameter and both slots around them in signal-path order (Input, Space, the
## Decay EQ / Modulation / Tank FX row under the map, Tone, Wet FX, Output).
##
## The layout lives in `ReverbDefaultView.tscn`. Each parameter control carries its parameter
## name as `metadata/param` and each slot tile its slot key as `metadata/slot`; `_build` only
## collects and wires them. The view talks to the device through `DeviceInstance` only, and
## subscribes to the device's `"envelope"` stream while it is shown. No autoload is referenced by
## name (looked up through the scene tree), so tests can drive it headless.
class_name ReverbDefaultView extends DeviceView

## Caption font size of the knobs (the caption label is built by LabeledKnob, not the scene). A
## caption too wide for its knob is trimmed, and LabeledKnob shows the full name on hover.
const KNOB_FONT_SIZE := 12

static var logger := Log.make("ReverbView")

## How the view finds the AudioEngineOSC autoload. Default: the scene tree (tests inject a fake).
var load_osc := Callable(self, "_autoload")

@onready var decay_map: ReverbDecayMap = %DecayMap
@onready var strip: ReverbEnvelopeStrip = %EnvelopeStrip
@onready var algorithm_control: SegmentedControl = %AlgorithmControl
@onready var freeze_check: CheckBox = %Freeze
@onready var tank_tile: DeviceSlotButton = %TankFxTile
@onready var wet_tile: DeviceSlotButton = %WetFxTile
@onready var _main_page: VBoxContainer = %MainPage

## The scene's knobs, keyed by parameter name.
var _knobs: Dictionary[String, LabeledKnob] = {}
## Slot tiles keyed by slot key.
var _tiles: Dictionary[String, DeviceSlotButton] = {}
var _built := false
var _subscribed := false
var _shown := false
## The Tank FX chain and devices whose changes update the "≈ Tank FX" mark.
var _watched_chain: DeviceInstance = null
var _watched_devices: Array[DeviceInstance] = []


func _ready() -> void:
	_build()
	if device != null:
		_setup()


## Wire every control tagged with `metadata/param` / `metadata/slot`, once. Nothing here needs the
## device.
func _build() -> void:
	if _built:
		return
	_built = true
	for node in _main_page.find_children("*", "", true, false):
		if node.has_meta("slot") and node is DeviceSlotButton:
			_tiles[String(node.get_meta("slot"))] = node
			continue
		if not node.has_meta("param"):
			continue
		var param_name := String(node.get_meta("param"))
		if node is LabeledKnob:
			var knob := node as LabeledKnob
			knob.label.add_theme_font_size_override("font_size", KNOB_FONT_SIZE)
			knob.knob.value_changed.connect(_on_knob_changed.bind(param_name))
			knob.knob.reset_requested.connect(_on_knob_reset.bind(param_name))
			_knobs[param_name] = knob
		elif node is SegmentedControl:
			node.selected_changed.connect(_on_segment_selected.bind(param_name))
		elif node is CheckBox:
			node.toggled.connect(_on_check_toggled.bind(param_name))
	decay_map.span_changed.connect(_on_span_changed)


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
	for key in _tiles:
		_tiles[key].bind_to_slot(device, key)
	decay_map.bind_device(device)
	strip.span = decay_map.span
	_watch_tank_fx()
	_refresh()
	_sync_subscription()


func _on_unbind() -> void:
	_shown = false
	_sync_subscription()
	_unwatch_tank_fx()
	if is_node_ready():
		decay_map.bind_device(null)
		strip.clear()
		for key in _tiles:
			_tiles[key].bind_to_slot(null, key)


func _configure_knobs() -> void:
	for knob_name in _knobs:
		var id := device.get_parameter_id_by_name(knob_name)
		var param := device.get_parameter(id)
		if param == null:
			continue
		var knob: RotaryKnob = _knobs[knob_name].knob
		knob.min_value = param.min_value
		knob.max_value = param.max_value
		knob.logarithmic = param.is_logarithmic
		knob.value_default = param.default_value
		knob.value_text_callback = _knob_text.bind(id)


func _knob_text(value: float, id: int) -> String:
	return ReverbData.format_value(id, value)


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
	algorithm_control.set_selected_no_signal(int(device.get_parameter_real(ReverbData.P_ALGORITHM)))
	freeze_check.set_pressed_no_signal(device.get_parameter_real(ReverbData.P_FREEZE) >= 0.5)
	decay_map.set_values(ReverbData.values_from_device(device))


func _on_span_changed(span: float) -> void:
	strip.span = span


# ============================================================================
# TANK FX
# ============================================================================

## The map is approximate while Tank FX holds an enabled device. Watch the slot chain and each of
## its devices so adding, removing, moving and bypassing all update the mark.
func _watch_tank_fx() -> void:
	_unwatch_tank_fx()
	if device == null:
		return
	if not device.slots_changed.is_connected(_update_tank_fx):
		device.slots_changed.connect(_update_tank_fx)
	_watched_chain = device.slot_chain(ReverbData.SLOT_TANK_FX)
	if _watched_chain != null and _watched_chain != device:
		for sig in [_watched_chain.child_added, _watched_chain.child_removed, _watched_chain.child_moved]:
			if not sig.is_connected(_on_tank_children_changed):
				sig.connect(_on_tank_children_changed)
	_watch_tank_devices()
	_update_tank_fx()


func _unwatch_tank_fx() -> void:
	if device != null and device.slots_changed.is_connected(_update_tank_fx):
		device.slots_changed.disconnect(_update_tank_fx)
	if is_instance_valid(_watched_chain):
		for sig in [_watched_chain.child_added, _watched_chain.child_removed, _watched_chain.child_moved]:
			if sig.is_connected(_on_tank_children_changed):
				sig.disconnect(_on_tank_children_changed)
	_watched_chain = null
	_unwatch_tank_devices()


func _watch_tank_devices() -> void:
	_unwatch_tank_devices()
	if device == null:
		return
	for inst in device.slot_devices(ReverbData.SLOT_TANK_FX):
		if not inst.enabled_changed.is_connected(_on_tank_device_enabled):
			inst.enabled_changed.connect(_on_tank_device_enabled)
		_watched_devices.append(inst)


func _unwatch_tank_devices() -> void:
	for inst in _watched_devices:
		if is_instance_valid(inst) and inst.enabled_changed.is_connected(_on_tank_device_enabled):
			inst.enabled_changed.disconnect(_on_tank_device_enabled)
	_watched_devices.clear()


func _on_tank_children_changed(_a = null, _b = null) -> void:
	_watch_tank_devices()
	_update_tank_fx()


func _on_tank_device_enabled(_enabled: bool) -> void:
	_update_tank_fx()


func _update_tank_fx() -> void:
	if not is_node_ready() or device == null:
		return
	var live := false
	for inst in device.slot_devices(ReverbData.SLOT_TANK_FX):
		if inst.enabled:
			live = true
			break
	decay_map.set_approximate(live)


# ============================================================================
# EDITS
# ============================================================================

func _param_id(param_name: String) -> int:
	return device.get_parameter_id_by_name(param_name)


func _on_knob_changed(value: float, param_name: String) -> void:
	if device != null:
		ParameterActions.set_real(device, _param_id(param_name), value)


func _on_knob_reset(param_name: String) -> void:
	if device != null:
		ParameterActions.reset(device, _param_id(param_name))


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
	if is_node_ready():
		strip.clear()
		strip.begin()
	_sync_subscription()


func _on_view_hidden() -> void:
	_shown = false
	_sync_subscription()
	if is_node_ready():
		strip.clear()


func _sync_subscription() -> void:
	var want := _shown and device != null
	if want == _subscribed:
		return
	var osc = load_osc.call("AudioEngineOSC")
	if osc == null:
		return
	logger.debug("%s envelope path=%s" % ["subscribe" if want else "unsubscribe", device.osc_path()])
	if want:
		osc.subscribe_device_data(device.osc_path(), "envelope")
		if not osc.device_data_received.is_connected(_on_envelope_received):
			osc.device_data_received.connect(_on_envelope_received)
	else:
		osc.unsubscribe_device_data(device.osc_path(), "envelope")
		if osc.device_data_received.is_connected(_on_envelope_received):
			osc.device_data_received.disconnect(_on_envelope_received)
	_subscribed = want


func _on_envelope_received(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type != "envelope" or device == null or osc_path != device.osc_path():
		return
	if not is_node_ready():
		return
	var decoded := ReverbData.decode_envelope(blob)
	if bool(decoded["valid"]):
		strip.push_records(decoded["in_db"], decoded["wet_db"], decoded["record_seconds"])


func _autoload(autoload_name: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(autoload_name) if tree != null else null
