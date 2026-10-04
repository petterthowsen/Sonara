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
	_test_defaults_applied_on_create_not_load()
	_test_add_remove_set_and_osc()
	_test_echoes_are_swallowed()
	_test_sync_to_engine()
	_test_json_round_trip()
	_test_get_routes_into()
	_test_child_move_rewrites_routes()
	_test_child_removal_drops_or_reindexes_routes()


# --- fixtures ------------------------------------------------------------------------------

func _setup_kinds() -> void:
	_registry = load("res://data/DeviceRegistry.gd").new()
	_registry._on_modulator_kind_received(_lfo_kind_args())
	_registry._on_modulator_kind_received(_adsr_kind_args())
	_registry._on_modulator_kind_received(["velocity", "Velocity", 0, 0])
	# DeviceInstance reads kinds through AssetService (it must not name the class at compile
	# time, or the test would depend on the autoloads before they exist).
	var asset_registry: Object = root.get_node("AssetService").device_registry
	for kind_id in ["lfo", "adsr", "velocity"]:
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
	_assert(_registry.get_modulator_kinds().size() == 3, "three kinds advertised")


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
	for i in range(7):
		inst.add_modulator("velocity")
	_assert(inst.modulators.size() == 8, "eight modulators fit")
	_assert(inst.add_modulator("velocity") == null, "a ninth is refused")
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
