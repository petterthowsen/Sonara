# test_plugin_state.gd
# Headless tests for CLAP plugin state persistence: the state blob round-trips through the
# `.sonara` JSON, is sent to the engine once the plugin is ready, and is fetched from the engine
# (through a hand-over file) before a project save.
#
# Project and DeviceInstance reference autoloads (AudioEngineOSC) by bare name, so they are
# loaded with load() inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_plugin_state.gd -- --test
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _osc: Node
## Every instance a test connected; disconnected before the next test so a reply reaches only
## the instance at that address now.
var _connected: Array = []


func suite_name() -> String:
	return "Plugin state tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_osc = root.get_node("AudioEngineOSC")
	_test_json_round_trip()
	_test_no_state_not_saved()
	_test_restore_on_ready()
	_test_save_skips_builtin_and_unloaded()
	_test_save_reads_engine_file()
	_test_save_failure_keeps_state()
	await _test_project_refresh()
	await _test_project_refresh_timeout()


## Registered fake device, so from_json can find it again.
func _device(device_id: String, type: int) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, _device_script.DeviceCategory.Instrument, type)
		registry._devices[device_id] = device
	return device


func _plugin(ch: Object) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.clap.synth", _device_script.DeviceType.CLAP), ch.id, 0)
	ch.add_device(inst)
	inst.connect_to_engine()
	_connected.append(inst)
	return inst


func _disconnect_all() -> void:
	for inst in _connected:
		inst.disconnect_from_engine()
	_connected.clear()


