# Modulation live values (spec 018 Phase 9): the engine's `modulation` data stream drives a
# knob's value arc and its per-voice markers, and the arc returns to the set value when the
# stream reports nothing.
# Run: godot --headless --path Godot -s tests/test_mod_live.gd -- --test
extends TestBase

const SYNTH_ID := "test.synth9"
const CHAIN_ID := "test.chain9"
const CUTOFF := 31

var _registry: Object
var _inst_script: GDScript
var _project_script: GDScript
var _mod_assign: GDScript
var _mod_live: GDScript


func suite_name() -> String:
	return "Modulation live values"


func run_tests() -> void:
	_inst_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_mod_assign = load("res://devices/modulators/ModAssign.gd")
	_mod_live = load("res://devices/modulators/ModLive.gd")
	_setup()
	await _test_view_shown_subscribes_the_chain()
	await _test_offset_record_moves_the_arc()
	await _test_values_record_wins_and_empties_return_to_base()
	await _test_child_target_reaches_the_childs_controls()
	await _test_view_hidden_unsubscribes_and_clears()


# --- fixtures ------------------------------------------------------------------------------

func _setup() -> void:
	_registry = load("res://data/DeviceRegistry.gd").new()
	_registry._on_modulator_kind_received(_lfo_kind_args())
	var asset_registry: Object = root.get_node("AssetService").device_registry
	asset_registry.modulator_kinds["lfo"] = _registry.get_modulator_kind("lfo")
	_registry._on_builtin_info_received([
		SYNTH_ID, "Synth", "instrument", "", 1, 0, 2, 0, "", 0,
		1,
		CUTOFF, "Cutoff", "Hz", "float", 1, 20.0, 20000.0, 2000.0, 1, 1.0, 0, "", 1, 1,
		0,
		0,
	])
	_registry._on_builtin_info_received([
		CHAIN_ID, "Chain", "utility", "", 0, 2, 2, 0, "", 0, 0, 1,
	])
	for device_id in [SYNTH_ID, CHAIN_ID]:
		asset_registry._devices[device_id] = _registry.get_device(device_id)


func _enum_param(id: int, name: String, values: Array, default_index: int) -> Array:
	var args: Array = [id, name, "", "enum", 1, 0.0, float(values.size() - 1), float(default_index), 0, 1.0, values.size()]
	args.append_array(values)
	args.append_array(["", 1, 0])
	return args


func _float_param(id: int, name: String, unit: String, minv: float, maxv: float, default_value: float, is_log: bool) -> Array:
	return [id, name, unit, "float", 1, minv, maxv, default_value, 1 if is_log else 0, 1.0, 0, "", 1, 0]


func _lfo_kind_args() -> Array:
	var args: Array = ["lfo", "LFO", 1, 5]
	args.append_array(_enum_param(0, "Shape", ["Sine", "Triangle", "Saw"], 0))
	args.append_array(_float_param(10, "Rate", "Hz", 0.02, 40.0, 2.0, true))
	args.append_array(_enum_param(20, "Sync", ["Off", "1/4", "1/8"], 0))
	args.append_array(_enum_param(30, "Retrigger", ["Free", "Note"], 0))
	args.append_array(_float_param(40, "Phase", "deg", 0.0, 360.0, 0.0, false))
	return args


func _synth() -> Object:
	return root.get_node("AssetService").device_registry.get_device(SYNTH_ID)


func _chain() -> Object:
	return root.get_node("AssetService").device_registry.get_device(CHAIN_ID)


func _instance() -> Object:
	return _inst_script.new(_synth(), 2, 0)


## Container with one synth child: `[container, child, lfo mod]`.
func _container_with_child() -> Array:
	var project = _project_script.new()
	var ch: Object = project.create_instrument_track("Inst").channel
	var container = _inst_script.new(_chain(), ch.id, -1)
	ch.add_device(container)
	var child = _inst_script.new(_synth(), ch.id, -1)
	ch.add_device(child, -1, container)
	return [container, child, container.add_modulator("lfo")]


func _knob(base: float) -> RotaryKnob:
	var knob := RotaryKnob.new()
	knob.position = Vector2(100, 100)
	knob.size = Vector2(60, 60)
	knob.min_value = 0.0
	knob.max_value = 1.0
	knob.value = base
	root.add_child(knob)
	knob.size = Vector2(60, 60)
	return knob


func _osc() -> Node:
	return root.get_node_or_null("AudioEngineOSC")


## Messages queued for the engine whose address ends with `suffix`.
func _pending(suffix: String) -> Array:
	var out: Array = []
	var osc = _osc()
	if osc == null:
		return out
	for item in osc._pending_sends:
		if str(item["address"]).ends_with(suffix):
			out.append(item)
	return out


func _clean() -> void:
	_mod_live.reset()
	var osc = _osc()
	if osc != null:
		osc._pending_sends.clear()


## Encode a payload as the engine writes it: records of `[kind, child path, param, values]`.
func _payload(records: Array) -> PackedByteArray:
	var blob := PackedByteArray()
	blob.append(records.size() & 0xFF)
	blob.append((records.size() >> 8) & 0xFF)
	for record in records:
		blob.append(int(record[0]))
		var path: Array = record[1]
		blob.append(path.size())
		for index in path:
			blob.append(int(index) & 0xFF)
			blob.append(int(index) >> 8)
		var p4 := PackedByteArray()
		p4.resize(4)
		p4.encode_u32(0, int(record[2]))
		blob.append_array(p4)
		var values: Array = record[3]
		blob.append(values.size())
		for value in values:
			var f4 := PackedByteArray()
			f4.resize(4)
			f4.encode_float(0, float(value))
			blob.append_array(f4)
	return blob


