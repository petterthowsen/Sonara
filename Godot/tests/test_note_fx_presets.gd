# test_note_fx_presets.gd
# Spec 027 (REQ-041, REQ-024 / T-029): the Step Sequencer's 70 parameters survive a device
# preset round trip (JSON serialize → parse → instantiate on a fresh channel), and the engine's
# /builtin/info payload marks every note-effect parameter automation-safe (Latch's momentary
# "Release All" excepted).
# Run: godot --headless --path Godot -s tests/test_note_fx_presets.gd -- --test
#
# Model classes reference autoloads, so they are loaded with load() instead of named.
extends TestBase

const SEQ_ID := "sonara.builtin.step_sequencer"
const LATCH_ID := "sonara.builtin.latch"

## SYNC_CHOICES (Engine/src/audio/dsp/tempo_sync.rs) from "1/1" onward, without "Off".
const RATE_CHOICES := [
	"1/1", "1/1.", "1/1T", "1/2", "1/2.", "1/2T", "1/4", "1/4.", "1/4T",
	"1/8", "1/8.", "1/8T", "1/16", "1/16.", "1/16T", "1/32", "1/32.", "1/32T",
]

var _device_script: GDScript
var _param_script: GDScript
var _inst_script: GDScript
var _preset_script: GDScript
var _project_script: GDScript


func suite_name() -> String:
	return "Note fx presets"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_inst_script = load("res://data/DeviceInstance.gd")
	_preset_script = load("res://data/DevicePreset.gd")
	_project_script = load("res://data/Project.gd")
	_test_step_sequencer_round_trip()
	_test_info_flags()
	# Only the shared AssetService registry entry is ours to remove.
	var registry: Object = root.get_node("AssetService").device_registry
	registry._devices.erase(SEQ_ID)


# ============================================================================
# 1) Step Sequencer preset round trip (REQ-024 / T-029)
# ============================================================================

func _seq_device() -> Object:
	var device: Object = _device_script.new(SEQ_ID, "Step Sequencer",
		_device_script.DeviceCategory.NoteEffect, _device_script.DeviceType.BuiltIn)
	device.add_parameter(_float(0, "Length", 1.0, 16.0, 4.0))
	device.add_parameter(_enum(1, "Mode", ["Chord", "Mono"]))
	device.add_parameter(_enum(2, "Velocity Source", ["Input × Step", "Step"]))
	device.add_parameter(_enum(10, "Rate", RATE_CHOICES))
	device.add_parameter(_float(11, "Gate", 10.0, 200.0, 100.0, "%"))
	device.add_parameter(_float(12, "Swing", 0.0, 75.0, 0.0, "%"))
	for k in range(1, 17):
		var base := 100 + 10 * (k - 1)
		device.add_parameter(_bool(base, "On", 1.0 if k == 1 else 0.0))
		device.add_parameter(_float(base + 1, "Pitch", -24.0, 24.0, 0.0))
		device.add_parameter(_float(base + 2, "Velocity", 0.0, 100.0, 100.0, "%"))
		device.add_parameter(_float(base + 3, "Chance", 0.0, 100.0, 100.0, "%"))
	return device


func _param(id: int, name: String, unit := "") -> Object:
	return _param_script.new(id, name, unit)


func _float(id: int, name: String, min_v: float, max_v: float, default_v: float, unit := "") -> Object:
	var p: Object = _param(id, name, unit)
	p.param_type = "float"
	p.min_value = min_v
	p.max_value = max_v
	p.default_value = default_v
	return p


func _bool(id: int, name: String, default_v: float) -> Object:
	var p: Object = _param(id, name)
	p.param_type = "bool"
	p.default_value = default_v
	return p


func _enum(id: int, name: String, values: Array) -> Object:
	var p: Object = _param(id, name)
	p.param_type = "enum"
	p.enum_values.assign(values)
	return p


func _step_param_ids() -> Array:
	var ids: Array = []
	for k in range(1, 17):
		var base := 100 + 10 * (k - 1)
		ids.append_array([base, base + 1, base + 2, base + 3])
	return ids


## Distinct, non-default normalized value per step parameter.
func _step_value(id: int) -> float:
	var k := float((id - 100) / 10 + 1)
	match id % 10:
		0:
			return 0.0 if k == 1.0 else 1.0  # flipped from the defaults
		1:
			return 0.05 + 0.02 * k
		2:
			return 0.02 + 0.01 * k
		_:
			return 0.03 + 0.013 * k


func _set_steps(inst: Object) -> void:
	for id in _step_param_ids():
		inst.parameter_values[id] = _step_value(id)


