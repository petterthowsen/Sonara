# Device modulation routes: /builtin/info carrying sources and the default patch, set/get,
# the change signal, engine echoes, JSON round trip and the undo command.
# Run: godot --headless --path Godot -s tests/test_device_mod_routes.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Device modulation routes"


func run_tests() -> void:
	_test_builtin_info_carries_modulation()
	_test_default_patch_seeds_routes()
	_test_set_get_and_signal()
	_test_amount_clamps_and_zero_removes()
	_test_routes_for_param_and_counts()
	_test_echo_handling()
	_test_clear()
	_test_json_round_trip()
	_test_undo_command()


func _synth() -> Device:
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	# id, name, category, description, midi, audio in/out, file loading, file desc, ext count,
	# param count, (one param), is_container, source count, sources, route count, routes
	registry._on_builtin_info_received([
		"test.synth", "Synth", "instrument", "", 1, 0, 2, 0, "", 0,
		1,
		31, "Cutoff", "Hz", "float", 1, 20.0, 20000.0, 2000.0, 1, 1.0, 0, "", 1, 1,
		0,
		2, "filter_env", "Filter Env", 0, "lfo1", "LFO 1", 1,
		1, "filter_env", 31, 0.35,
	])
	return registry.get_device("test.synth")


# Loaded at runtime: the autoloads DeviceInstance refers to don't exist yet when this script compiles.
func _instance():
	return load("res://data/DeviceInstance.gd").new(_synth(), 2, 0)


func _test_builtin_info_carries_modulation() -> void:
	var device: Device = _synth()
	_assert(device != null and device.has_modulation(), "device advertises modulation")
	_assert(device.mod_sources.size() == 2, "two sources parsed")
	_assert(device.mod_sources[1]["id"] == "lfo1" and device.mod_sources[1]["bipolar"] == true,
		"source id and polarity parsed")
	_assert(device.mod_sources[0]["bipolar"] == false, "unipolar source")
	_assert(device.default_mod_routes.size() == 1
		and is_equal_approx(device.default_mod_routes[0]["amount"], 0.35), "default route parsed")
	# A device without the modulation block (older layout) still registers.
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	registry._on_builtin_info_received(["test.plain", "Plain", "effect", "", 0, 2, 2, 0, "", 0, 0, 0])
	var plain: Device = registry.get_device("test.plain")
	_assert(plain != null and not plain.has_modulation(), "no modulation block means no sources")


func _test_default_patch_seeds_routes() -> void:
	var inst = _instance()
	_assert(is_equal_approx(inst.get_mod_amount("filter_env", 31), 0.35), "new instance has the default patch")
	_assert(inst.get_mod_amount("lfo1", 31) == 0.0, "no route reads as 0")


func _test_set_get_and_signal() -> void:
	var inst = _instance()
	var seen: Array = []
	inst.mod_route_changed.connect(func(s, p, a): seen.append([s, p, a]))
	inst.set_mod_amount("lfo1", 31, 0.5)
	_assert(is_equal_approx(inst.get_mod_amount("lfo1", 31), 0.5), "amount stored")
	_assert(seen.size() == 1 and seen[0][0] == "lfo1" and seen[0][1] == 31 and is_equal_approx(seen[0][2], 0.5),
		"signal carries source, param and amount")
	inst.set_mod_amount("lfo1", 31, 0.5)
	_assert(seen.size() == 1, "an unchanged amount does not re-emit")


func _test_amount_clamps_and_zero_removes() -> void:
	var inst = _instance()
	inst.set_mod_amount("lfo1", 31, 3.0)
	_assert(inst.get_mod_amount("lfo1", 31) == 1.0, "amount clamps to 1")
	inst.set_mod_amount("lfo1", 31, -3.0)
	_assert(inst.get_mod_amount("lfo1", 31) == -1.0, "amount clamps to -1")
	inst.set_mod_amount("lfo1", 31, 0.0)
	_assert(not inst.mod_routes.has("lfo1:31"), "amount 0 removes the route")


func _test_routes_for_param_and_counts() -> void:
	var inst = _instance()
	inst.set_mod_amount("lfo1", 31, -0.25)
	var routes = inst.get_routes_for_param(31)
	_assert(routes.size() == 2 and routes[0]["source"] == "filter_env" and routes[1]["source"] == "lfo1",
		"routes come back in source order")
	_assert(inst.get_route_count_for_source("lfo1") == 1, "per-source route count")
	_assert(inst.get_routes_for_param(99).is_empty(), "unrouted parameter has no routes")


