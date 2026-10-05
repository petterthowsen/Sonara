# test_device_presets.gd
# Headless tests for device presets (phase 1): DevicePreset capture/instantiate, PresetLibrary
# files, fresh ids, stripped root context, file path fallback, tag normalization, and (phase 2)
# separate-output return channels.
# Run: godot --headless --path Godot -s tests/test_device_presets.gd -- --test
#
# Model classes reference autoloads, so they are loaded with load() instead of named.
extends TestBase

const CHAIN_ID := "sonara.builtin.chain"
const DRUM_ID := "sonara.builtin.drum_machine"

var _device_script: GDScript
var _inst_script: GDScript
var _preset_script: GDScript
var _library_script: GDScript
var _project_script: GDScript
var _scratch := ""


func suite_name() -> String:
	return "Device presets"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_inst_script = load("res://data/DeviceInstance.gd")
	_preset_script = load("res://data/DevicePreset.gd")
	_library_script = load("res://data/PresetLibrary.gd")
	_project_script = load("res://data/Project.gd")
	_scratch = OS.get_temp_dir().path_join("sonara_presets_test_%d" % Time.get_ticks_usec())
	_library_script.dir_override = _scratch.path_join("presets")
	_preset_script.roots_override = {}
	_test_tags()
	_test_builtin_round_trip()
	_test_chain_nested()
	_test_drum_machine()
	_test_clap_state_blob()
	_test_missing_file_fallback()
	_test_library_files()
	_test_unknown_device()
	_test_drum_returns()
	_test_layer_returns()
	_test_returns_need_project()
	_cleanup(_scratch)
	_library_script.dir_override = ""
	_preset_script.roots_override = {}


func _device(device_id: String, category: int = 1, container := false, type: int = 0) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id.get_extension(), category, type)
		device.is_container = container
		registry._devices[device_id] = device
	return device


func _channel() -> Object:
	return _project_script.new().create_instrument_track("Inst").channel


## Instance added to `ch` (under `parent` when given).
func _add(ch: Object, device_id: String, parent: Object = null, container := false) -> Object:
	var inst: Object = _inst_script.new(_device(device_id, 1, container), ch.id, -1)
	ch.add_device(inst, -1, parent)
	return inst


func _collect_ids(data: Dictionary, out: Array) -> void:
	out.append(str(data.get("id", "")))
	for child in data.get("children", []):
		_collect_ids(child, out)


func _roundtrip(preset: Object) -> Object:
	var text := JSON.stringify(preset.to_json())
	return _preset_script.from_json(JSON.parse_string(text))


func _test_tags() -> void:
	var tags: PackedStringArray = _preset_script.normalize_tags("  Pad, WARM,pad ,, Warm ,bass")
	_assert(Array(tags) == ["pad", "warm", "bass"], "tags trimmed, lower-cased and de-duplicated: %s" % str(tags))
	_assert(_preset_script.normalize_tags("").is_empty(), "empty tag string gives no tags")
	_assert(Array(_preset_script.normalize_tags(["A", "a", " b "])) == ["a", "b"], "array input is normalized too")