func _test_step_sequencer_round_trip() -> void:
	var device: Object = _seq_device()
	var registry: Object = root.get_node("AssetService").device_registry
	_assert(registry._devices.get(SEQ_ID) == null, "the Step Sequencer starts unregistered")
	registry._devices[SEQ_ID] = device
	var channel: Object = _project_script.new().create_instrument_track("Seq").channel
	var inst: Object = _inst_script.new(device, channel.id, -1)
	channel.add_device(inst, -1)
	_set_steps(inst)

	var preset: Object = _preset_script.capture_now(inst, "Steps")
	_assert(preset.device_id == SEQ_ID and preset.device_name == "Step Sequencer", "device id and name captured")
	var text := JSON.stringify(preset.to_json())
	var loaded: Object = _preset_script.from_json(JSON.parse_string(text))
	_assert(loaded != null and loaded.name == "Steps", "preset survives JSON")

	var fresh_channel: Object = _project_script.new().create_instrument_track("Seq 2").channel
	var copy: Object = loaded.instantiate(fresh_channel.id)
	_assert(copy != null, "instantiates on a fresh channel")
	if copy == null:
		return
	for id in _step_param_ids():
		var expected: float = _step_value(id)
		_assert(is_equal_approx(copy.parameter_values.get(id, -7.0), expected),
			"step parameter %d survives (got %s, want %s)" % [id, str(copy.parameter_values.get(id, -7.0)), str(expected)])
	# Sanity: the values really are non-default, so the loop above can't pass vacuously.
	_assert(is_equal_approx(inst.parameter_values[100], 0.0) and is_equal_approx(inst.parameter_values[110], 1.0),
		"the On flips are non-default")
	_assert(inst.parameter_values[101] != 0.5, "a Pitch value is non-default")


# ============================================================================
# 2) /builtin/info flags (REQ-041)
# ============================================================================

## One wire tuple: id, name, unit, type, syncable, min, max, default, is_log, skew, enum_count,
## enum values, module, automatable, modulatable.
func _param_wire(id: int, name: String, type: String, min_v: float, max_v: float, default_v: float,
		enums: Array = [], automatable := 1, modulatable := 1, unit := "", syncable := 1) -> Array:
	var args: Array = [id, name, unit, type, syncable, min_v, max_v, default_v, 0, 1.0, enums.size()]
	args.append_array(enums)
	args.append_array(["", automatable, modulatable])
	return args


func _seq_info() -> Array:
	var args: Array = [SEQ_ID, "Step Sequencer", "note_effect", "", 1, 0, 2, 0, "", 0]
	var params: Array = [
		_param_wire(0, "Length", "float", 1.0, 16.0, 4.0),
		_param_wire(1, "Mode", "enum", 0.0, 1.0, 0.0, ["Chord", "Mono"]),
		_param_wire(2, "Velocity Source", "enum", 0.0, 1.0, 0.0, ["Input × Step", "Step"]),
		_param_wire(10, "Rate", "enum", 0.0, 17.0, 15.0, RATE_CHOICES),
		_param_wire(11, "Gate", "float", 10.0, 200.0, 100.0, [], 1, 1, "%"),
		_param_wire(12, "Swing", "float", 0.0, 75.0, 0.0, [], 1, 1, "%"),
	]
	for k in range(1, 17):
		var base := 100 + 10 * (k - 1)
		params.append(_param_wire(base, "On %d" % k, "bool", 0.0, 1.0, 1.0 if k == 1 else 0.0))
		params.append(_param_wire(base + 1, "Pitch %d" % k, "float", -24.0, 24.0, 0.0))
		params.append(_param_wire(base + 2, "Velocity %d" % k, "float", 0.0, 100.0, 100.0, [], 1, 1, "%"))
		params.append(_param_wire(base + 3, "Chance %d" % k, "float", 0.0, 100.0, 100.0, [], 1, 1, "%"))
	args.append(params.size())
	for p in params:
		args.append_array(p)
	args.append_array([0, 0])  # is_container, modulator_count
	return args


func _latch_info() -> Array:
	var args: Array = [LATCH_ID, "Latch", "note_effect", "", 1, 0, 2, 0, "", 0, 2]
	args.append_array(_param_wire(0, "Mode", "enum", 0.0, 1.0, 0.0, ["Chord", "Toggle"]))
	args.append_array(_param_wire(1, "Release All", "bool", 0.0, 1.0, 0.0, [], 0, 0))  # momentary trigger
	args.append_array([0, 0])
	return args


func _test_info_flags() -> void:
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	registry._on_builtin_info_received(_seq_info())
	var device: Object = registry.get_device(SEQ_ID)
	_assert(device != null and device.name == "Step Sequencer"
		and device.category == _device_script.DeviceCategory.NoteEffect,
		"the Step Sequencer registers as a note effect")
	if device == null:
		return
	_assert(device.parameters.size() == 70, "all 70 parameters parsed (got %d)" % device.parameters.size())
	var rate: Object = device.get_parameter(10)
	_assert(rate != null and rate.enum_values.size() == 18 and rate.enum_values[0] == "1/1"
		and rate.enum_values[17] == "1/32T", "Rate carries the 18 sync choices")
	var instance: Object = _inst_script.new(device, 2, 0)
	var params: Array = instance.get_parameters()
	_assert(params.size() == 70, "the instance sees 70 parameters")
	for p in params:
		_assert(p.is_automation_safe, "%s is automation-safe" % p.name)
		if p.param_type == "float":
			_assert(p.is_modulatable, "%s is modulatable" % p.name)

	var latch_registry: Object = load("res://data/DeviceRegistry.gd").new()
	latch_registry._on_builtin_info_received(_latch_info())
	var latch: Object = latch_registry.get_device(LATCH_ID)
	_assert(latch != null, "the Latch registers")
	if latch == null:
		return
	var mode: Object = latch.get_parameter(0)
	var release: Object = latch.get_parameter(1)
	_assert(mode != null and mode.is_automation_safe, "Latch Mode is automation-safe")
	_assert(release != null and not release.is_automation_safe, "Latch Release All is NOT automation-safe")
