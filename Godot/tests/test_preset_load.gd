# test_preset_load.gd
# Headless tests for device presets (phase 5): DevicePresetLoadCommand (load in place, undo/redo,
# slot fields kept), preset tracking on the instance, and the save dialog's tags and author.
# Run: godot --headless --path Godot -s tests/test_preset_load.gd -- --test
#
# Scripts that reference autoloads are loaded with load() instead of named.
extends TestBase

var _device_script: GDScript
var _instance_script: GDScript
var _preset_script: GDScript
var _library_script: GDScript
var _project_script: GDScript
var _command_script: GDScript
var _drop_util: GDScript
var _scratch := ""


func suite_name() -> String:
	return "Preset load in place"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_preset_script = load("res://data/DevicePreset.gd")
	_library_script = load("res://data/PresetLibrary.gd")
	_project_script = load("res://data/Project.gd")
	_command_script = load("res://history/commands/DevicePresetLoadCommand.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_scratch = OS.get_temp_dir().path_join("sonara_preset_load_%d" % Time.get_ticks_usec())
	_library_script.dir_override = _scratch
	_test_load_in_place()
	_test_slot_fields_survive()
	_test_preset_tracking()
	await _test_save_dialog()
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


## Path of a saved preset of a fresh `device_id` instance with parameter 1 set to `value`.
func _save_preset(device_id: String, preset_name: String, value: float, container := false) -> String:
	var inst: Object = _instance_script.new(_device(device_id, _device_script.DeviceCategory.Effect, container), 0, -1)
	inst.parameter_values[1] = value
	return _library_script.save(_preset_script.capture_now(inst, preset_name))


func _ids_stripped(data: Dictionary) -> Dictionary:
	var copy := data.duplicate(true)
	_strip_ids(copy)
	return copy


func _strip_ids(data: Dictionary) -> void:
	data.erase("id")
	for child in data.get("children", []):
		_strip_ids(child)


func _test_load_in_place() -> void:
	var path := _save_preset("test.fx.load", "Bright", 0.9)
	var ch: Object = _project_script.new().create_instrument_track("T").channel
	var other: Object = _instance_script.new(_device("test.fx.other", _device_script.DeviceCategory.Effect), ch.id, -1)
	var old: Object = _instance_script.new(_device("test.fx.load", _device_script.DeviceCategory.Effect), ch.id, -1)
	old.name = "My Delay"
	old.parameter_values[1] = 0.1
	ch.add_device(other)
	ch.add_device(old)
	var before: Dictionary = _ids_stripped(old.to_json())
	var fresh: Object = _drop_util.instance_for_preset_path(path, ch.id, null)
	var cmd: Object = _command_script.new(ch, old, fresh)
	cmd.do()
	_assert(ch.devices.size() == 2 and ch.devices[1] == fresh, "the device is replaced at the same position")
	_assert(ch.devices[0] == other, "its neighbour stays")
	_assert(is_equal_approx(fresh.parameter_values.get(1, -1.0), 0.9), "the preset's parameters apply")
	_assert(fresh.name == "My Delay", "a name the user typed is kept: %s" % fresh.name)
	_assert(fresh.preset_name == "Bright" and fresh.preset_path == path, "the instance remembers its preset")
	cmd.undo()
	_assert(ch.devices.size() == 2 and ch.devices[1] == old, "undo puts the old device back")
	_assert(_ids_stripped(old.to_json()) == before, "undo restores the exact previous state")
	cmd.do()
	_assert(ch.devices[1] == fresh and ch.devices.size() == 2, "redo loads the same preset instance again")
	# Default name: the preset's name wins.
	var plain: Object = _instance_script.new(_device("test.fx.load", _device_script.DeviceCategory.Effect), ch.id, -1)
	ch.add_device(plain)
	var named: Object = _drop_util.instance_for_preset_path(path, ch.id, null)
	_command_script.new(ch, plain, named).do()
	_assert(named.name == "Bright", "a default name becomes the preset name: %s" % named.name)


func _test_slot_fields_survive() -> void:
	var path := _save_preset("sonara.builtin.chain", "Chain Preset", 0.5, true)
	_device("sonara.builtin.drum_machine", _device_script.DeviceCategory.Instrument, true)
	var ch: Object = _project_script.new().create_instrument_track("Drums").channel
	var drum: Object = _instance_script.new(_device("sonara.builtin.drum_machine", _device_script.DeviceCategory.Instrument, true), ch.id, -1)
	ch.add_device(drum)
	var pad: Object = _instance_script.new(_device("test.fx.pad", _device_script.DeviceCategory.Effect), ch.id, -1)
	ch.add_device(pad, -1, drum)
	var slot: Object = drum.children[0]
	slot.slot_note = 40
	slot.choke_group = 3
	slot.slot_volume = 0.8
	slot.slot_mute = true
	slot.return_channel_id = 77
	var fresh: Object = _drop_util.instance_for_preset_path(path, ch.id, null)
	var cmd: Object = _command_script.new(ch, slot, fresh)
	cmd.do()
	var now: Object = drum.children[0]
	_assert(now == fresh, "the slot chain is replaced")
	_assert(now.slot_note == 40 and now.choke_group == 3, "pad note and choke group carry over")
	_assert(is_equal_approx(now.slot_volume, 0.8) and now.slot_mute, "slot mix carries over")
	_assert(now.return_channel_id == 77, "the pad return id carries over")
	cmd.undo()
	_assert(drum.children[0] == slot and slot.slot_note == 40, "undo restores the old slot chain")


func _test_preset_tracking() -> void:
	var inst: Object = _instance_script.new(_device("test.fx.track", _device_script.DeviceCategory.Effect), 0, -1)
	var seen := [0]
	inst.preset_changed.connect(func(): seen[0] += 1)
	inst.set_preset("Warm", "/x/Warm.sonpreset")
	inst.set_preset("Warm", "/x/Warm.sonpreset")
	_assert(seen[0] == 1, "preset_changed fires once per change")
	var copy: Object = _instance_script.from_json(inst.to_json())
	_assert(copy != null and copy.preset_name == "Warm" and copy.preset_path == "/x/Warm.sonpreset", "the preset survives the project round trip")
	var preset: Object = _preset_script.capture_now(inst, "Other")
	_assert(not preset.device.has("preset_name"), "a preset does not store the preset it came from")


func _test_save_dialog() -> void:
	var scene: PackedScene = load("res://devices/DevicePresetSaveDialog.tscn")
	var dialog: Window = scene.instantiate()
	root.add_child(dialog)
	await process_frame
	var inst: Object = _instance_script.new(_device("test.fx.dialog", _device_script.DeviceCategory.Effect), 0, -1)
	dialog.open_for(inst)
	dialog.get_node("%NameEdit").text = "Dialog Preset"
	dialog.get_node("%TagsEdit").text = " Pad, WARM ,pad,, "
	dialog.get_node("%AuthorEdit").text = "Tester"
	await dialog._capture_and_write(false)
	var path: String = _library_script.path_for("test.fx.dialog", "Dialog Preset")
	var header: Object = _preset_script.read_header(path)
	_assert(header != null, "saving writes the preset file")
	if header:
		_assert(Array(header.tags) == ["pad", "warm"], "tags are normalized: %s" % str(header.tags))
		_assert(header.author == "Tester", "the author is saved")
	_assert(inst.preset_name == "Dialog Preset" and inst.preset_path == path, "the device now points at the saved preset")
	var author: String = str(root.get_node("Sonara").get_config("presets/author", ""))
	_assert(author == "Tester", "the author is remembered in config")
	dialog.open_for(inst)
	_assert(dialog.get_node("%AuthorEdit").text == "Tester", "the author is prefilled next time")
	_assert(dialog.get_node("%TagsEdit").text == "pad, warm", "tags are prefilled from the current preset")
	dialog.get_node("%NameEdit").text = ""
	dialog._update_save_enabled()
	_assert(dialog.get_node("%SaveButton").disabled, "Save is disabled while the name is empty")
	dialog.queue_free()


func _cleanup(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_cleanup(dir.path_join(d))
	DirAccess.remove_absolute(dir)
