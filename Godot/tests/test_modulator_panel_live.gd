# Modulator panel live displays and modulator→modulator targets (spec 033 phases 3–4):
# the `modulation` payload's trailing block decodes into per-modulator states and
# modulator-param records, the panel display draws a dot at the live position, removing a
# modulator cleans its siblings' routes, and the detail knobs are assign targets.
# Run: godot --headless --path Godot -s tests/test_modulator_panel_live.gd -- --test
extends TestBase

const SYNTH_ID := "test.synth12"
const CHAIN_ID := "test.chain12"
const CUTOFF := 31
const LFO_RATE := 10

var _registry: Object
var _inst_script: GDScript
var _project_script: GDScript
var _mod_assign: GDScript
var _mod_live: GDScript
var _pane_script: GDScript
var _panel_script: GDScript

var _state_signal_cb: Callable


func suite_name() -> String:
	return "Modulator panel live displays and targets"


func run_tests() -> void:
	_inst_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_mod_assign = load("res://devices/modulators/ModAssign.gd")
	_mod_live = load("res://devices/modulators/ModLive.gd")
	_pane_script = load("res://devices/modulators/ModulatorsPane.gd")
	_panel_script = load("res://devices/modulators/ModulatorPanel.gd")
	_setup()
	await _test_old_payload_decodes_as_before()
	await _test_new_payload_fills_states_and_signals_once()
	await _test_unknown_ext_kind_is_skipped()
	await _test_kind3_updates_the_modulator_knob_not_the_device_param()
	await _test_lfo_dot_moves()
	await _test_adsr_dots_per_stage()
	await _test_velocity_dot_and_unknown_kind()
	await _test_remove_modulator_cleans_sibling_routes()
	await _test_target_name_names_mod_targets()
	await _test_relative_target_and_self_rejection()
	await _test_assign_flow_drag_on_another_panel()


# --- fixtures ------------------------------------------------------------------------------

func _setup() -> void:
	_registry = load("res://data/DeviceRegistry.gd").new()
	_registry._on_modulator_kind_received(_lfo_kind_args())
	_registry._on_modulator_kind_received(_adsr_kind_args())
	_registry._on_modulator_kind_received(["velocity", "Velocity", 0, 0])
	_registry._on_modulator_kind_received(["cc", "CC", 0, 0])
	var asset_registry: Object = root.get_node("AssetService").device_registry
	for kind_id in ["lfo", "adsr", "velocity", "cc"]:
		asset_registry.modulator_kinds[kind_id] = _registry.get_modulator_kind(kind_id)
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
	return [id, name, unit, "float", 1, minv, maxv, default_value, 1 if is_log else 0, 1.0, 0, "", 1, 1]


func _lfo_kind_args() -> Array:
	var args: Array = ["lfo", "LFO", 1, 5]
	args.append_array(_enum_param(0, "Shape", ["Sine", "Triangle", "Saw", "Square", "S&H"], 0))
	args.append_array(_float_param(10, "Rate", "Hz", 0.02, 40.0, 2.0, true))
	args.append_array(_enum_param(20, "Sync", ["Off", "1/4", "1/8"], 0))
	args.append_array(_enum_param(30, "Retrigger", ["Free", "Note"], 0))
	args.append_array(_float_param(40, "Phase", "deg", 0.0, 360.0, 0.0, false))
	return args


func _adsr_kind_args() -> Array:
	var args: Array = ["adsr", "Envelope", 0, 4]
	args.append_array(_float_param(0, "Attack", "s", 0.0005, 10.0, 0.005, false))
	args.append_array(_float_param(10, "Decay", "s", 0.0005, 10.0, 0.3, false))
	args.append_array(_float_param(20, "Sustain", "", 0.0, 1.0, 0.5, false))
	args.append_array(_float_param(30, "Release", "s", 0.0005, 10.0, 0.3, false))
	return args


func _synth() -> Object:
	return root.get_node("AssetService").device_registry.get_device(SYNTH_ID)


func _chain() -> Object:
	return root.get_node("AssetService").device_registry.get_device(CHAIN_ID)


func _instance() -> Object:
	return _inst_script.new(_synth(), 2, 0)