## Deliver a `modulation` payload as if the engine had sent it.
func _emit(osc_path: String, records: Array) -> void:
	var osc = _osc()
	if osc != null:
		osc.device_data_received.emit(osc_path, "modulation", _payload(records))


# --- tests ---------------------------------------------------------------------------------

func _test_view_shown_subscribes_the_chain() -> void:
	_clean()
	var inst = _instance()
	inst.add_modulator("lfo")
	var base: float = inst.get_parameter_normalized(CUTOFF)
	var knob := _knob(base)
	_mod_assign.attach(knob, inst, CUTOFF)
	_assert(knob.mod_live_value < 0.0, "before any payload there is no live value")
	_mod_live.view_shown(inst)
	var subs := _pending("/data/subscribe")
	var found := false
	for item in subs:
		if item["address"] == "%s/data/subscribe" % inst.osc_path() and item["args"] == ["modulation"]:
			found = true
	_assert(found, "showing a view subscribes the device's modulation stream")
	knob.queue_free()


func _test_offset_record_moves_the_arc() -> void:
	_clean()
	var inst = _instance()
	inst.add_modulator("lfo")
	var base: float = inst.get_parameter_normalized(CUTOFF)
	var knob := _knob(base)
	_mod_assign.attach(knob, inst, CUTOFF)
	_mod_live.view_shown(inst)
	_emit(inst.osc_path(), [[0, [], CUTOFF, [0.2]]])
	var expected: float = clampf(base + 0.2, 0.0, 1.0)
	_assert(is_equal_approx(knob.mod_live_value, expected),
		"the arc follows base + offset (%.3f, expected %.3f)" % [knob.mod_live_value, expected])
	_assert(knob.mod_live_values.size() == 1 and is_equal_approx(knob.mod_live_values[0], expected),
		"the offset becomes one marker")
	_assert(is_equal_approx(knob.value, base), "the knob line stays at the assigned value")
	# The next payload replaces the reporter's records wholesale.
	_emit(inst.osc_path(), [])
	_assert(knob.mod_live_value < 0.0, "the heartbeat payload returns the arc to the set value")
	_assert(knob.mod_live_values.is_empty(), "and drops the markers")
	knob.queue_free()


func _test_values_record_wins_and_empties_return_to_base() -> void:
	_clean()
	var inst = _instance()
	inst.add_modulator("lfo")
	var base: float = inst.get_parameter_normalized(CUTOFF)
	var knob := _knob(base)
	_mod_assign.attach(knob, inst, CUTOFF)
	_mod_live.view_shown(inst)
	_emit(inst.osc_path(), [[0, [], CUTOFF, [0.15]], [1, [], CUTOFF, [0.3, 0.8]]])
	_assert(is_equal_approx(knob.mod_live_value, 0.8), "a per-voice record wins, newest last (got %.3f)" % knob.mod_live_value)
	_assert(knob.mod_live_values.size() == 2, "every voice becomes a marker")
	_emit(inst.osc_path(), [[1, [], CUTOFF, []]])
	_assert(knob.mod_live_value < 0.0, "with no sounding voice the arc returns to the set value")
	_assert(knob.mod_live_values.is_empty(), "and the markers are gone")
	knob.queue_free()


func _test_child_target_reaches_the_childs_controls() -> void:
	_clean()
	var setup := _container_with_child()
	var container = setup[0]
	var child = setup[1]
	var mod = setup[2]
	container.set_route_amount(mod.mod_id, "child/0/param/%d" % CUTOFF, 0.5)
	var base: float = child.get_parameter_normalized(CUTOFF)
	var knob := _knob(base)
	_mod_assign.attach(knob, child, CUTOFF)
	_mod_live.view_shown(child)
	var found := false
	for item in _pending("/data/subscribe"):
		if item["address"] == "%s/data/subscribe" % container.osc_path() and item["args"] == ["modulation"]:
			found = true
	_assert(found, "showing the child subscribes the ancestor that holds the modulator")
	_emit(container.osc_path(), [[0, [0], CUTOFF, [0.25]]])
	var expected: float = clampf(base + 0.25, 0.0, 1.0)
	_assert(is_equal_approx(knob.mod_live_value, expected),
		"an ancestor's child-path record reaches the child's control (%.3f, expected %.3f)" % [knob.mod_live_value, expected])
	knob.queue_free()


func _test_view_hidden_unsubscribes_and_clears() -> void:
	_clean()
	var inst = _instance()
	inst.add_modulator("lfo")
	var base: float = inst.get_parameter_normalized(CUTOFF)
	var knob := _knob(base)
	_mod_assign.attach(knob, inst, CUTOFF)
	_mod_live.view_shown(inst)
	_emit(inst.osc_path(), [[0, [], CUTOFF, [0.2]]])
	_assert(knob.mod_live_value >= 0.0, "setup: the live value arrived")
	_mod_live.view_hidden(inst)
	var found := false
	for item in _pending("/data/unsubscribe"):
		if item["address"] == "%s/data/unsubscribe" % inst.osc_path() and item["args"] == ["modulation"]:
			found = true
	_assert(found, "hiding the last view unsubscribes the stream")
	_assert(knob.mod_live_value < 0.0, "and the arc returns to the set value")
	_assert(knob.mod_live_values.is_empty(), "the markers are dropped too")
	knob.queue_free()