func _test_builtin_round_trip() -> void:
	var ch := _channel()
	var inst := _add(ch, "test.synth")
	inst.name = "My Lead"
	inst.slot_volume = 0.8
	inst.slot_note = 36
	inst.choke_targets = PackedStringArray(["0000000001"])
	inst.parameter_values[31] = 0.25
	var mod = load("res://data/Modulator.gd").new()
	mod.mod_id = 0
	mod.kind = "adsr"
	mod.name = "Filter Env"
	mod.params = {50: 0.1}
	mod.routes = {"param/31": 0.4}
	inst.modulators.append(mod)
	var preset: Object = _preset_script.capture_now(inst, "Warm Pad", "Peter", "Pad, Warm")
	_assert(preset.device_id == "test.synth" and preset.device_name == "synth", "device id and name captured")
	_assert(Array(preset.tags) == ["pad", "warm"], "tags stored normalized")
	for key in ["name", "slot_volume", "slot_note", "choke_targets", "id"]:
		_assert(not preset.device.has(key), "root field '%s' is dropped" % key)
	var loaded := _roundtrip(preset)
	_assert(loaded != null and loaded.name == "Warm Pad" and loaded.author == "Peter", "header survives JSON")
	var copy: Object = loaded.instantiate(ch.id)
	_assert(copy != null, "instantiates")
	if copy == null:
		return
	_assert(copy.name == "Warm Pad", "instance is named after the preset")
	_assert(copy.id != inst.id and not copy.id.is_empty(), "instance id is fresh")
	_assert(is_equal_approx(copy.parameter_values.get(31, -1.0), 0.25), "parameter values survive")
	_assert(copy.modulators.size() == 1 and is_equal_approx(copy.modulators[0].get_route("param/31"), 0.4),
		"modulators survive")
	_assert(copy.slot_note == -1 and copy.choke_targets.is_empty(), "root slot fields are not carried")
	_assert(inst.name == "My Lead", "the source is untouched")


func _test_chain_nested() -> void:
	var ch := _channel()
	var chain := _add(ch, CHAIN_ID, null, true)
	var a := _add(ch, "test.fx.a", chain)
	var b := _add(ch, "test.fx.b", chain)
	a.parameter_values[1] = 0.1
	var preset: Object = _preset_script.capture_now(chain, "Rack")
	var copy: Object = _roundtrip(preset).instantiate(ch.id)
	_assert(copy != null and not copy.children.is_empty(), "chain children survive")
	if copy == null:
		return
	var data: Dictionary = copy.to_json()
	var ids: Array = []
	_collect_ids(data, ids)
	var seen := {}
	for i in ids:
		seen[i] = true
	_assert(not ids.has("") and seen.size() == ids.size(), "every id in the tree is set and unique: %s" % str(ids))
	var source_ids: Array = []
	_collect_ids(chain.to_json(), source_ids)
	for i in ids:
		_assert(not source_ids.has(i), "id %s is not shared with the source" % i)
	_assert(copy.children.size() == chain.children.size(), "same child count")
	var leaf: Object = copy.children[0]
	while not leaf.children.is_empty():
		leaf = leaf.children[0]
	_assert(is_equal_approx(leaf.parameter_values.get(1, -1.0), 0.1), "nested parameter survives")
	_assert(not JSON.stringify(preset.device).contains("\"open\""), "open slot state is not stored")
	_assert(b != null, "second child existed")


func _test_drum_machine() -> void:
	var ch := _channel()
	var drum := _add(ch, DRUM_ID, null, true)
	var add_cmd: GDScript = load("res://history/commands/DeviceAddCommand.gd")
	for note in [36, 38]:
		var pad: Object = _inst_script.new(_device("test.fx.pad%d" % note), ch.id, -1)
		pad.slot_note = note
		add_cmd.new(ch, pad, -1, drum).do()
	# The pad on 38 chokes the pad on 36; ids are refreshed in the preset, so compare by note.
	drum.children[1].choke_targets = PackedStringArray([drum.children[0].id])
	var preset: Object = _preset_script.capture_now(drum, "Kit")
	var copy: Object = _roundtrip(preset).instantiate(ch.id)
	_assert(copy != null and copy.children.size() == drum.children.size(), "pads survive")
	if copy == null:
		return
	var notes: Array = []
	var chokes: Array = []
	for slot in copy.children:
		notes.append(slot.slot_note)
		chokes.append(copy.choke_target_pads(slot).map(func(p): return p.slot_note))
	var src_notes: Array = []
	for slot in drum.children:
		src_notes.append(slot.slot_note)
	_assert(notes == src_notes, "pad notes survive: %s vs %s" % [notes, src_notes])
	_assert(chokes == [[], [36]], "choke targets follow the fresh pad ids: %s" % [chokes])
	_assert(copy.children[0].id != drum.children[0].id, "pad ids are fresh")


