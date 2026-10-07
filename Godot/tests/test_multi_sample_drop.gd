# test_multi_sample_drop.gd
# Headless tests for dropping several audio files where no Sampler exists yet: onto a device row it
# creates a Sampler in multisample mode with one zone per file, onto an empty Drum Machine pad it
# creates one on that pad, and onto an occupied pad's Sampler it adds zones. Single files, mixed
# selections and non-instrument channels keep their old rules.
# Run: godot --headless --path Godot -s tests/test_multi_sample_drop.gd -- --test
extends TestBase

const DRUM_ID := "sonara.builtin.drum_machine"
const SAMPLER_ID := "sonara.builtin.sampler"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _asset_script: GDScript
var _drop_util: GDScript
var _host_script: GDScript
var _history_util: GDScript
var _recorded: Array = []


func suite_name() -> String:
	return "Multi-sample drop"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_asset_script = load("res://browser/Asset.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_host_script = load("res://devices/DeviceChainDropHost.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	_history_util.test_recorder = func(cmd): _recorded.append(cmd)
	_device(SAMPLER_ID, _device_script.DeviceCategory.Instrument, false, true)
	_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true)
	_test_device_row_creates_multisample_sampler()
	_test_rules_stay_narrow()
	_test_empty_pad_creates_sampler()
	_test_occupied_pad_adds_zones()
	_history_util.test_recorder = Callable()
	_recorded.clear()


func _device(device_id: String, category: int, container := false, loads := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		if loads:
			device.supports_file_loading = true
			device.supported_file_extensions.assign([".wav"])
		registry._devices[device_id] = device
	return device


func _files(names: Array) -> Array:
	var out: Array = []
	for n in names:
		var asset: Object = _asset_script.new()
		asset.type = _asset_script.TYPE.Audio
		asset.path = "/tmp/" + n
		out.append(asset)
	return out


func _paths(inst: Object) -> Array:
	return inst.multisample.zones.map(func(z): return z.path.get_file())


func _test_device_row_creates_multisample_sampler() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Inst").channel
	var host: Object = _host_script.new()
	host.bind(ch)
	var files := _files(["c3.wav", "d3.wav", "e3.wav"])
	_assert(host.can_drop(files, -1), "a row on an instrument channel accepts several audio files")
	_assert(host.drop(files, -1), "the drop is applied")
	_assert(ch.devices.size() == 1 and ch.devices[0].is_sampler(), "a Sampler is created")
	var sampler: Object = ch.devices[0]
	_assert(sampler.multisample != null and sampler.multisample.active, "in multisample mode")
	_assert(_paths(sampler) == ["c3.wav", "d3.wav", "e3.wav"], "with one zone per file: %s" % [_paths(sampler)])
	_assert(sampler.loaded_file_path.is_empty(), "and no single-mode file")
	_undo()
	_assert(ch.devices.is_empty(), "one undo removes the Sampler")


func _test_rules_stay_narrow() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Inst").channel
	var audio: Object = project.create_audio_track("Audio").channel
	var host: Object = _host_script.new()
	host.bind(ch)
	_assert(not host.can_drop(_files(["a.wav"]), -1), "a single file still does not create a device on a row")
	var mixed := _files(["a.wav", "b.wav"])
	mixed[1].type = _asset_script.TYPE.Midi
	_assert(not host.can_drop(mixed, -1), "a selection with a non-audio asset is refused")
	host.bind(audio)
	_assert(not host.can_drop(_files(["a.wav", "b.wav"]), -1), "an audio channel can't hold a Sampler")


func _drum() -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var drum: Object = _device_instance_script.new(_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true), ch.id, -1)
	ch.add_device(drum)
	return {"ch": ch, "drum": drum}


func _test_empty_pad_creates_sampler() -> void:
	var s := _drum()
	var files := _files(["k1.wav", "k2.wav"])
	_assert(_drop_util.can_drop_on_drum_pad(files, null, s.ch, s.drum, 36), "an empty pad accepts several samples")
	_drop_util.drop_on_drum_pad(s.ch, s.drum, 36, files)
	_assert(s.drum.children.size() == 1, "one pad device is added")
	var pad: Object = s.drum.children[0]
	_assert(pad.slot_note == 36 and pad.is_sampler(), "a Sampler sits on note 36")
	_assert(pad.multisample.active and _paths(pad) == ["k1.wav", "k2.wav"], "holding the samples as zones")
	_undo()
	_assert(s.drum.children.is_empty(), "undo removes the pad")
	# Through the pad-row host an empty pad takes the same drop.
	var host: Object = _host_script.new()
	host.bind_slot(s.ch, s.drum, _device_instance_script.pad_slot_key(40))
	_assert(host.pad_note == 40 and host.can_drop(files, -1) and host.drop(files, -1), "the empty-pad row takes it")
	_assert(s.drum.children.size() == 1 and s.drum.children[0].slot_note == 40, "on its own note")


func _test_occupied_pad_adds_zones() -> void:
	var s := _drum()
	_drop_util.drop_on_drum_pad(s.ch, s.drum, 36, _files(["k1.wav", "k2.wav"]))
	var pad: Object = s.drum.children[0]
	var more := _files(["k3.wav", "k4.wav"])
	_assert(_drop_util.can_drop_on_drum_pad(more, pad, s.ch, s.drum, 36), "an occupied Sampler pad accepts several samples")
	_drop_util.drop_on_drum_pad(s.ch, s.drum, 36, more)
	_assert(s.drum.children.size() == 1 and pad.multisample.zones.size() == 4, "they join the pad's zones")


func _undo() -> void:
	_recorded.pop_back().undo()
