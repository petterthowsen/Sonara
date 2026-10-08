# test_note_map_sfz.gd
# Headless tests for SFZ key labels in the Auto note map (docs/specs/014-sfz-key-labels):
# DeviceInstance parsing of `keys/info`, NoteMapResolver's SFZ source, and the watcher.
#
# Run: godot --headless --path Godot -s tests/test_note_map_sfz.gd -- --test
extends TestBase

const SFZ_ID := "sonara.builtin.sfizz"
const DRUM_ID := "sonara.builtin.drum_machine"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _resolver: GDScript
var _aux: GDScript


func suite_name() -> String:
	return "SFZ note map tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_resolver = load("res://data/NoteMapResolver.gd")
	_aux = load("res://data/AuxReturnSync.gd")
	_test_key_info_parsing()
	_test_labelled_sfz_map()
	_test_unlabelled_sfz_is_not_a_source()
	_test_drum_machine_unchanged()
	_test_playable_ranges()
	_test_ranges_only_sfz()
	_test_assistant_text()
	await _test_watcher()


func _device(ch: Object, device_id: String, title: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
		registry._devices[device_id] = device
	return _device_instance_script.new(device, ch.id, 0)


## Instrument channel with an SFZ sampler on its root chain. Returns {channel, sfz}.
func _sfz_channel() -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Strings").channel
	var sfz := _device(ch, SFZ_ID, "SFZ")
	ch.add_device(sfz)
	return {"channel": ch, "sfz": sfz}


## keys/info args: [count, (key, is_keyswitch, label)..., range_count, (lo, hi)...]
func _info(entries: Array, ranges: Array = []) -> Array:
	var args: Array = [entries.size()]
	for e in entries:
		args.append_array(e)
	args.append(ranges.size())
	for r in ranges:
		args.append_array(r)
	return args


func _test_key_info_parsing() -> void:
	var d := _sfz_channel()
	var sfz: Object = d.sfz
	var hits := [0]
	sfz.key_labels_changed.connect(func() -> void: hits[0] += 1)
	sfz._on_key_info_received(_info([[60, 0, "Open"], [24, 1, "Spiccato"]]))
	_assert(hits[0] == 1, "keys/info emits key_labels_changed once (got %d)" % hits[0])
	_assert(sfz.key_labels.size() == 2, "two keys parsed (got %d)" % sfz.key_labels.size())
	_assert(sfz.key_labels[0] == {"key": 24, "keyswitch": true, "label": "Spiccato"}, "sorted by key, keyswitch flag kept (got %s)" % [sfz.key_labels[0]])
	_assert(sfz.key_labels[1] == {"key": 60, "keyswitch": false, "label": "Open"}, "playable key parsed (got %s)" % [sfz.key_labels[1]])
	sfz._on_key_info_received(_info([]))
	_assert(sfz.key_labels.is_empty(), "a count of 0 clears the labels")
	_assert(hits[0] == 2, "clearing also emits (got %d)" % hits[0])
	sfz._on_key_info_received([2, 60, 0, "Open"])
	_assert(sfz.key_labels.size() == 1, "a truncated message keeps only the complete entries (got %d)" % sfz.key_labels.size())
	_assert(_aux.is_sfz(sfz) and not _aux.is_sfz(null), "is_sfz detects the sampler")


func _test_labelled_sfz_map() -> void:
	var d := _sfz_channel()
	var ch: Object = d.channel
	d.sfz._on_key_info_received(_info([[36, 0, "Rimshot"], [24, 1, "Spiccato"], [25, 1, ""]]))
	_assert(_resolver.has_auto_source(ch), "a labelled SFZ is an Auto source")
	var map: Object = _resolver.effective_map(ch)
	_assert(map.get_name(36) == "Rimshot", "playable key named (got '%s')" % map.get_name(36))
	_assert(map.get_name(24) == "Spiccato", "keyswitch named (got '%s')" % map.get_name(24))
	_assert(map.get_name(25) == "Keyswitch", "unnamed keyswitch falls back (got '%s')" % map.get_name(25))
	_assert(map.get_color(24) == _resolver.SFZ_KEYSWITCH_COLOR and map.get_color(25) == _resolver.SFZ_KEYSWITCH_COLOR, "keyswitches use the keyswitch colour")
	_assert(map.get_color(36) == _resolver.SFZ_KEY_COLOR, "playable keys use the neutral colour")
	_assert(map.pitches().size() == 3, "only named keys get entries (got %d)" % map.pitches().size())
	_assert(map.is_keyswitch(24) and map.is_keyswitch(25), "keyswitch keys are in keyswitches")
	_assert(not map.is_keyswitch(36), "a plain labelled key is not a keyswitch")
	_assert(map.duplicate_map().is_keyswitch(24), "duplicate_map copies keyswitches")
	_assert(not _resolver.wants_drum_view(ch), "an SFZ never turns on Drum View")
	ch.set_note_map_mode(ch.NoteMapMode.NONE)
	_assert(_resolver.effective_map(ch).is_empty(), "None still means no map")


func _test_unlabelled_sfz_is_not_a_source() -> void:
	var d := _sfz_channel()
	var ch: Object = d.channel
	_assert(not _resolver.has_auto_source(ch), "an unlabelled SFZ is not a source")
	_assert(_resolver.effective_map(ch).is_empty(), "…and names nothing")
	_assert(not _resolver.wants_drum_view(ch), "…and doesn't want Drum View")
	d.sfz._on_key_info_received(_info([[36, 0, "Rimshot"]]))
	d.sfz._on_key_info_received(_info([]))
	_assert(_resolver.effective_map(ch).is_empty(), "reloading to an unlabelled SFZ clears the map")


func _test_drum_machine_unchanged() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var drum := _device(ch, DRUM_ID, "Drum Machine")
	ch.add_device(drum)
	_assert(_resolver.has_auto_source(ch) and _resolver.wants_drum_view(ch), "a Drum Machine is still a Drum View source")


func _test_watcher() -> void:
	var d := _sfz_channel()
	var watcher: Object = load("res://data/NoteMapWatcher.gd").new()
	var hits := [0]
	watcher.changed.connect(func() -> void: hits[0] += 1)
	watcher.bind(d.channel)
	d.sfz._on_key_info_received(_info([[36, 0, "Rimshot"]]))
	d.sfz._on_key_info_received(_info([[36, 0, "Rimshot"], [24, 1, "Spiccato"]]))
	await process_frame
	_assert(hits[0] == 1, "several key_labels_changed in one frame give exactly one changed (got %d)" % hits[0])
	d.sfz._on_key_info_received(_info([]))
	await process_frame
	_assert(hits[0] == 2, "a later reload notifies again (got %d)" % hits[0])
	watcher.bind(null)


func _test_playable_ranges() -> void:
	var d := _sfz_channel()
	d.sfz._on_key_info_received(_info([[24, 1, "Sustain"]], [[36, 72], [80, 90]]))
	_assert(d.sfz.playable_ranges == [[36, 72], [80, 90]], "ranges parsed (got %s)" % [d.sfz.playable_ranges])
	var map: Object = _resolver.effective_map(d.channel)
	_assert(map.is_playable(36) and map.is_playable(72) and map.is_playable(85), "keys inside ranges are playable")
	_assert(not map.is_playable(35) and not map.is_playable(73) and not map.is_playable(24), "keys outside ranges are not")
	_assert(map.has_entry(24), "a keyswitch outside the ranges keeps its map entry (the piano doesn't grey it)")
	_assert(map.duplicate_map().playable_ranges == map.playable_ranges, "duplicate keeps ranges")
	_assert(not map.to_json().has("playable_ranges"), "ranges are not serialized")
	d.sfz._on_key_info_received([0])
	_assert(d.sfz.playable_ranges.is_empty(), "an older engine (no range tail) leaves no ranges")
	d.sfz._on_key_info_received(_info([]))
	_assert(_resolver.effective_map(d.channel).is_playable(5), "no ranges: every key is playable")


func _test_ranges_only_sfz() -> void:
	var d := _sfz_channel()
	d.sfz._on_key_info_received(_info([], [[36, 36]]))
	_assert(_resolver.has_auto_source(d.channel), "an SFZ with ranges is a source")
	_assert(_resolver.effective_map(d.channel).is_empty(), "…that names nothing")
	_assert(not _resolver.wants_drum_view(d.channel), "…and never wants Drum View")


func _test_assistant_text() -> void:
	var util: GDScript = load("res://ai/tools/SfzKeyInfoUtil.gd")
	var d := _sfz_channel()
	var sfz: Object = d.sfz
	_assert(util.row_fields(sfz).is_empty(), "no file loaded: nothing to report")
	sfz.loaded_file_path = "/tmp/x.sfz"
	_assert(util.text_for(sfz, "Strings/SFZ") == "", "engine not connected: no pending message (key info will never come)")
	sfz.key_info_received = true
	_assert(util.text_for(sfz, "Strings/SFZ") == "", "an SFZ that declares nothing says nothing")
	sfz._on_key_info_received(_info([[0, 1, "Sustain"], [1, 1, ""], [60, 0, "Open"]], [[36, 72], [80, 80]]))
	var fields: Dictionary = util.row_fields(sfz)
	_assert(fields.get("playable_ranges") == [{"from": "C1", "to": "C4"}, {"from": "G#4", "to": "G#4"}], "ranges as note names (got %s)" % [fields.get("playable_ranges")])
	_assert(fields.get("keyswitches") == [{"key": "C-2", "name": "Sustain"}, {"key": "C#-2", "name": "(unnamed)"}], "keyswitches only, as note names (got %s)" % [fields.get("keyswitches")])
	var text: String = util.text_for(sfz, "Strings/SFZ")
	_assert(text.contains("Playable keys: C1-C4, G#4."), "text lists ranges (got '%s')" % text)
	_assert(text.contains("C-2 Sustain, C#-2 (unnamed)"), "text lists keyswitches (got '%s')" % text)
	var watch: Callable = util.watch(sfz)
	var t0 := Time.get_ticks_msec()
	await watch.call()
	_assert(Time.get_ticks_msec() - t0 < 500, "nothing to wait for offline: returns at once")