func _knob(base := 0.5) -> RotaryKnob:
	var knob := RotaryKnob.new()
	knob.position = Vector2(100, 100)
	knob.size = Vector2(60, 60)
	knob.min_value = 0.0
	knob.max_value = 1.0
	knob.value = base
	root.add_child(knob)
	knob.size = Vector2(60, 60)
	return knob


func _clean() -> void:
	_drop_signal_count()
	_mod_live.reset()
	_mod_assign.end()
	var osc = root.get_node_or_null("AudioEngineOSC")
	if osc != null:
		osc._pending_sends.clear()


func _osc() -> Node:
	return root.get_node_or_null("AudioEngineOSC")


func _pending(suffix: String) -> Array:
	var out: Array = []
	var osc = _osc()
	if osc == null:
		return out
	for item in osc._pending_sends:
		if str(item["address"]).ends_with(suffix):
			out.append(item)
	return out


## Encode the counted kind 0/1 records (`[kind, path, param, values]`) as the engine writes them.
func _records_blob(records: Array) -> PackedByteArray:
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


func _u16(blob: PackedByteArray, value: int) -> void:
	blob.append(value & 0xFF)
	blob.append((value >> 8) & 0xFF)


func _f32(blob: PackedByteArray, value: float) -> void:
	var f4 := PackedByteArray()
	f4.resize(4)
	f4.encode_float(0, value)
	blob.append_array(f4)


func _kind2(blob: PackedByteArray, mod_id: int, stage: int, x: float, value: float) -> void:
	blob.append(2)
	blob.append(10)
	blob.append(mod_id)
	blob.append(stage)
	_f32(blob, x)
	_f32(blob, value)


func _kind3(blob: PackedByteArray, mod_id: int, param_id: int, offset: float) -> void:
	blob.append(3)
	blob.append(9)
	blob.append(mod_id)
	var p4 := PackedByteArray()
	p4.resize(4)
	p4.encode_u32(0, param_id)
	blob.append_array(p4)
	_f32(blob, offset)


## Append an ext block to `blob`: a list of `(kind, len, bytes)` triples, or null for none.
func _append_ext(blob: PackedByteArray, ext: Variant) -> void:
	if ext == null:
		return
	_u16(blob, ext.size())
	for record in ext:
		blob.append_array(record)


## Deliver a payload; `records` is the counted list, `ext` a list of raw byte arrays or null.
func _emit(osc_path: String, records: Array, ext: Variant = null) -> void:
	var blob := _records_blob(records)
	_append_ext(blob, ext)
	var osc = _osc()
	if osc != null:
		osc.device_data_received.emit(osc_path, "modulation", blob)


func _signal_count(device) -> Array:
	var counter := [0]
	_state_signal_cb = func(_d): counter[0] += 1
	_mod_live.holder().modulator_states_changed.connect(_state_signal_cb)
	return counter


## Drop the counting connection before the test object is freed: a live connection to the
## static holder outlives the test and corrupts the heap at teardown.
func _drop_signal_count() -> void:
	if _state_signal_cb.is_valid():
		_mod_live.holder().modulator_states_changed.disconnect(_state_signal_cb)
	_state_signal_cb = Callable()


# --- T-010: decoding -----------------------------------------------------------------------

func _test_old_payload_decodes_as_before() -> void:
	_clean()
	var inst = _instance()
	inst.add_modulator("lfo")
	var base: float = inst.get_parameter_normalized(CUTOFF)
	var knob := _knob(base)
	_mod_assign.attach(knob, inst, CUTOFF)
	_mod_live.view_shown(inst)
	_emit(inst.osc_path(), [[0, [], CUTOFF, [0.2]]], null)
	var expected: float = clampf(base + 0.2, 0.0, 1.0)
	_assert(is_equal_approx(knob.mod_live_value, expected),
		"an old-format payload (no block) still moves the arc (%.3f, expected %.3f)" % [knob.mod_live_value, expected])
	_assert(ModLive.modulator_state(inst, 0).is_empty(), "and adds no modulator states")
	_emit(inst.osc_path(), [])
	_assert(knob.mod_live_value < 0.0, "the heartbeat still returns the arc to the set value")
	knob.queue_free()