func _test_clap_state_blob() -> void:
	var ch := _channel()
	var clap: Object = _device("clap:/fake/plug.clap", 0, false, _device_script.DeviceType.CLAP)
	clap.version = "2.1"
	var inst: Object = _inst_script.new(clap, ch.id, -1)
	ch.add_device(inst)
	inst.plugin_state = PackedByteArray([1, 2, 3, 250])
	var preset: Object = _preset_script.capture_now(inst, "Plug Patch")
	_assert(preset.plugin.get("version", "") == "2.1", "plugin info recorded")
	var copy: Object = _roundtrip(preset).instantiate(ch.id)
	_assert(copy != null and copy.plugin_state == PackedByteArray([1, 2, 3, 250]), "plugin_state blob survives")


func _test_missing_file_fallback() -> void:
	var lib := _scratch.path_join("samples_old")
	var moved := _scratch.path_join("samples_new")
	DirAccess.make_dir_recursive_absolute(moved.path_join("Drums"))
	var f := FileAccess.open(moved.path_join("Drums/kick.wav"), FileAccess.WRITE)
	f.store_string("x")
	f.close()
	_preset_script.roots_override = {"assets/samples/paths": [lib]}
	var ch := _channel()
	var inst := _add(ch, "test.sampler")
	inst.loaded_file_path = lib.path_join("Drums/kick.wav")
	var other := _add(ch, "test.sampler2")
	other.loaded_file_path = lib.path_join("Drums/gone.wav")
	var preset: Object = _preset_script.capture_now(inst, "Kick")
	_assert(preset.files.size() == 1 and preset.files[0]["rel"] == "Drums/kick.wav"
			and preset.files[0]["root"] == lib, "files table records root and relative path: %s" % str(preset.files))
	# The library moved: only the relative path against the new root finds the file.
	_preset_script.roots_override = {"assets/samples/paths": [moved]}
	var copy: Object = _roundtrip(preset).instantiate(ch.id)
	_assert(copy != null and copy.loaded_file_path == moved.path_join("Drums/kick.wav"),
			"path resolves through the relative-path fallback: %s" % (copy.loaded_file_path if copy else "null"))
	var gone: Object = _preset_script.capture_now(other, "Gone")
	var missing: Object = _roundtrip(gone)
	var copy2: Object = missing.instantiate(ch.id)
	_assert(copy2 != null and missing.missing_files.size() == 1, "an unfindable file is reported")
	_preset_script.roots_override = {}


