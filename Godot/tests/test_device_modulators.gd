# Device modulators (spec 018): DeviceRegistry kind/default parsing, the DeviceInstance model,
# OSC messages and echo handling, JSON round trip, sync, and descendant route rewriting.
# Run: godot --headless --path Godot -s tests/test_device_modulators.gd -- --test
extends TestBase

const SYNTH_ID := "test.synth"
const CHAIN_ID := "test.chain"

var _registry: Object
var _device_script: GDScript
var _inst_script: GDScript
var _project_script: GDScript


func suite_name() -> String:
	return "Device modulators"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_inst_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_setup_kinds()
	_test_kinds_parsed()
	_test_cc_kind()
	_test_defaults_applied_on_create_not_load()
	_test_add_remove_set_and_osc()
	_test_echoes_are_swallowed()
	_test_sync_to_engine()
	_test_engine_clear_keeps_names_and_order()
	_test_json_round_trip()
	_test_get_routes_into()
	_test_swap_modulators()
	_test_sync_order_adds_before_routes()
	_test_child_move_rewrites_routes()
	_test_child_removal_drops_or_reindexes_routes()
	_test_xy_pad_model()
	_test_xy_pad_pair_mutations()
	_test_knob_bipolar_routes()


# --- fixtures ------------------------------------------------------------------------------