func _test_new_payload_fills_states_and_signals_once() -> void:
	_clean()
	var inst = _instance()
	var mod = inst.add_modulator("lfo")
	_mod_live.view_shown(inst)
	var count: Array = _signal_count(inst)
	var k2 := PackedByteArray()
	_kind2(k2, mod.mod_id, 1, 0.25, -0.5)
	var k3 := PackedByteArray()
	_kind3(k3, mod.mod_id, LFO_RATE, 0.125)
	_emit(inst.osc_path(), [], [k2, k3])
	var state: Dictionary = ModLive.modulator_state(inst, mod.mod_id)
	_assert(not state.is_empty() and int(state["stage"]) == 1 and is_equal_approx(float(state["x"]), 0.25)
		and is_equal_approx(float(state["value"]), -0.5), "a new payload fills the modulator state")
	_assert(count[0] == 1, "the states signal fires once per payload")
	_emit(inst.osc_path(), [], [k2])
	_assert(count[0] == 2, "one more payload, one more signal")
	_assert(ModLive.modulator_state(inst, 999).is_empty(), "an unknown modulator id has no state")
	# Wholescale replacement: the next payload's block wins.
	var k2b := PackedByteArray()
	_kind2(k2b, mod.mod_id, 4, 0.75, 0.25)
	_emit(inst.osc_path(), [], [k2b])
	var state2: Dictionary = ModLive.modulator_state(inst, mod.mod_id)
	_assert(int(state2["stage"]) == 4 and is_equal_approx(float(state2["x"]), 0.75),
		"the states are replaced wholesale per payload")
	# An empty block still clears (a heartbeat with no sounding modulator).
	_emit(inst.osc_path(), [], [])
	_assert(ModLive.modulator_state(inst, mod.mod_id).is_empty(),
		"an empty ext block clears the states")
	# Old engine again: an old-format payload leaves the states alone (they are already empty).
	_emit(inst.osc_path(), [])
	_assert(count[0] == 4, "an old-format payload does not signal")
	_drop_signal_count()


func _test_unknown_ext_kind_is_skipped() -> void:
	_clean()
	var inst = _instance()
	var mod = inst.add_modulator("lfo")
	_mod_live.view_shown(inst)
	var unknown := PackedByteArray()
	unknown.append(7)
	unknown.append(3)
	unknown.append(1)
	unknown.append(2)
	unknown.append(3)
	var k2 := PackedByteArray()
	_kind2(k2, mod.mod_id, 2, 0.5, 0.25)
	_emit(inst.osc_path(), [], [unknown, k2])
	var state: Dictionary = ModLive.modulator_state(inst, mod.mod_id)
	_assert(int(state["stage"]) == 2 and is_equal_approx(float(state["x"]), 0.5),
		"an unknown ext kind is skipped by len and the following record still decodes")


# --- T-016: kind 3 targets -----------------------------------------------------------------

func _test_kind3_updates_the_modulator_knob_not_the_device_param() -> void:
	_clean()
	var inst = _instance()
	var a = inst.add_modulator("lfo")
	var b = inst.add_modulator("lfo")
	var base_rate: float = a.get_param(LFO_RATE)
	var dev_knob := _knob(inst.get_parameter_normalized(CUTOFF))
	var mod_knob := _knob(base_rate)
	_mod_assign.attach(dev_knob, inst, CUTOFF)
	_mod_assign.attach_modulator(mod_knob, inst, a.mod_id, LFO_RATE)
	_mod_live.view_shown(inst)
	var k3 := PackedByteArray()
	_kind3(k3, a.mod_id, LFO_RATE, 0.2)
	_emit(inst.osc_path(), [], [k3])
	var expected: float = clampf(base_rate + 0.2, 0.0, 1.0)
	_assert(is_equal_approx(mod_knob.mod_live_value, expected),
		"the kind 3 record moves the modulator knob's arc (%.3f, expected %.3f)" % [mod_knob.mod_live_value, expected])
	_assert(dev_knob.mod_live_value < 0.0, "the device's param 0..n knob is untouched")
	dev_knob.queue_free()
	mod_knob.queue_free()


# --- T-011: displays -----------------------------------------------------------------------