func _test_library_files() -> void:
	var ch := _channel()
	var inst := _add(ch, "test.lib")
	var preset: Object = _preset_script.capture_now(inst, "Bad/Name?", "Me", "x")
	var path: String = _library_script.save(preset)
	_assert(path.ends_with("lib/BadName.sonpreset"), "saved under the device folder with a slug: %s" % path)
	_assert(FileAccess.file_exists(path), "file exists")
	_assert(_library_script.save(preset) == "", "saving over an existing preset needs overwrite")
	_assert(_library_script.save(preset, true) == path, "overwrite works")
	var other: Object = _preset_script.capture_now(inst, "Second")
	_library_script.save(other)
	# A user subfolder is found, and an unrelated device is not.
	var sub: String = _library_script.folder_for("lib").path_join("Mine")
	DirAccess.make_dir_recursive_absolute(sub)
	var user_copy: Object = _preset_script.capture_now(inst, "Third")
	var f := FileAccess.open(sub.path_join("Third.sonpreset"), FileAccess.WRITE)
	f.store_string(JSON.stringify(user_copy.to_json()))
	f.close()
	var broken := FileAccess.open(sub.path_join("Broken.sonpreset"), FileAccess.WRITE)
	broken.store_string("{not json")
	broken.close()
	var listed: Array = _library_script.list_for_device("test.lib", "lib")
	var names: Array = []
	for p in listed:
		names.append(p.name)
	_assert(names == ["Bad/Name?", "Second", "Third"], "lists device presets incl. subfolders, skips broken: %s" % str(names))
	_assert(_library_script.list_for_device("test.nothing", "nothing").is_empty(), "other devices have none")
	var moved_dir: String = _library_script.root_dir().path_join("elsewhere")
	DirAccess.make_dir_recursive_absolute(moved_dir)
	DirAccess.rename_absolute(path, moved_dir.path_join("moved.sonpreset"))
	var wide: Array = _library_script.list_for_device("test.lib", "no-such-folder")
	_assert(wide.size() == 3, "falls back to scanning the whole root: %d" % wide.size())
	var loaded: Object = _library_script.load_preset(wide[0].path)
	_assert(loaded != null and loaded.device_id == "test.lib" and not loaded.device.is_empty(), "full load works")
	_assert(_library_script.load_preset(sub.path_join("Broken.sonpreset")) == null, "broken file loads as null")
	var header: Object = _preset_script.read_header(wide[0].path)
	_assert(header != null and header.device.is_empty(), "header read skips the device tree")


func _test_unknown_device() -> void:
	var ch := _channel()
	var inst := _add(ch, "test.vanishing")
	var preset: Object = _roundtrip(_preset_script.capture_now(inst, "Ghost"))
	root.get_node("AssetService").device_registry._devices.erase("test.vanishing")
	_assert(preset.instantiate(ch.id) == null and not preset.warnings.is_empty(), "unknown device gives null and a warning")


func _cleanup(path: String) -> void:
	for sub in DirAccess.get_directories_at(path):
		_cleanup(path.path_join(sub))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)


# --- phase 2: return channels ---------------------------------------------------------------

## {project, channel}: the project is kept alive so devices can reach it.
func _setup(track_name := "Inst", project: Object = null) -> Dictionary:
	if project == null:
		project = _project_script.new()
	return {"project": project, "channel": project.create_instrument_track(track_name).channel}


func _add_cmd(ch: Object, inst: Object, parent: Object = null) -> Object:
	var cmd: Object = load("res://history/commands/DeviceAddCommand.gd").new(ch, inst, -1, parent)
	cmd.do()
	return cmd


## Drum Machine on a new channel with pads on `notes`. Returns {project, channel, drum, pads}.
func _drum_setup(notes: Array) -> Dictionary:
	var d := _setup("Kit")
	var drum := _add(d.channel, DRUM_ID, null, true)
	var pads: Array = []
	for note in notes:
		var pad: Object = _inst_script.new(_device("test.fx.pad%d" % note), d.channel.id, -1)
		pad.slot_note = note
		pad.name = "Pad %d" % note
		_add_cmd(d.channel, pad, drum)
		pads.append(drum.children[drum.children.size() - 1])
	d.drum = drum
	d.pads = pads
	return d