func _setup_kinds() -> void:
	_registry = load("res://data/DeviceRegistry.gd").new()
	_registry._on_modulator_kind_received(_lfo_kind_args())
	_registry._on_modulator_kind_received(_adsr_kind_args())
	_registry._on_modulator_kind_received(["velocity", "Velocity", 0, 0])
	_registry._on_modulator_kind_received(_cc_kind_args())
	_registry._on_modulator_kind_received(_knob_kind_args())
	_registry._on_modulator_kind_received(_xy_kind_args("xyx", "XY X"))
	_registry._on_modulator_kind_received(_xy_kind_args("xyy", "XY Y"))
	_registry._on_modulator_kind_received(_sidechain_kind_args())
	# DeviceInstance reads kinds through AssetService (it must not name the class at compile
	# time, or the test would depend on the autoloads before they exist).
	var asset_registry: Object = root.get_node("AssetService").device_registry
	for kind_id in ["lfo", "adsr", "velocity", "cc", "knob", "xyx", "xyy", "sidechain"]:
		asset_registry.modulator_kinds[kind_id] = _registry.get_modulator_kind(kind_id)
	# Built-in devices: a synth with a default modulator, and an empty container.
	_registry._on_builtin_info_received([
		SYNTH_ID, "Synth", "instrument", "", 1, 0, 2, 0, "", 0,
		1,
		31, "Cutoff", "Hz", "float", 1, 20.0, 20000.0, 2000.0, 1, 1.0, 0, "", 1, 1,
		0,
		1, "adsr", "Filter Env", 1, 0, 0.0, 1, "param/31", 0.35,
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
	args.append_array(_enum_param(0, "Shape", ["Sine", "Triangle", "Saw", "Square", "S&H"], 0))
	args.append_array(_float_param(10, "Rate", "Hz", 0.02, 40.0, 2.0, true))
	args.append_array(_enum_param(20, "Sync", ["Off", "1/4", "1/8"], 0))
	args.append_array(_enum_param(30, "Retrigger", ["Free", "Note"], 0))
	args.append_array(_float_param(40, "Phase", "deg", 0.0, 360.0, 0.0, false))
	return args


func _adsr_kind_args() -> Array:
	var args: Array = ["adsr", "ADSR", 0, 4]
	args.append_array(_float_param(0, "Attack", "s", 0.0005, 10.0, 0.005, false))
	args.append_array(_float_param(10, "Decay", "s", 0.0005, 10.0, 0.3, false))
	args.append_array(_float_param(20, "Sustain", "", 0.0, 1.0, 0.5, false))
	args.append_array(_float_param(30, "Release", "s", 0.0005, 10.0, 0.3, false))
	return args


func _cc_kind_args() -> Array:
	var args: Array = ["cc", "MIDI CC", 0, 2]
	args.append_array(_float_param(0, "CC Number", "", 0.0, 119.0, 0.0, false))
	args.append_array(_float_param(10, "Smooth", "ms", 0.0, 500.0, 0.0, false))
	return args


## Spec 036 kinds: knob (Value + Polarity), the two XY slots, sidechain (Source = channel id).
func _knob_kind_args() -> Array:
	var args: Array = ["knob", "Knob", 0, 2]
	args.append_array(_float_param(0, "Value", "", 0.0, 1.0, 0.0, false))
	args.append_array(_enum_param(10, "Polarity", ["Unipolar", "Bipolar"], 0))
	return args


func _xy_kind_args(kind_id: String, kind_name: String) -> Array:
	var args: Array = [kind_id, kind_name, 1, 1]
	args.append_array(_float_param(0, "Position", "", 0.0, 1.0, 0.5, false))
	return args


func _sidechain_kind_args() -> Array:
	var args: Array = ["sidechain", "Sidechain", 0, 5]
	args.append_array(_float_param(0, "Low Cut", "Hz", 20.0, 20000.0, 20.0, true))
	args.append_array(_float_param(10, "High Cut", "Hz", 20.0, 20000.0, 20000.0, true))
	args.append_array(_float_param(20, "Attack", "ms", 0.0, 500.0, 5.0, false))
	args.append_array(_float_param(30, "Release", "ms", 5.0, 2000.0, 150.0, false))
	args.append_array(_float_param(40, "Source", "", 0.0, 999.0, 0.0, false))
	return args


func _synth() -> Object:
	return root.get_node("AssetService").device_registry.get_device(SYNTH_ID)


func _chain() -> Object:
	return root.get_node("AssetService").device_registry.get_device(CHAIN_ID)


func _instance() -> Object:
	return _inst_script.new(_synth(), 2, 0)


func _osc() -> Node:
	return root.get_node_or_null("AudioEngineOSC")


func _modulator_messages() -> Array:
	var osc := _osc()
	if osc == null:
		return []
	return osc._pending_sends.filter(func(item) -> bool: return str(item.address).contains("/modulator/"))


# --- tests ---------------------------------------------------------------------------------

func _test_kinds_parsed() -> void:
	var lfo: Dictionary = _registry.get_modulator_kind("lfo")
	_assert(lfo.get("name") == "LFO" and lfo.get("bipolar") == true, "lfo kind parsed")
	_assert(lfo["params"].size() == 5 and lfo["params"][0].param_type == "enum", "lfo Shape is an enum")
	_assert(lfo["params"][1].id == 10 and lfo["params"][1].is_logarithmic, "lfo Rate is logarithmic")
	var adsr: Dictionary = _registry.get_modulator_kind("adsr")
	_assert(adsr.get("bipolar") == false and adsr["params"].size() == 4, "adsr kind parsed unipolar")
	_assert(_registry.get_modulator_kinds().size() == 8, "eight kinds advertised")
	var knob: Dictionary = _registry.get_modulator_kind("knob")
	_assert(knob.get("name") == "Knob" and knob.get("bipolar") == false,
		"knob parsed unipolar (polarity is per instance, spec 036 D1)")
	var xyx: Dictionary = _registry.get_modulator_kind("xyx")
	_assert(xyx.get("bipolar") == true and xyx["params"][0].id == 0, "xyx parsed bipolar with Position")
	var sc: Dictionary = _registry.get_modulator_kind("sidechain")
	_assert(sc["params"].size() == 5 and sc["params"][4].id == 40 and sc["params"][4].max_value == 999.0,
		"sidechain Source is a 0..999 channel id")


func _test_cc_kind() -> void:
	var cc: Dictionary = _registry.get_modulator_kind("cc")
	_assert(cc.get("name") == "MIDI CC" and cc.get("bipolar") == false, "cc kind parsed unipolar")
	_assert(cc["params"].size() == 2 and cc["params"][0].id == 0 and cc["params"][1].id == 10,
		"cc has CC_NUMBER slot 0 and CC_SMOOTH slot 10")

	var inst := _instance()
	inst.modulators.clear()
	var mod = inst.add_modulator("cc")
	_assert(mod != null and mod.kind == "cc", "add_modulator(\"cc\") works")
	_assert(is_equal_approx(mod.get_param(0), 0.0), "CC Number default 0")

	inst.set_modulator_param(mod.mod_id, 10, 0.25)
	var data: Dictionary = JSON.parse_string(JSON.stringify(inst.to_json()))
	var entry: Dictionary = data["modulators"][0]
	_assert(entry["kind"] == "cc", "JSON round-trip preserves kind cc")
	var loaded = _inst_script.from_json(data)
	_assert(loaded.modulators.size() == 1 and loaded.modulators[0].kind == "cc" and
		is_equal_approx(loaded.modulators[0].get_param(10), 0.25), "cc params survive JSON")


func _test_defaults_applied_on_create_not_load() -> void:
	var inst := _instance()
	_assert(inst.modulators.size() == 1, "a new instance copies the default patch")
	var mod = inst.modulators[0]
	_assert(mod.kind == "adsr" and mod.name == "Filter Env" and mod.mod_id == 0, "default kind, name and id")
	_assert(is_equal_approx(mod.get_route("param/31"), 0.35), "default route stored")
	_assert(is_equal_approx(mod.get_param(0), 0.0), "default param value normalized (%s)" % mod.get_param(0))

	# A saved project with an explicit (empty) list means the user removed them all.
	var saved: Dictionary = inst.to_json()
	saved["modulators"] = []
	var loaded = _inst_script.from_json(saved)
	_assert(loaded.modulators.is_empty(), "an empty saved list loads as no modulators")

	# A project saved before modulators existed keeps the defaults.
	var legacy: Dictionary = inst.to_json()
	legacy.erase("modulators")
	var legacy_loaded = _inst_script.from_json(legacy)
	_assert(legacy_loaded.modulators.size() == 1, "legacy data keeps the default patch")


func _test_add_remove_set_and_osc() -> void:
	var inst := _instance()
	inst.modulators.clear()
	var osc := _osc()
	if osc:
		osc._pending_sends.clear()
	var added: Array = []
	inst.modulator_added.connect(func(m): added.append(m.mod_id))
	var mod = inst.add_modulator("lfo")
	_assert(mod != null and mod.mod_id == 0 and mod.name == "LFO", "add_modulator allocates id 0")
	_assert(is_equal_approx(mod.get_param(10), _kind_rate_default_norm()), "kind defaults seed the params")
	_assert(added == [0], "modulator_added emitted")
	_assert(_sent_once("/modulator/add", [0, "lfo"]), "add sends modulator/add [id, kind]")

	if osc:
		osc._pending_sends.clear()
	inst.set_modulator_param(0, 10, 0.5)
	_assert(is_equal_approx(mod.get_param(10), 0.5), "param stored")
	_assert(_sent_once("/modulator/0/param/10/value", [0.5]), "param sends value")

	if osc:
		osc._pending_sends.clear()
	inst.set_modulator_param(0, 20, 0.4)
	_assert(is_equal_approx(mod.get_param(20), 0.5), "enum snaps to a canonical index (%s)" % mod.get_param(20))
	_assert(_sent_float("/modulator/0/param/20/value", 0.5), "enum sends its normalized value as a float")

	if osc:
		osc._pending_sends.clear()
	inst.set_route_amount(0, "param/31", 0.6)
	_assert(is_equal_approx(mod.get_route("param/31"), 0.6), "route stored")
	_assert(_sent_once("/modulator/0/route/set", ["param/31", 0.6]), "route sends target and amount")
	inst.set_route_amount(0, "param/31", 0.0)
	_assert(mod.routes.is_empty(), "amount 0 removes the route")

	# Capacity and id reuse.
	for i in range(inst.MAX_MODULATORS - 1):
		inst.add_modulator("velocity")
	_assert(inst.modulators.size() == inst.MAX_MODULATORS, "%d modulators fit" % inst.MAX_MODULATORS)
	_assert(inst.add_modulator("velocity") == null, "one more is refused")
	inst.remove_modulator(3)
	_assert(inst.get_modulator(3) == null, "remove drops it")
	var reused = inst.add_modulator("velocity")
	_assert(reused != null and reused.mod_id == 3, "the lowest free id is reused")


func _kind_rate_default_norm() -> float:
	var rate: Object = _registry.get_modulator_kind("lfo")["params"][1]
	return rate.value_to_normalized(rate.default_value)


## One message to `address_suffix` with exactly `args`.
func _sent_once(address_suffix: String, args: Array) -> bool:
	for item in _modulator_messages():
		if str(item.address).ends_with(address_suffix):
			return item.args == args
	return false


## The engine accepts only a float argument here, so the type is checked, not just the value.
func _sent_float(address_suffix: String, value: float) -> bool:
	for item in _modulator_messages():
		if str(item.address).ends_with(address_suffix):
			return item.args.size() == 1 and typeof(item.args[0]) == TYPE_FLOAT and is_equal_approx(item.args[0], value)
	return false


func _test_echoes_are_swallowed() -> void:
	var inst := _instance()
	inst.modulators.clear()
	var added: Array = []
	var changed: Array = []
	inst.modulator_added.connect(func(m): added.append(m.mod_id))
	inst.modulator_changed.connect(func(id): changed.append(id))
	inst.add_modulator("lfo")
	# The engine's echo of our own add must not duplicate the modulator.
	inst._on_modulator_add_received([0, "lfo"])
	_assert(inst.modulators.size() == 1 and added.size() == 1, "an echo of our add is swallowed")

	inst.set_modulator_param(0, 10, 0.7)
	changed.clear()
	inst._on_modulator_param_received([0.7], "/channel/2/device/0/modulator/0/param/10/value")
	_assert(changed.is_empty(), "an echo of our param edit is swallowed")
	# An unsolicited value (state/get resend) is applied.
	inst._on_modulator_param_received([0.1], "/channel/2/device/0/modulator/0/param/10/value")
	_assert(changed == [0] and is_equal_approx(inst.get_modulator(0).get_param(10), 0.1), "an unsolicited value applies")

	# An unsolicited add (resend) creates a missing modulator.
	inst._on_modulator_add_received([4, "velocity"])
	_assert(inst.get_modulator(4) != null and inst.get_modulator(4).kind == "velocity", "an unsolicited add is applied")


func _test_sync_to_engine() -> void:
	var inst := _instance()
	var osc := _osc()
	if osc == null:
		return
	osc._pending_sends.clear()
	inst.sync_to_engine()
	var messages := _modulator_messages()
	var addresses := messages.map(func(item): return str(item.address).get_file())
	_assert(addresses.has("clear"), "sync sends modulator/clear")
	_assert(addresses.has("add"), "sync sends modulator/add")
	_assert(addresses.has("value"), "sync sends the modulator parameters")
	var routes := messages.filter(func(item): return str(item.address).ends_with("/route/set"))
	_assert(routes.size() == 1 and routes[0].args[0] == "param/31", "sync sends the routes")


## The engine echoes a sync (and a state resend) as clear + one add per modulator, carrying no
## names or array order: both must survive.
func _test_engine_clear_keeps_names_and_order() -> void:
	var inst := _instance()
	inst.modulators.clear()
	var a = inst.add_modulator("lfo")
	var b = inst.add_modulator("adsr")
	a.set_name("Wobble")
	b.set_name("Pluck")
	inst.swap_modulators(a.mod_id, b.mod_id)
	var address := "/channel/2/device/0/modulator/clear"

	# Echo of our own sync: clear, then adds.
	inst.sync_modulators_to_engine()
	inst._on_modulator_clear_received([], address)
	inst._on_modulator_add_received([a.mod_id, "lfo"])
	inst._on_modulator_add_received([b.mod_id, "adsr"])
	var names: Array = inst.modulators.map(func(m): return m.name)
	_assert(names == ["Pluck", "Wobble"], "names and order survive the echo of our sync (got %s)" % [names])

	# Unsolicited resend (engine id order, not array order).
	inst._pending_mod_echoes.clear()
	inst._on_modulator_clear_received([], address)
	inst._on_modulator_add_received([a.mod_id, "lfo"])
	inst._on_modulator_add_received([b.mod_id, "adsr"])
	names = inst.modulators.map(func(m): return m.name)
	_assert(names == ["Pluck", "Wobble"], "names and order survive an engine resend (got %s)" % [names])


func _test_json_round_trip() -> void:
	var inst := _instance()
	inst.set_modulator_param(0, 0, 0.42)
	inst.set_route_amount(0, "param/31", -0.25)
	var data: Dictionary = JSON.parse_string(JSON.stringify(inst.to_json()))
	_assert(data.has("modulators") and data["modulators"].size() == 1, "modulators are saved")
	var entry: Dictionary = data["modulators"][0]
	_assert(entry["kind"] == "adsr" and entry["name"] == "Filter Env", "kind and name saved")
	_assert(is_equal_approx(float(entry["routes"][0]["amount"]), -0.25), "route amount saved")
	var loaded = _inst_script.from_json(data)
	_assert(loaded.modulators.size() == 1 and is_equal_approx(loaded.modulators[0].get_param(0), 0.42),
		"params survive JSON")
	_assert(is_equal_approx(loaded.modulators[0].get_route("param/31"), -0.25), "routes survive JSON")


func _test_get_routes_into() -> void:
	var inst := _instance()
	inst.set_route_amount(0, "param/31", 0.5)
	var routes: Array = inst.get_routes_into("param/31")
	_assert(routes.size() == 1 and routes[0]["mod_id"] == 0 and is_equal_approx(routes[0]["amount"], 0.5),
		"get_routes_into returns the modulator")
	_assert(routes[0]["bipolar"] == false and routes[0]["name"] == "Filter Env", "with name and polarity")
	_assert(inst.get_routes_into("param/99").is_empty(), "an unrouted target has no routes")


func _test_child_move_rewrites_routes() -> void:
	var project = _project_script.new()
	var ch: Object = project.create_instrument_track("Inst").channel
	var container = _inst_script.new(_chain(), ch.id, -1)
	ch.add_device(container)
	var a = _inst_script.new(_synth(), ch.id, -1)
	var b = _inst_script.new(_synth(), ch.id, -1)
	ch.add_device(a, -1, container)
	ch.add_device(b, -1, container)
	var mod = container.add_modulator("lfo")
	container.set_route_amount(mod.mod_id, "child/1/param/31", 0.5)
	_assert(container.get_modulator(mod.mod_id).get_route("child/1/param/31") == 0.5, "route set to child 1")

	ch.move_device(0, 1, container)
	_assert(is_equal_approx(container.get_modulator(mod.mod_id).get_route("child/0/param/31"), 0.5),
		"moving the child rewrites the route to child 0")
	_assert(container.get_modulator(mod.mod_id).get_route("child/1/param/31") == 0.0, "the old target is gone")


func _test_child_removal_drops_or_reindexes_routes() -> void:
	var project = _project_script.new()
	var ch: Object = project.create_instrument_track("Inst").channel
	var container = _inst_script.new(_chain(), ch.id, -1)
	ch.add_device(container)
	for i in range(3):
		ch.add_device(_inst_script.new(_synth(), ch.id, -1), -1, container)
	var mod = container.add_modulator("lfo")
	container.set_route_amount(mod.mod_id, "child/0/param/31", 0.4)
	container.set_route_amount(mod.mod_id, "child/2/param/31", -0.4)

	ch.remove_device(0, container)
	_assert(container.get_modulator(mod.mod_id).get_route("child/0/param/31") == 0.0, "a route into the removed child is dropped")
	_assert(is_equal_approx(container.get_modulator(mod.mod_id).get_route("child/1/param/31"), -0.4),
		"a later route shifts down one index")


## Reorder: swap keeps both ids, colour indexes follow the array, order is saved and loaded.
func _test_swap_modulators() -> void:
	var inst := _instance()
	inst.modulators.clear()
	var a = inst.add_modulator("lfo")
	var b = inst.add_modulator("velocity")
	inst.set_route_amount(a.mod_id, "param/31", 0.4)
	var fired: Array = []
	inst.modulators_reordered.connect(func(): fired.append(1))

	inst.swap_modulators(a.mod_id, b.mod_id)
	_assert(fired.size() == 1, "the swap emits modulators_reordered once")
	_assert(inst.modulators[0].mod_id == b.mod_id and inst.modulators[1].mod_id == a.mod_id,
		"the array entries swapped, both ids kept")
	var routes: Array = inst.get_routes_into("param/31")
	_assert(routes.size() == 1 and routes[0]["mod_id"] == a.mod_id and routes[0]["color_index"] == 1,
		"the route's colour index follows the new array position")

	var data: Dictionary = JSON.parse_string(JSON.stringify(inst.to_json()))
	_assert(int(data["modulators"][0]["mod_id"]) == b.mod_id, "the swapped order is saved")
	var loaded = _inst_script.from_json(data)
	_assert(loaded.modulators[0].mod_id == b.mod_id and loaded.modulators[1].mod_id == a.mod_id,
		"and restored as-is (no id sort)")

	inst.swap_modulators(a.mod_id, a.mod_id)
	inst.swap_modulators(a.mod_id, 7)
	_assert(fired.size() == 1, "self-swaps and missing ids are no-ops")


## Sync order: every modulator/add (+params) precedes every route/set, so a mod/{B}/… route on an
## early modulator resolves even when B comes later in the array.
func _test_sync_order_adds_before_routes() -> void:
	var inst := _instance()
	inst.modulators.clear()
	var osc := _osc()
	if osc == null:
		return
	osc._pending_sends.clear()
	var a = inst.add_modulator("lfo")
	var b = inst.add_modulator("velocity")
	inst.set_route_amount(a.mod_id, "param/31", 0.3)
	inst.set_route_amount(b.mod_id, "mod/%d/param/10" % a.mod_id, 0.5)

	osc._pending_sends.clear()
	inst.sync_modulators_to_engine()
	var messages := _modulator_messages()
	var last_add := -1
	var first_route := -1
	for i in messages.size():
		var suffix := str(messages[i].address).get_file()
		if suffix.begins_with("add") or suffix.contains("value"):
			last_add = i
		elif suffix.ends_with("set"):
			first_route = i if first_route < 0 else first_route
	_assert(last_add >= 0 and first_route > last_add,
		"every add + param precedes every route/set (%d < %d)" % [last_add, first_route])
	_assert(messages[last_add].args == [b.mod_id, "velocity"],
		"the last pre-route message is the last modulator's add")


# --- spec 036 -------------------------------------------------------------------------------

func _test_xy_pad_model() -> void:
	var inst := _instance()
	inst.modulators.clear()
	var pad = inst.add_xy_pad()
	_assert(pad != null and pad.x != null and pad.y != null, "add_xy_pad returns a pad with both slots")
	_assert(inst.modulators.size() == 2 and inst.modulators[0] == pad.x and inst.modulators[1] == pad.y,
		"the pair is appended adjacent, X first")
	var found: Array = inst.xy_pairs()
	_assert(found.size() == 1 and found[0].x == pad.x and found[0].y == pad.y,
		"xy_pairs finds the adjacent pair")
	_assert(pad.name == "XY Pad" and pad.y.name == "XY Pad Y", "the slots are named XY Pad / XY Pad Y")
	_assert(pad.holds(pad.x.mod_id) and pad.holds(pad.y.mod_id) and not pad.holds(7),
		"holds() reports the pair's slots")
	_assert(is_equal_approx(pad.position().x, 0.5) and is_equal_approx(pad.position().y, 0.5),
		"the pad starts centred")
	var osc := _osc()
	if osc:
		osc._pending_sends.clear()
	pad.set_position(Vector2(0.3, 0.8))
	_assert(is_equal_approx(pad.x.get_param(0), 0.3) and is_equal_approx(pad.y.get_param(0), 0.8),
		"set_position writes both slots' Position")
	_assert(_sent_float("/modulator/%d/param/0/value" % pad.x.mod_id, 0.3)
		and _sent_float("/modulator/%d/param/0/value" % pad.y.mod_id, 0.8),
		"one normalized value message per slot")

	# One free slot is not enough for a pair: refused, nothing added.
	var full := _instance()
	full.modulators.clear()
	for i in range(full.MAX_MODULATORS - 1):
		full.add_modulator("velocity")
	_assert(full.add_xy_pad() == null, "with one free slot an XY pad is refused")
	_assert(full.modulators.size() == full.MAX_MODULATORS - 1, "and nothing was added")
	_assert(full.add_modulator("velocity") != null, "a plain modulator still fits")


func _test_xy_pad_pair_mutations() -> void:
	var inst := _instance()
	inst.modulators.clear()
	var pad = inst.add_xy_pad()
	inst.remove_xy_pad(pad)
	_assert(inst.modulators.is_empty(), "remove_xy_pad takes both slots")

	pad = inst.add_xy_pad()
	var plain = inst.add_modulator("velocity")
	pad.set_position(Vector2(0.25, 0.75))
	var dup = inst.duplicate_xy_pad(pad)
	_assert(dup != null, "duplicate_xy_pad copies the pair")
	_assert(inst.modulators.size() == 5, "two pairs plus the plain modulator")
	var found: Array = inst.xy_pairs()
	_assert(found.size() == 2, "both pairs stay adjacent")
	_assert(inst.modulators[3] == dup.x and inst.modulators[4] == dup.y,
		"the copy pair sits at the end, X then Y")
	_assert(dup.x.kind == "xyx" and dup.y.kind == "xyy", "the copy keeps the slot kinds")
	_assert(is_equal_approx(dup.position().x, 0.25) and is_equal_approx(dup.position().y, 0.75),
		"the copy carries the position")
	_assert(dup.x.name.begins_with("XY Pad") and dup.y.name == "%s Y" % dup.x.name,
		"and a fresh pair name")

	# Renaming the X slot renames the pair's Y slot.
	inst.rename_modulator(pad.x.mod_id, "Macro")
	_assert(pad.x.name == "Macro" and pad.y.name == "Macro Y", "the pair renames together")

	# Save/load round-trips as two plain Modulators; adjacent entries re-form the pair on load.
	var data: Dictionary = JSON.parse_string(JSON.stringify(inst.to_json()))
	var kinds: Array = []
	for entry in data["modulators"]:
		kinds.append(entry["kind"])
	_assert(kinds == ["xyx", "xyy", "velocity", "xyx", "xyy"], "the save holds five plain modulators")
	var loaded = _inst_script.from_json(data)
	_assert(loaded.modulators.size() == 5, "all five load")
	var loaded_pairs: Array = loaded.xy_pairs()
	_assert(loaded_pairs.size() == 2, "the adjacent pairs re-form on load")
	_assert(is_equal_approx(loaded_pairs[0].position().x, 0.25)
		and is_equal_approx(loaded_pairs[0].position().y, 0.75), "positions survive the round trip")
	_assert(loaded.modulators[2].kind == "velocity", "and a plain modulator between pairs loads as-is")


func _test_knob_bipolar_routes() -> void:
	var inst := _instance()
	inst.modulators.clear()
	var knob = inst.add_modulator("knob")
	_assert(knob != null and knob.kind == "knob", "a knob can be added")
	_assert(is_equal_approx(knob.get_param(0), 0.0) and not knob.is_bipolar(),
		"default Value 0, default polarity Unipolar")
	inst.set_route_amount(knob.mod_id, "param/31", 0.5)
	_assert(inst.get_routes_into("param/31")[0]["bipolar"] == false, "Unipolar routes report unipolar")
	inst.set_modulator_param(knob.mod_id, 10, 1.0)
	_assert(knob.is_bipolar(), "Polarity is read from parameter 10")
	var routes: Array = inst.get_routes_into("param/31")
	_assert(routes.size() == 1 and routes[0]["bipolar"] == true,
		"a Bipolar knob's route reports bipolar (REQ-002)")
	inst.set_modulator_param(knob.mod_id, 10, 0.0)
	_assert(inst.get_routes_into("param/31")[0]["bipolar"] == false, "and back to Unipolar")