func _display(device, mod_id: int, display_size := Vector2(56, 40)) -> Control:
	var display: Control = load("res://devices/modulators/ModulatorDisplay.gd").new()
	display.custom_minimum_size = display_size
	root.add_child(display)
	display.size = display_size
	display.setup(device, mod_id)
	await process_frame
	display.size = display_size
	return display


func _test_lfo_dot_moves() -> void:
	_clean()
	var inst = _instance()
	var mod = inst.add_modulator("lfo")
	_mod_live.view_shown(inst)
	var display: Control = await _display(inst, mod.mod_id)
	_assert(not display.has_dot(), "before any payload the LFO shape has no dot")
	var k2 := PackedByteArray()
	_kind2(k2, mod.mod_id, 0, 0.25, 0.5)
	_emit(inst.osc_path(), [], [k2])
	await process_frame
	_assert(display.has_dot(), "a live state draws the dot")
	var dot: Vector2 = display.dot_position()
	var expected := Vector2(3.0 + 0.25 * (display.size.x - 6.0), 3.0 + (0.5 - 0.25) * (display.size.y - 6.0))
	_assert(dot.distance_to(expected) < 1.0, "the LFO dot sits at (phase, value) (%s vs %s)" % [dot, expected])
	var k2b := PackedByteArray()
	_kind2(k2b, mod.mod_id, 0, 0.75, -0.5)
	_emit(inst.osc_path(), [], [k2b])
	await process_frame
	_assert(display.dot_position().x > dot.x, "the dot moves with the phase")
	display.queue_free()


func _test_adsr_dots_per_stage() -> void:
	_clean()
	var inst = _instance()
	var mod = inst.add_modulator("adsr")
	_mod_live.view_shown(inst)
	var display: Control = await _display(inst, mod.mod_id)
	var h := display.size.y - 6.0
	# Attack at level 0.5: halfway up, inside the attack segment.
	var k2 := PackedByteArray()
	_kind2(k2, mod.mod_id, 1, 0.0, 0.5)
	_emit(inst.osc_path(), [], [k2])
	await process_frame
	var attack: Vector2 = display.dot_position()
	_assert(is_equal_approx(attack.y, 3.0 + 0.5 * h), "the attack dot rides the level (%s)" % attack)
	_assert(attack.x > 3.0 and attack.x < display.size.x * 0.5, "and sits along the attack segment")
	# Sustain: middle of the sustain segment, at the sustain level.
	var k2s := PackedByteArray()
	_kind2(k2s, mod.mod_id, 3, 0.0, 0.5)
	_emit(inst.osc_path(), [], [k2s])
	await process_frame
	var sustain: Vector2 = display.dot_position()
	_assert(is_equal_approx(sustain.y, 3.0 + 0.5 * h), "the sustain dot sits at the sustain level")
	_assert(sustain.x > attack.x, "and is right of the attack dot")
	# Decay at level 0.7: below the sustain level, along the decay segment.
	var k2d := PackedByteArray()
	_kind2(k2d, mod.mod_id, 2, 0.0, 0.7)
	_emit(inst.osc_path(), [], [k2d])
	await process_frame
	var decay: Vector2 = display.dot_position()
	_assert(decay.y < sustain.y and decay.y > 3.0 and decay.x > attack.x and decay.x < sustain.x,
		"the decay dot sits above the sustain level between attack and sustain (%s)" % decay)
	# Release at level 0.3: the tail, left of nothing — right of the sustain segment.
	var k2r := PackedByteArray()
	_kind2(k2r, mod.mod_id, 4, 0.0, 0.3)
	_emit(inst.osc_path(), [], [k2r])
	await process_frame
	var release: Vector2 = display.dot_position()
	_assert(release.x > sustain.x and release.y > sustain.y, "the release dot fades down the tail (%s)" % release)
	# Idle: no dot.
	var k2i := PackedByteArray()
	_kind2(k2i, mod.mod_id, 0, 0.0, 0.0)
	_emit(inst.osc_path(), [], [k2i])
	await process_frame
	_assert(not display.has_dot(), "an idle envelope has no dot")
	display.queue_free()