func _blob(size: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(size)
	for i in size:
		out[i] = (i * 7 + 3) % 256
	return out


## Sends queued for `address` since `from` (the test OSC client never binds, so all sends queue).
func _sends_to(address: String, from: int = 0) -> Array:
	var out: Array = []
	for i in range(from, _osc._pending_sends.size()):
		var item: Dictionary = _osc._pending_sends[i]
		if item.address == address:
			out.append(item.args)
	return out


## Pretend to be the engine: write `blob` to the requested file and answer.
func _answer_save(inst: Object, args: Array, blob: PackedByteArray, size: int = -2) -> void:
	var path := str(args[0])
	if size == -2:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(blob)
		f.close()
		size = blob.size()
	_osc._on_osc_message_received(inst.osc_addr("state/saved"), [path, size], 0)


func _test_json_round_trip() -> void:
	_disconnect_all()
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var inst := _plugin(ch)
	var blob := _blob(70000)  # bigger than one OSC datagram
	inst.plugin_state = blob
	var data: Dictionary = JSON.parse_string(JSON.stringify(inst.to_json()))
	_assert(data.has("plugin_state"), "state is written to the device JSON")
	var again: Object = _device_instance_script.from_json(data)
	_assert(again.plugin_state == blob, "state survives a JSON round trip (%d bytes)" % again.plugin_state.size())
	_assert(again._plugin_state_restore_pending, "a loaded state waits to be sent to the engine")


func _test_no_state_not_saved() -> void:
	_disconnect_all()
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var inst := _plugin(ch)
	var data: Dictionary = inst.to_json()
	_assert(not data.has("plugin_state"), "no plugin_state key without a state")
	var again: Object = _device_instance_script.from_json(data)
	_assert(again.plugin_state.is_empty() and not again._plugin_state_restore_pending, "no state, nothing to restore")


func _test_restore_on_ready() -> void:
	_disconnect_all()
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var src := _plugin(ch)
	var blob := _blob(5000)
	src.plugin_state = blob
	var data: Dictionary = JSON.parse_string(JSON.stringify(src.to_json()))
	ch.remove_device_instance(src)
	src.disconnect_from_engine()
	var inst: Object = _device_instance_script.from_json(data)
	ch.add_device(inst)
	inst.connect_to_engine()
	_connected.append(inst)
	var addr: String = inst.osc_addr("state/load")

	var mark: int = _osc._pending_sends.size()
	inst._set_loading_state("loading")
	_assert(_sends_to(addr, mark).is_empty(), "nothing is sent while the plugin loads")

	inst._set_loading_state("ready")
	var sends := _sends_to(addr, mark)
	_assert(sends.size() == 1, "state/load is sent once the plugin is ready")
	if sends.size() == 1:
		var path := str(sends[0][0])
		_assert(path.is_absolute_path(), "the engine gets an absolute path: %s" % path)
		_assert(FileAccess.get_file_as_bytes(path) == blob, "the hand-over file holds the state")
		DirAccess.remove_absolute(path)

	mark = _osc._pending_sends.size()
	inst._set_loading_state("crashed:test")
	inst._set_loading_state("ready")
	_assert(_sends_to(addr, mark).is_empty(), "a reload doesn't send the project state again")


func _test_save_skips_builtin_and_unloaded() -> void:
	_disconnect_all()
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var builtin: Object = _device_instance_script.new(_device("test.builtin.synth", _device_script.DeviceType.BuiltIn), ch.id, 0)
	ch.add_device(builtin)
	builtin.connect_to_engine()
	_connected.append(builtin)
	builtin._set_loading_state("ready")
	_assert(not builtin.save_plugin_state(), "a built-in device has no plugin state to save")

	var inst := _plugin(ch)
	inst._set_loading_state("loading")
	_assert(not inst.save_plugin_state(), "a plugin that isn't ready isn't asked")
	inst._set_loading_state("failed:missing")
	_assert(not inst.save_plugin_state(), "a plugin that failed to load isn't asked")


func _test_save_reads_engine_file() -> void:
	_disconnect_all()
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var inst := _plugin(ch)
	inst._set_loading_state("ready")
	var mark: int = _osc._pending_sends.size()
	var results: Array = []
	inst.plugin_state_saved.connect(func(ok): results.append(ok))
	_assert(inst.save_plugin_state(), "a ready plugin is asked for its state")
	var sends := _sends_to(inst.osc_addr("state/save"), mark)
	_assert(sends.size() == 1, "state/save is sent")
	if sends.size() != 1:
		return
	var blob := _blob(1234)
	_answer_save(inst, sends[0], blob)
	_assert(results == [true], "plugin_state_saved(true) fires")
	_assert(inst.plugin_state == blob, "the state is read from the engine's file")
	_assert(not FileAccess.file_exists(str(sends[0][0])), "the hand-over file is removed")


func _test_save_failure_keeps_state() -> void:
	_disconnect_all()
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var inst := _plugin(ch)
	var old := _blob(10)
	inst.plugin_state = old
	inst._set_loading_state("ready")
	var results: Array = []
	inst.plugin_state_saved.connect(func(ok): results.append(ok))

	var mark: int = _osc._pending_sends.size()
	inst.save_plugin_state()
	_answer_save(inst, _sends_to(inst.osc_addr("state/save"), mark)[0], PackedByteArray(), -1)
	_assert(results == [false] and inst.plugin_state == old, "a failed save keeps the last state")

	mark = _osc._pending_sends.size()
	inst.save_plugin_state()
	_answer_save(inst, _sends_to(inst.osc_addr("state/save"), mark)[0], PackedByteArray(), 0)
	_assert(results == [false, true] and inst.plugin_state == old, "a plugin with no state extension keeps what it had")


func _test_project_refresh() -> void:
	_disconnect_all()
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var a := _plugin(ch)
	var b := _plugin(ch)
	a._set_loading_state("ready")
	b._set_loading_state("ready")
	var mark: int = _osc._pending_sends.size()
	var blob_a := _blob(300)
	var blob_b := _blob(400)
	# Answer on the next frame, while refresh_plugin_states() waits.
	var answer := func() -> void:
		_answer_save(a, _sends_to(a.osc_addr("state/save"), mark)[0], blob_a)
		_answer_save(b, _sends_to(b.osc_addr("state/save"), mark)[0], blob_b)
	answer.call_deferred()
	var started := Time.get_ticks_msec()
	await project.refresh_plugin_states(2.0)
	_assert(Time.get_ticks_msec() - started < 1000, "refresh returns once every plugin answered")
	_assert(a.plugin_state == blob_a and b.plugin_state == blob_b, "refresh collects every plugin's state")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	_assert(JSON.stringify(saved).contains(Marshalls.raw_to_base64(blob_b)), "the project JSON holds the refreshed state")


func _test_project_refresh_timeout() -> void:
	_disconnect_all()
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var inst := _plugin(ch)
	var old := _blob(20)
	inst.plugin_state = old
	inst._set_loading_state("ready")
	await project.refresh_plugin_states(0.2)
	_assert(inst.plugin_state == old, "a plugin that never answers keeps its last state")
	_assert(inst.plugin_state_saved.get_connections().is_empty(), "the refresh disconnects after a timeout")
