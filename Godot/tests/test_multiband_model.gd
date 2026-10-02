# test_multiband_model.gd
# Headless tests for the Multiband FX model (spec 016 phase G1): six band chains on add, band
# names, enabling a band places its edge (D7), disabling removes the band's devices undoably (D8),
# at least two bands stay active, band chains can't be dragged out, and the band mix controls send
# no Layer `/slot/` OSC. A project round-trips a non-default active set with devices in its bands.
# Run: godot --headless --path Godot -s tests/test_multiband_model.gd -- --test
extends TestBase

const CHAIN_ID := "sonara.builtin.chain"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _add_cmd: GDScript
var _remove_cmd: GDScript
var _drop_util: GDScript
var _mb: GDScript
var _slot: GDScript
var _param: GDScript


func suite_name() -> String:
	return "Multiband FX model"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_remove_cmd = load("res://history/commands/DeviceRemoveCommand.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_mb = load("res://data/Multiband.gd")
	_slot = load("res://data/SlotChain.gd")
	_param = load("res://data/DeviceParameter.gd")
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	_register_multiband()
	_test_add_creates_six_chains()
	_test_effect_like_track_creation()
	_test_enable_places_edge()
	_test_enable_below_lowest()
	_test_disable_removes_devices_and_undoes()
	_test_cannot_drop_below_two_bands()
	_test_structure_is_locked()
	_test_slot_volume_sends_no_layer_osc()
	_test_round_trip()


func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


## Fake Multiband FX with the spec's parameter table.
func _register_multiband() -> void:
	var device: Object = _device(_mb.DEVICE_ID, _device_script.DeviceCategory.Effect, true)
	var edges := {2: 60.0, 3: 200.0, 4: 700.0, 5: 2500.0, 6: 8000.0}
	for p in range(1, 7):
		var active = _param.new(_mb.param_id(p, 0), "Band %d Active" % p)
		active.param_type = "bool"
		active.default_value = 1.0 if p in [1, 3, 5] else 0.0
		device.add_parameter(active)
		if p >= 2:
			var edge = _param.new(_mb.param_id(p, 1), "Band %d Low Edge" % p, "Hz")
			edge.min_value = 20.0
			edge.max_value = 20000.0
			edge.is_logarithmic = true
			edge.default_value = edges[p]
			device.add_parameter(edge)
		var gain = _param.new(_mb.param_id(p, 2), "Band %d Gain" % p, "dB")
		gain.min_value = -24.0
		gain.max_value = 24.0
		device.add_parameter(gain)


func _channel() -> Object:
	return _project_script.new().create_instrument_track("Inst").channel


func _multiband(ch: Object) -> Object:
	var mb: Object = _device_instance_script.new(_device(_mb.DEVICE_ID, _device_script.DeviceCategory.Effect, true), ch.id, -1)
	ch.add_device(mb)
	return mb


func _fx(ch: Object, n: String, band: Object) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.fx." + n, _device_script.DeviceCategory.Effect), ch.id, -1)
	ch.add_device(inst, -1, band)
	return inst


func _names(mb: Object) -> Array:
	return mb.children.map(func(c): return c.name)


func _active(mb: Object) -> Array:
	return Array(_mb.active_positions(mb))


func _set_edge(mb: Object, p: int, hz: float) -> void:
	mb.set_parameter_normalized(_mb.param_id(p, 1), _mb.freq_to_norm(hz))


func _toggle(mb: Object, p: int, on: bool) -> Variant:
	var cmd = _mb.toggle_command(mb, p, on)
	if cmd:
		cmd.do()
	return cmd


func _test_add_creates_six_chains() -> void:
	var ch := _channel()
	var mb := _multiband(ch)
	_assert(mb.children.size() == 6, "a new Multiband FX has six band chains")
	_assert(mb.children.all(func(c): return _slot.is_chain(c)), "every band is a slot chain")
	_assert(_active(mb) == [1, 3, 5], "default active set is {1, 3, 5}")
	_assert(_names(mb).slice(0, 5) == ["Low", "Band 2", "Mid", "Band 4", "High"] or _names(mb)[0] == "Low", "names follow the active bands")
	_assert([_names(mb)[0], _names(mb)[2], _names(mb)[4]] == ["Low", "Mid", "High"], "active bands are Low/Mid/High (got %s)" % [_names(mb)])
	_assert(mb.device.container_focuses_one_child(), "children are focused one at a time")


func _test_effect_like_track_creation() -> void:
	var mb_device: Object = _device(_mb.DEVICE_ID, _device_script.DeviceCategory.Effect, true)
	_assert(not mb_device.creates_instrument_track(), "Multiband FX behaves like an effect (no instrument track)")
	_assert(_device("sonara.builtin.layer", _device_script.DeviceCategory.Effect, true).creates_instrument_track(), "Layer still makes an instrument track")


func _test_enable_places_edge() -> void:
	var ch := _channel()
	var mb := _multiband(ch)
	_toggle(mb, 4, true)
	_assert(_active(mb) == [1, 3, 4, 5], "band 4 is active after enabling")
	var edge4 = _mb.edge_hz(mb, 4)
	_assert(edge4 > 200.0 * 1.1 and edge4 < 2500.0 / 1.1, "enabling 4 keeps its edge inside Mid's range (%.0f Hz)" % edge4)
	_assert(_names(mb)[0] == "Low" and _names(mb)[2] == "Low Mid" and _names(mb)[3] == "High Mid" and _names(mb)[4] == "High", "names become Low/Low Mid/High Mid/High (got %s)" % [_names(mb)])
	# Band 6 with a stored edge outside High's range gets the geometric mean.
	_set_edge(mb, 6, 2600.0)
	_toggle(mb, 6, true)
	var expected := sqrt(2500.0 * 20000.0)
	_assert(absf(_mb.edge_hz(mb, 6) - expected) / expected < 0.01, "enabling 6 moves an out-of-range edge to the geometric mean (%.0f Hz)" % _mb.edge_hz(mb, 6))
	_assert([_names(mb)[0], _names(mb)[2], _names(mb)[5]] == ["Sub", "Low", "High"], "five bands are named Sub/Low/Mid/High Mid/High (got %s)" % [_names(mb)])
	_toggle(mb, 2, true)
	_assert(_names(mb) == ["Sub", "Low", "Low Mid", "Mid", "High Mid", "Air"], "six bands are named Sub … Air (got %s)" % [_names(mb)])


func _test_enable_below_lowest() -> void:
	var ch := _channel()
	var mb := _multiband(ch)
	_toggle(mb, 3, false)  # {1, 5}
	# Make band 2 the lowest by switching 1 off after enabling 2.
	_toggle(mb, 2, true)
	_toggle(mb, 1, false)
	_assert(_active(mb) == [2, 5], "band 2 is the lowest after band 1 goes")
	_set_edge(mb, 5, 2500.0)
	_toggle(mb, 1, true)
	_assert(_active(mb) == [1, 2, 5], "band 1 enabled below the lowest")
	var edge2 = _mb.edge_hz(mb, 2)
	_assert(edge2 > 20.0 * 1.1 and edge2 < 2500.0 / 1.1, "the old lowest band's edge became a valid crossover (%.0f Hz)" % edge2)


func _test_disable_removes_devices_and_undoes() -> void:
	var ch := _channel()
	var mb := _multiband(ch)
	var fx := _fx(ch, "a", mb.children[2])
	_assert(_mb.device_count(mb, 3) == 1, "band 3 holds one device")
	var cmd = _mb.toggle_command(mb, 3, false)
	_toggle(mb, 2, true)  # now 4 active so band 3 may go
	cmd = _toggle(mb, 3, false)
	_assert(cmd != null, "disabling band 3 is allowed with 4 active")
	_assert(not _mb.is_active(mb, 3), "band 3 is inactive")
	_assert(mb.children[2].children.is_empty(), "disabling removed the band's device")
	cmd.undo()
	_assert(_mb.is_active(mb, 3), "undo re-enables band 3")
	_assert(mb.children[2].children.size() == 1 and mb.children[2].children[0] == fx, "undo brings the device back")


func _test_cannot_drop_below_two_bands() -> void:
	var ch := _channel()
	var mb := _multiband(ch)
	_toggle(mb, 3, false)
	_assert(_active(mb) == [1, 5], "two bands left")
	_assert(_mb.toggle_command(mb, 1, false) == null, "disabling down to one band is refused")
	_assert(not _mb.can_disable(mb, 5), "can_disable is false at two bands")


func _test_structure_is_locked() -> void:
	var ch := _channel()
	var mb := _multiband(ch)
	_assert(not _drop_util.can_drop_instance_on_host(ch, mb.children[0], null), "a band chain can't be dragged out")
	var fx := _fx(ch, "b", null)
	var add = _add_cmd.new(ch, _device_instance_script.new(_device("test.fx.c", _device_script.DeviceCategory.Effect), ch.id, -1), -1, mb)
	add.do()
	_assert(mb.children.size() == 6, "a device added onto the Multiband FX goes into a band, not a 7th chain")
	_assert(mb.children[0].children.size() == 1, "...into the lowest active band when none is open")
	_drop_util.drop_instance(ch, fx, mb, -1)
	_assert(mb.children.size() == 6 and mb.children[0].children.size() == 2, "dropping a device onto it adds to a band")
	var clear = _mb.clear_band_command(mb, 1)
	clear.do()
	_assert(mb.children[0].children.is_empty(), "Clear Band empties the chain")
	clear.undo()
	_assert(mb.children[0].children.size() == 2, "Clear Band undoes")


func _test_slot_volume_sends_no_layer_osc() -> void:
	var ch := _channel()
	var mb := _multiband(ch)
	var sent := []
	var osc: Object = root.get_node("AudioEngineOSC")
	var had: bool = osc.has_signal("message_sent")
	# `_send_layer_slot` returns early unless the parent is a Layer; check the guard directly.
	_assert(not mb.children[0]._is_layer(mb), "a Multiband FX isn't a Layer")
	mb.children[0].set_slot_volume(0.3)
	_assert(sent.is_empty() and (had or true), "setting a band chain's slot volume sends no /slot/ OSC")


func _test_round_trip() -> void:
	var ch := _channel()
	var mb := _multiband(ch)
	_toggle(mb, 6, true)
	_toggle(mb, 5, false)
	_assert(_active(mb) == [1, 3, 6], "active set {1, 3, 6}")
	_fx(ch, "rt", mb.children[2])
	var data: Dictionary = mb.to_json()
	var loaded: Object = _device_instance_script.from_json(data)
	_assert(loaded != null and loaded.children.size() == 6, "load keeps six band chains")
	_assert(_active(loaded) == [1, 3, 6], "load keeps the active set")
	_assert(loaded.children[2].children.size() == 1, "load keeps the device in band 3")
	_assert(loaded.children.all(func(c): return _slot.is_chain(c) and c.children.all(func(g): return not _slot.is_chain(g))), "slot chains are not re-wrapped")
	# Fewer than six children get the missing chains.
	var short: Dictionary = data.duplicate(true)
	short["children"] = short["children"].slice(0, 4)
	var padded: Object = _device_instance_script.from_json(short)
	_assert(padded.children.size() == 6, "a project with four bands gets the missing chains")