func _test_velocity_dot_and_unknown_kind() -> void:
	_clean()
	var inst = _instance()
	var velocity = inst.add_modulator("velocity")
	var unknown = inst.add_modulator("cc")
	_mod_live.view_shown(inst)
	var vdisplay: Control = await _display(inst, velocity.mod_id)
	var k2v := PackedByteArray()
	_kind2(k2v, velocity.mod_id, 0, 0.0, 0.25)
	_emit(inst.osc_path(), [], [k2v])
	await process_frame
	_assert(vdisplay.has_dot(), "a velocity state draws the trace dot")
	var dot: Vector2 = vdisplay.dot_position()
	_assert(is_equal_approx(dot.x, vdisplay.size.x - 3.0), "the generic dot rides the newest sample")
	_assert(is_equal_approx(dot.y, 3.0 + 0.75 * (vdisplay.size.y - 6.0)),
		"an unipolar kind maps 0..1 (%s)" % dot)
	var k2v2 := PackedByteArray()
	_kind2(k2v2, velocity.mod_id, 0, 0.0, 0.75)
	_emit(inst.osc_path(), [], [k2v2])
	await process_frame
	_assert(vdisplay.dot_position().y < dot.y, "and the dot moves with the value")
	var udisplay: Control = await _display(inst, unknown.mod_id)
	var k2u := PackedByteArray()
	_kind2(k2u, unknown.mod_id, 0, 0.0, 0.5)
	_emit(inst.osc_path(), [], [k2u])
	await process_frame
	_assert(udisplay.has_dot(), "an unregistered display kind (cc) draws the generic display without errors")
	vdisplay.queue_free()
	udisplay.queue_free()


# --- T-015: route cleanup and names ---------------------------------------------------------

func _test_remove_modulator_cleans_sibling_routes() -> void:
	_clean()
	var inst = _instance()
	var a = inst.add_modulator("lfo")
	var b = inst.add_modulator("lfo")
	inst.set_route_amount(a.mod_id, "mod/%d/param/%d" % [b.mod_id, LFO_RATE], 0.5)
	_assert(not inst.get_modulator(a.mod_id).routes.is_empty(), "setup: the route exists")
	var events: Array = []
	inst.route_changed.connect(func(mod_id, _target, _amount): events.append(mod_id))
	inst.remove_modulator(b.mod_id)
	_assert(inst.get_modulator(a.mod_id).routes.is_empty(), "removing B erases A's mod/B routes")
	_assert(events.size() == 1 and events[0] == a.mod_id, "and route_changed fired for A")


func _test_target_name_names_mod_targets() -> void:
	_clean()
	var inst = _instance()
	var a = inst.add_modulator("lfo")
	var b = inst.add_modulator("lfo")
	var tile: ModulatorPanel = _panel_script.new()
	root.add_child(tile)
	tile.setup(b)
	var name: String = tile._target_name("mod/%d/param/%d" % [a.mod_id, LFO_RATE])
	_assert(name.begins_with(a.name) and name.contains("› Rate"),
		"a mod target is named \"{modulator} › {param}\" (got \"%s\")" % name)
	_assert(tile._target_name("mod/%d" % a.mod_id) == a.name, "a bare mod target keeps the modulator name")
	tile.queue_free()


# --- T-016/T-017: assign flow ----------------------------------------------------------------