func _test_drum_returns() -> void:
	var d := _drum_setup([36, 38, 42])
	var project: Object = d.project
	var ret: Object = project.get_channel_by_id(d.pads[1].return_channel_id)
	_assert(ret != null, "pad 2 has a return")
	if ret == null:
		return
	ret.set_volume(-6.0)
	ret.set_pan(0.25)
	ret.set_mute(true)
	var eq: Object = _inst_script.new(_device("test.fx.eq"), ret.id, -1)
	ret.add_device(eq)
	eq.parameter_values[1] = 0.3
	var preset: Object = _roundtrip(_preset_script.capture_now(d.drum, "Kit"))
	_assert(preset.returns.size() == 3, "3 pad returns captured (got %d)" % preset.returns.size())
	var json := JSON.stringify(preset.returns)
	for key in ["parent_channel_id", "output_channel_id", "send_channels", "aux_pad_note"]:
		_assert(not json.contains("\"%s\"" % key), "return context '%s' is not stored" % key)

	var target := _setup("Target", project)
	var ch: Object = target.channel
	var inst: Object = preset.instantiate(ch.id, project)
	_assert(inst != null, "preset instantiates")
	if inst == null:
		return
	var before: int = project.channels.size()
	var cmd := _add_cmd(ch, inst)
	var kids: Array = project.get_channel_children(ch)
	_assert(kids.size() == 3, "new channel got 3 returns (got %d)" % kids.size())
	_assert(project.channels.size() == before + 3, "exactly 3 channels were added")
	var by_note := {}
	for k in kids:
		by_note[k.aux_pad_note] = k
	var copy: Object = by_note.get(38)
	_assert(copy != null and copy != ret, "pad 2 return is a new channel on its note")
	if copy == null:
		return
	_assert(is_equal_approx(copy.volume, -6.0), "volume kept (%f)" % copy.volume)
	_assert(is_equal_approx(copy.pan, 0.25), "pan kept")
	_assert(copy.mute, "mute kept")
	_assert(copy.devices.size() == 1 and is_equal_approx(copy.devices[0].parameter_values.get(1, -1.0), 0.3),
			"EQ and its parameter kept on the return")
	_assert(copy.devices.size() == 1 and copy.devices[0].id != eq.id, "return effect got a fresh id")
	_assert(copy.parent_channel_id == ch.id and copy.output_channel_id == ch.id, "return nested under the new channel")
	_assert(copy.id != ret.id, "fresh channel id")
	var plain: Object = by_note.get(36)
	_assert(plain != null and is_equal_approx(plain.volume, 0.0) and plain.devices.is_empty(), "other pads keep default returns")

	cmd.undo()
	_assert(project.get_channel_children(ch).is_empty() and project.channels.size() == before, "undo removes the returns")
	cmd.do()
	_assert(project.channels.size() == before + 3 and project.get_channel_by_id(copy.id) == copy,
			"redo brings back the same Channel objects")


func _test_layer_returns() -> void:
	var d := _setup("Layer")
	var ch: Object = d.channel
	var layer := _add(ch, "sonara.builtin.layer", null, true)
	for n in ["Kick", "Snare"]:
		var slot: Object = _inst_script.new(_device("test.fx.layerslot"), ch.id, -1)
		slot.name = n
		_add_cmd(ch, slot, layer)
	layer.children[1].set_slot_separate_out(true)
	var ret: Object = d.project.get_channel_by_id(layer.children[1].return_channel_id)
	_assert(ret != null, "separate slot has a return")
	if ret == null:
		return
	ret.set_volume(-3.0)
	var preset: Object = _roundtrip(_preset_script.capture_now(layer, "Split"))
	_assert(preset.returns.size() == 1, "one Layer return captured")
	var target := _setup("Target", d.project)
	var inst: Object = preset.instantiate(target.channel.id, d.project)
	var cmd := _add_cmd(target.channel, inst)
	var kids: Array = d.project.get_channel_children(target.channel)
	_assert(kids.size() == 1, "exactly one return created (got %d)" % kids.size())
	if kids.size() == 1:
		_assert(is_equal_approx(kids[0].volume, -3.0), "Layer return volume kept")
		_assert(kids[0].aux_bus_index == 1, "bus index follows the slot")
	var count: int = d.project.channels.size()
	cmd.undo()
	cmd.do()
	_assert(d.project.channels.size() == count, "undo and redo keep the channel count")


func _test_returns_need_project() -> void:
	var d := _drum_setup([36])
	var preset: Object = _roundtrip(_preset_script.capture_now(d.drum, "Kit"))
	var inst: Object = preset.instantiate(d.channel.id)
	_assert(inst != null and preset.warnings.size() == 1, "without a project the returns are skipped with a warning")
