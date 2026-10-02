# test_preset_drop.gd
# Headless tests for device presets (phase 4): a Preset asset drops like the device it holds.
# instance_for_asset, channel fit, new-channel kind and name, drum pad drops, missing devices.
# Run: godot --headless --path Godot -s tests/test_preset_drop.gd -- --test
#
# Scripts that reference autoloads are loaded with load() instead of named.
extends TestBase

const DRUM_ID := "sonara.builtin.drum_machine"

var _asset_script: GDScript
var _library_script: GDScript
var _preset_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _project_script: GDScript
var _drop_util: GDScript
var _project: Object
var _scratch := ""


func suite_name() -> String:
	return "Preset drops"


func run_tests() -> void:
	_asset_script = load("res://browser/Asset.gd")
	_library_script = load("res://data/PresetLibrary.gd")
	_preset_script = load("res://data/DevicePreset.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_scratch = OS.get_temp_dir().path_join("sonara_preset_drop_%d" % Time.get_ticks_usec())
	_library_script.dir_override = _scratch
	_test_instance_for_asset()
	_test_channel_fit_and_new_channel()
	_test_drum_pad_drop()
	_test_missing_device()
	_cleanup(_scratch)
	_library_script.dir_override = ""


func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


## Preset asset for a saved capture of a fresh instance of `device_id`.
func _preset_asset(device_id: String, category: int, preset_name: String) -> Object:
	var device: Object = _device(device_id, category)
	var inst: Object = _device_instance_script.new(device, 0, -1)
	var preset: Object = _preset_script.capture_now(inst, preset_name)
	var path: String = _library_script.save(preset)
	var asset: Object = _asset_script.new()
	asset.type = _asset_script.TYPE.Preset
	asset.path = path
	asset.name = preset_name
	asset.device_id = device_id
	asset.device_name = device.name
	return asset


func _fresh_project() -> Object:
	_project = _project_script.new()
	return _project


func _test_instance_for_asset() -> void:
	var asset := _preset_asset("test.fx.warm", _device_script.DeviceCategory.Effect, "Warm Pad")
	var ch: Object = _fresh_project().create_instrument_track("T").channel
	var inst: Object = _drop_util.instance_for_asset(asset, ch.id, -1, _project)
	_assert(inst != null, "a preset asset instantiates")
	if inst == null:
		return
	_assert(inst.device.device_id == "test.fx.warm", "it holds the preset's device")
	_assert(inst.name == "Warm Pad", "named after the preset: %s" % inst.name)
	_assert(inst.channel_id == ch.id, "bound to the target channel")
	var other: Object = _drop_util.instance_for_asset(asset, ch.id, -1, _project)
	_assert(other.id != inst.id, "each drop gets fresh ids")
	_drop_util.drop_asset(ch, asset, -1, null)
	_assert(ch.devices.size() == 1 and ch.devices[0].device.device_id == "test.fx.warm", "drop_asset adds it to the channel")


func _test_channel_fit_and_new_channel() -> void:
	var fx_asset := _preset_asset("test.fx.air", _device_script.DeviceCategory.Effect, "Air")
	var synth_asset := _preset_asset("test.synth.lead", _device_script.DeviceCategory.Instrument, "Lead")
	_fresh_project()
	var inst_ch: Object = _project.create_instrument_track("Inst").channel
	var audio_ch: Object = _project.create_audio_track("Audio").channel
	_assert(_drop_util.can_drop_asset_on_channel(inst_ch, synth_asset), "instrument preset fits an instrument channel")
	_assert(not _drop_util.can_drop_asset_on_channel(audio_ch, synth_asset), "instrument preset is refused on an audio channel")
	_assert(_drop_util.can_drop_asset_on_channel(audio_ch, fx_asset), "effect preset fits an audio channel")
	_assert(_drop_util.new_channel_kind(synth_asset, false) == "instrument", "instrument preset makes an instrument track")
	_assert(_drop_util.new_channel_kind(synth_asset, true) == "", "instrument preset can't make a bus")
	_assert(_drop_util.new_channel_kind(fx_asset, false) == "audio", "effect preset makes an audio track")
	_assert(_drop_util.new_channel_kind(fx_asset, true) == "bus", "effect preset makes a bus")
	var made: Object = _drop_util.create_channel_for(_project, fx_asset, false)
	_assert(made != null and made.devices.size() == 1, "create_channel_for adds the preset's device")
	_assert(made != null and made.name == "Air", "the new track is named after the preset: %s" % (made.name if made else ""))


func _test_drum_pad_drop() -> void:
	var fx_asset := _preset_asset("test.fx.snare", _device_script.DeviceCategory.Effect, "Snare Room")
	_device("sonara.builtin.chain", _device_script.DeviceCategory.Effect, true)  # slot chains wrap pad devices
	var ch: Object = _fresh_project().create_instrument_track("Drums").channel
	var drum: Object = _device_instance_script.new(_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true), ch.id, -1)
	ch.add_device(drum)
	_assert(_drop_util.can_drop_on_drum_pad(fx_asset, null, ch, drum), "an empty pad accepts a preset")
	_drop_util.drop_on_drum_pad(ch, drum, 40, fx_asset)
	var pad: Object = drum.children[0] if not drum.children.is_empty() else null
	_assert(pad != null and pad.slot_note == 40, "the preset's device lands on note 40")
	_assert(pad != null and pad.children.size() == 1 and pad.children[0].device.device_id == "test.fx.snare",
			"the pad holds the preset's device")
	_assert(_drop_util.can_drop_on_drum_pad(fx_asset, pad, ch, drum), "an occupied pad accepts a preset")


func _test_missing_device() -> void:
	var asset := _preset_asset("test.fx.gone", _device_script.DeviceCategory.Effect, "Gone")
	root.get_node("AssetService").device_registry._devices.erase("test.fx.gone")
	var ch: Object = _fresh_project().create_instrument_track("T").channel
	_assert(not _drop_util.can_drop_asset_on_channel(ch, asset), "a preset whose device is missing is refused")
	_assert(_drop_util.new_channel_kind(asset, false) == "", "and can't start a channel")
	_assert(_drop_util.instance_for_asset(asset, ch.id, -1, _project) == null, "and doesn't instantiate")


func _cleanup(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_cleanup(dir.path_join(d))
	DirAccess.remove_absolute(dir)