func _click(node: Control, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = Vector2(30, 30)
	node._gui_input(e)


func _motion(node: Control, relative: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.relative = relative
	e.position = Vector2(30, 30) + relative
	node._gui_input(e)


func _test_relative_target_and_self_rejection() -> void:
	_clean()
	var project = _project_script.new()
	var ch: Object = project.create_instrument_track("Inst").channel
	var inst = _inst_script.new(_chain(), ch.id, -1)
	ch.add_device(inst)
	var child = _inst_script.new(_synth(), ch.id, -1)
	ch.add_device(child, -1, inst)
	var a = inst.add_modulator("lfo")
	var b = inst.add_modulator("lfo")
	_assert(_mod_assign.relative_target(inst, inst, b.mod_id, LFO_RATE) == "mod/%d/param/%d" % [b.mod_id, LFO_RATE],
		"relative_target returns mod/{id}/param/{pid} on the same device")
	_assert(_mod_assign.relative_target(inst, child, b.mod_id, LFO_RATE) == "",
		"a mod target is same-device only")
	_assert(_mod_assign.relative_target(inst, child, -1, CUTOFF) == "child/0/param/%d" % CUTOFF,
		"a device param on a child keeps the child path")
	# The assigning modulator's own knob is rejected.
	_mod_assign.begin(inst, a.mod_id)
	var self_knob := _knob(a.get_param(LFO_RATE))
	_mod_assign.attach_modulator(self_knob, inst, a.mod_id, LFO_RATE)
	_mod_live.view_shown(inst)
	var k3 := PackedByteArray()
	_kind3(k3, a.mod_id, LFO_RATE, 0.3)
	_emit(inst.osc_path(), [], [k3])
	_assert(self_knob.mod_live_value < 0.0, "the assigning modulator's own knob is not attached")
	# A routed sibling's knob lights up and takes the amount.
	var sibling_knob := _knob(b.get_param(LFO_RATE))
	_mod_assign.attach_modulator(sibling_knob, inst, b.mod_id, LFO_RATE)
	await process_frame
	_assert(sibling_knob.mod_assign_active, "another modulator's knob is a valid target")
	_assert(is_equal_approx(sibling_knob.mod_assign_amount, 0.0), "with no route yet, the amount is 0")
	inst.set_route_amount(a.mod_id, "mod/%d/param/%d" % [b.mod_id, LFO_RATE], 0.4)
	await process_frame
	_assert(is_equal_approx(sibling_knob.mod_assign_amount, 0.4), "the amount follows the route")
	self_knob.queue_free()
	sibling_knob.queue_free()


func _test_assign_flow_drag_on_another_panel() -> void:
	_clean()
	var inst = _instance()
	var a = inst.add_modulator("lfo")
	var b = inst.add_modulator("lfo")
	var pane = _pane_script.new()
	root.add_child(pane)
	pane.size = Vector2(420, 330)
	await pane.bind_to_device(inst)
	await process_frame
	await process_frame
	# Assign mode for A, then select B: the selection must keep assign mode alive.
	_mod_assign.begin(inst, a.mod_id)
	pane._on_panel_clicked(b.mod_id)
	await process_frame
	await process_frame
	_assert(_mod_assign.is_active_for(inst, a.mod_id), "selecting B keeps assign mode for A")
	var rate_knob: RotaryKnob = pane._controls.get(LFO_RATE)
	_assert(rate_knob != null, "B's detail built its Rate knob")
	_assert(rate_knob.mod_assign_active, "B's knob is an assign target")
	var value_before: float = rate_knob.value
	_click(rate_knob, true)
	_motion(rate_knob, Vector2(0, -24))
	_click(rate_knob, false)
	await process_frame
	var target := "mod/%d/param/%d" % [b.mod_id, LFO_RATE]
	var amount: float = inst.get_modulator(a.mod_id).get_route(target)
	_assert(amount > 0.0, "an amount drag on B's Rate sets A's route into it (%.3f)" % amount)
	_assert(is_equal_approx(rate_knob.value, value_before), "the drag never moved the knob's value")
	var sent := false
	for item in _pending("/route/set"):
		if item["address"] == "%s/modulator/%d/route/set" % [inst.osc_path(), a.mod_id] \
				and str(item["args"][0]) == target:
			sent = true
	_assert(sent, "the route went out as modulator/{A}/route/set")
	# A's own knobs must ignore the drag: rebuild A's detail while assign is active.
	pane._on_panel_clicked(a.mod_id)
	await process_frame
	await process_frame
	var own_knob: RotaryKnob = pane._controls.get(LFO_RATE)
	_assert(own_knob != null and not own_knob.mod_assign_active, "A's own knob is not an assign target")
	var routes_before: int = inst.get_modulator(a.mod_id).routes.size()
	own_knob.mod_assign_active = true
	own_knob.mod_amount_changed.emit(0.5)
	own_knob.mod_assign_active = false
	_assert(inst.get_modulator(a.mod_id).routes.size() == routes_before,
		"a stray emit on A's own knob writes no route onto A")
	pane.queue_free()