func _test_echo_handling() -> void:
	var inst = _instance()
	var seen: Array = []
	inst.mod_route_changed.connect(func(s, p, a): seen.append([s, p, a]))
	# Our own edit: the echo is swallowed.
	inst.set_mod_amount("lfo1", 31, 0.5)
	seen.clear()
	inst._on_mod_set_received(["lfo1", 31, 0.5])
	_assert(seen.is_empty(), "the echo of our own edit does not re-emit")
	# An engine-initiated value (e.g. a state/get resend) is applied.
	inst._on_mod_set_received(["lfo1", 31, -0.5])
	_assert(seen.size() == 1 and is_equal_approx(inst.get_mod_amount("lfo1", 31), -0.5),
		"an unsolicited amount is applied")
	# Two edits in flight: the stale first echo is ignored.
	inst.set_mod_amount("lfo1", 31, 0.1)
	inst.set_mod_amount("lfo1", 31, 0.2)
	seen.clear()
	inst._on_mod_set_received(["lfo1", 31, 0.1])
	_assert(seen.is_empty() and is_equal_approx(inst.get_mod_amount("lfo1", 31), 0.2),
		"a stale echo is dropped while a newer edit is in flight")
	inst._on_mod_set_received(["lfo1", 31, 0.2])
	_assert(seen.is_empty(), "the last echo matches and stays quiet")
	# An echo of zero from the engine removes the route.
	inst._on_mod_set_received(["lfo1", 31, 0.0])
	_assert(inst.get_mod_amount("lfo1", 31) == 0.0 and seen.size() == 1, "an echoed 0 removes the route")


func _test_clear() -> void:
	var inst = _instance()
	inst.set_mod_amount("lfo1", 31, 0.5)
	var seen: Array = []
	inst.mod_route_changed.connect(func(s, p, a): seen.append([s, p, a]))
	inst.clear_mod_routes()
	_assert(inst.mod_routes.is_empty(), "clear removes every route")
	_assert(seen.size() == 2 and seen.all(func(e): return e[2] == 0.0), "clear emits a removal per route")
	seen.clear()
	inst._on_mod_clear_received([])
	_assert(seen.is_empty(), "the clear echo is swallowed")
	# An unsolicited clear (resync) wipes the local routes.
	inst.set_mod_amount("lfo1", 31, 0.5)
	inst._on_mod_set_received(["lfo1", 31, 0.5])
	inst._on_mod_clear_received([])
	_assert(inst.mod_routes.is_empty(), "an unsolicited clear is applied")


func _test_json_round_trip() -> void:
	var inst = _instance()
	inst.set_mod_amount("lfo1", 31, -0.4)
	inst.set_mod_amount("filter_env", 31, 0.0)
	var data: Dictionary = JSON.parse_string(JSON.stringify(inst.to_json()))
	_assert(data.has("mod_routes"), "routes are saved")
	_assert(data["mod_routes"].size() == 1, "removed default route is not saved")
	# from_json resolves the device through AssetService; check the saved shape and the restore
	# logic on the model directly.
	var restored = _instance()
	restored.mod_routes.clear()
	for route in data["mod_routes"]:
		restored.mod_routes[_instance()._mod_key(route["source"], int(route["param_id"]))] = float(route["amount"])
	_assert(is_equal_approx(restored.get_mod_amount("lfo1", 31), -0.4), "amount survives JSON")
	_assert(restored.get_mod_amount("filter_env", 31) == 0.0, "removed default stays removed")


func _test_undo_command() -> void:
	var inst = _instance()
	inst.set_mod_amount("lfo1", 31, 0.3)
	var cmd = inst.mod_amount_command("lfo1", 31, 0.0, 0.3)
	cmd.undo()
	_assert(inst.get_mod_amount("lfo1", 31) == 0.0, "undo removes the route")
	cmd.do()
	_assert(is_equal_approx(inst.get_mod_amount("lfo1", 31), 0.3), "redo restores it")
	var drag = inst.mod_amount_command("lfo1", 31, 0.3, 0.6)
	_assert(cmd.can_merge(drag), "consecutive drags merge")
	cmd.merge_with(drag)
	cmd.undo()
	_assert(inst.get_mod_amount("lfo1", 31) == 0.0, "a merged drag undoes in one step")
