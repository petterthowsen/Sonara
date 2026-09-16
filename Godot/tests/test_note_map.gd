# test_note_map.gd
# Headless tests for note maps (docs/specs/002-note-maps): the NoteMap model, the
# user library, the Auto map resolved from a Drum Machine, channel persistence,
# and the project/library independence rules.
#
# Project, Channel and DeviceInstance reference autoloads (AudioEngineOSC,
# AssetService) by bare name, so they are loaded with load() inside run_tests()
# rather than being named by class, matching test_multi_out_devices.gd.
# Run: godot --headless --path Godot -s tests/test_note_map.gd -- --test
extends TestBase

var _project_script: GDScript
var _channel_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _aux: GDScript
var _library: GDScript
var _resolver: GDScript
var _watcher_script: GDScript

var _scratch := ""


func suite_name() -> String:
	return "Note map tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_channel_script = load("res://data/Channel.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_aux = load("res://data/AuxReturnSync.gd")
	_library = load("res://data/NoteMapLibrary.gd")
	_resolver = load("res://data/NoteMapResolver.gd")
	_watcher_script = load("res://data/NoteMapWatcher.gd")

	_scratch = OS.get_cache_dir().path_join("sonara_note_map_tests_%d" % Time.get_ticks_usec())
	_library.dir_override = _scratch

	_test_model()
	_test_json_roundtrip()
	_test_library_roundtrip()
	_test_auto_map()
	_test_auto_map_no_source()
	_test_channel_assignment()
	_test_older_projects()
	_test_project_is_self_contained()
	_test_edits_stay_in_the_project()
	_test_save_auto_map_as_named()
	_test_drum_view_preference()
	await _test_watcher()

	_library.dir_override = ""
	_remove_scratch()


# --- model -----------------------------------------------------------------

func _test_model() -> void:
	var map := NoteMap.new("GM Drums", "Drums", "Peter")
	map.set_entry(36, "Kick", Color.RED)
	map.set_entry(38, "Snare", Color.BLUE)
	_assert(map.get_name(36) == "Kick", "REQ-006: entry name reads back")
	_assert(map.get_color(38).is_equal_approx(Color.BLUE), "REQ-006: entry colour reads back")
	_assert(map.get_name(37) == "", "an unmapped pitch has no name")
	_assert(map.get_color(37).a == 0.0, "an unmapped pitch has a transparent colour")
	_assert(not map.has_entry(37) and map.has_entry(36), "has_entry only for mapped pitches")
	_assert(map.pitches() == PackedInt32Array([36, 38]), "pitches() is sorted")

	map.erase_entry(36)
	_assert(not map.has_entry(36), "REQ-007: erase_entry unmaps the pitch")
	_assert(not map.is_empty(), "one entry left, so not empty")
	map.erase_entry(38)
	_assert(map.is_empty(), "erasing every entry empties the map")

	var bounds := NoteMap.new()
	bounds.set_entry(-1, "low", Color.RED)
	bounds.set_entry(128, "high", Color.RED)
	_assert(bounds.is_empty(), "pitches outside 0-127 are ignored")


func _test_json_roundtrip() -> void:
	var map := NoteMap.new("GM Drums", "Drums", "Peter")
	map.set_entry(36, "Kick", Color("#cc4444"))
	map.set_entry(38, "Snare", Color("#4444cc"))

	# Through real JSON text, so int keys really do come back as strings.
	var text := JSON.stringify(map.to_json())
	var back := NoteMap.from_json(JSON.parse_string(text))
	_assert(back.map_name == "GM Drums" and back.category == "Drums" and back.author == "Peter",
		"REQ-009: name, category and author round-trip")
	_assert(back.pitches() == PackedInt32Array([36, 38]), "REQ-009: entries round-trip")
	_assert(back.get_name(36) == "Kick" and back.get_name(38) == "Snare", "REQ-009: names round-trip")
	_assert(back.get_color(36).to_html(false) == "cc4444", "REQ-009: colours round-trip")

	_assert(NoteMap.from_json(null).is_empty(), "from_json on junk gives an empty map")

	var copy := map.duplicate_map()
	copy.set_entry(36, "Kick 2", Color.GREEN)
	_assert(map.get_name(36) == "Kick", "duplicate_map is a deep copy")


# --- library ---------------------------------------------------------------

func _test_library_roundtrip() -> void:
	var gm := NoteMap.new("GM Drums", "Drums", "Peter")
	gm.set_entry(36, "Kick", Color.RED)
	gm.set_entry(38, "Snare", Color.BLUE)
	var kit := NoteMap.new("My Kit", "Kits", "Someone Else")
	kit.set_entry(60, "Bell", Color.GREEN)

	_assert(_library.save_map(gm), "REQ-009: saving a new map succeeds")
	_assert(_library.save_map(kit), "REQ-009: saving a second map succeeds")
	_assert(_library.exists("GM Drums"), "REQ-009: a saved map exists in the library")

	_assert(not _library.save_map(gm), "REQ-009: saving over an existing name is refused")
	_assert(_library.save_map(gm, true), "REQ-009: overwrite: true saves anyway")

	var listed: Array = _library.list()
	var names := []
	for m in listed:
		names.append(m.map_name)
	_assert(names == ["GM Drums", "My Kit"], "REQ-010: list() returns both maps sorted: %s" % str(names))
	_assert(listed[0].category == "Drums" and listed[0].author == "Peter",
		"REQ-010: list() carries category and author")

	var loaded = _library.load_map("GM Drums")
	_assert(loaded != null, "REQ-010: load_map finds a saved map")
	_assert(loaded.pitches() == PackedInt32Array([36, 38]), "REQ-010: loaded entries match what was saved")
	_assert(loaded.get_name(38) == "Snare", "REQ-010: loaded names match")

	_assert(_library.load_map("Nothing Here") == null, "load_map on a missing name gives null")
	_assert(not _library.save_map(NoteMap.new()), "an unnamed map is refused")


# --- Auto maps -------------------------------------------------------------

## DeviceInstance of a fake built-in device, registered so the id resolves.
func _device(ch: Object, device_id: String, title: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
		registry._devices[device_id] = device
	return _device_instance_script.new(device, ch.id, 0)


## Instrument channel with a Drum Machine holding pads named `pad_names`.
## Returns {channel, drum, pads}.
func _drum(project: Object, pad_names: Array) -> Dictionary:
	var ch: Object = project.create_instrument_track("Drums").channel
	var drum := _device(ch, _aux.DRUM_MACHINE_ID, "Drum Machine")
	ch.add_device(drum)
	var pads: Array = []
	for n in pad_names:
		var pad := _device(ch, "sonara.builtin.polysynth", "PolySynth")
		pad.name = n
		ch.add_device(pad, -1, drum)
		pads.append(pad)
	return {"channel": ch, "drum": drum, "pads": pads}


func _test_auto_map() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["Kick", "Snare"])
	var ch: Object = d.channel
	d.pads[0].set_slot_note(36)
	d.pads[1].set_slot_note(38)
	project.get_channel_by_id(d.pads[0].return_channel_id).set_color(Color.RED)
	project.get_channel_by_id(d.pads[1].return_channel_id).set_color(Color.BLUE)

	var map = _resolver.effective_map(ch)
	_assert(map.pitches() == PackedInt32Array([36, 38]),
		"REQ-002: Auto map has one entry per pad: %s" % str(map.pitches()))
	_assert(map.get_name(36) == "Kick" and map.get_name(38) == "Snare",
		"REQ-002: entry names come from the pad devices")
	_assert(map.get_color(36).is_equal_approx(Color.RED), "REQ-002: entry colour is the pad return's colour")
	_assert(map.get_color(38).is_equal_approx(Color.BLUE), "REQ-002: second entry colour too")
	_assert(_resolver.has_auto_source(ch), "REQ-002: a Drum Machine is an Auto source")

	# An empty pad (its device removed, its return kept) contributes no entry.
	ch.remove_device_instance(d.pads[1])
	var after = _resolver.effective_map(ch)
	_assert(after.pitches() == PackedInt32Array([36]),
		"REQ-002: an empty pad is unmapped: %s" % str(after.pitches()))

	# The map follows a pad moved to another note (REQ-004's row move).
	d.pads[0].set_slot_note(40)
	var moved = _resolver.effective_map(ch)
	_assert(moved.pitches() == PackedInt32Array([40]) and moved.get_name(40) == "Kick",
		"REQ-004: the entry follows the pad to its new note")

	# for_track resolves through the track's default channel.
	var track: Object = project.get_channel_paired_track(ch)
	var by_track = _resolver.for_track(project, track)
	_assert(by_track.pitches() == PackedInt32Array([40]), "REQ-025: for_track resolves the track's channel")


func _test_auto_map_no_source() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	ch.add_device(_device(ch, "sonara.builtin.polysynth", "PolySynth"))
	_assert(ch.note_map_mode == _channel_script.NoteMapMode.AUTO, "REQ-001: a new channel defaults to Auto")
	_assert(_resolver.effective_map(ch).is_empty(), "REQ-003: Auto with only a PolySynth is empty")
	_assert(not _resolver.has_auto_source(ch), "REQ-003: a PolySynth is not an Auto source")
	_assert(_resolver.for_track(null, null).is_empty(), "for_track tolerates nulls")


# --- channel assignment and persistence ------------------------------------

func _test_channel_assignment() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Strings").channel

	var map := NoteMap.new("Kontakt Strings", "Keyswitches", "Peter")
	map.set_entry(24, "Sustain", Color.RED)
	map.set_entry(26, "Staccato", Color.BLUE)

	var emitted := [0]
	ch.note_map_changed.connect(func(): emitted[0] += 1)
	ch.set_note_map(map)
	_assert(ch.note_map_mode == _channel_script.NoteMapMode.NAMED, "REQ-001: set_note_map switches to NAMED")
	_assert(emitted[0] == 1, "set_note_map emits note_map_changed once")

	# REQ-001: save and reload the project, the named map comes back identical.
	var reloaded := _reload(project)
	var ch2: Object = _channel_named(reloaded, "Strings")
	_assert(ch2 != null, "the channel survives the round trip")
	_assert(ch2.note_map_mode == _channel_script.NoteMapMode.NAMED, "REQ-001: the assignment round-trips")
	_assert(ch2.note_map != null and ch2.note_map.map_name == "Kontakt Strings",
		"REQ-001: the named map's name round-trips")
	_assert(ch2.note_map.pitches() == PackedInt32Array([24, 26]), "REQ-001: its entries round-trip")
	_assert(ch2.note_map.get_name(26) == "Staccato", "REQ-001: its names round-trip")

	ch.set_note_map_mode(_channel_script.NoteMapMode.NONE)
	_assert(_resolver.effective_map(ch).is_empty(), "None resolves to an empty map")
	ch.set_note_map(null)
	_assert(ch.note_map == null and ch.note_map_mode == _channel_script.NoteMapMode.NONE,
		"set_note_map(null) clears the embedded map")


func _test_older_projects() -> void:
	# A channel dictionary written before note maps existed.
	var data := {"id": 7, "name": "Old", "channel_type": "INSTRUMENT"}
	var ch: Object = _channel_script.from_json(data)
	_assert(ch.note_map_mode == _channel_script.NoteMapMode.AUTO, "REQ-012: a channel with no keys loads as Auto")
	_assert(ch.note_map == null, "REQ-012: and with no embedded map")
	_assert(ch.drum_view == -1, "REQ-028: and with Drum View unset")


func _test_project_is_self_contained() -> void:
	var gm := NoteMap.new("GM Drums", "Drums", "Peter")
	gm.set_entry(36, "Kick", Color.RED)
	gm.set_entry(38, "Snare", Color.BLUE)
	_library.save_map(gm, true)

	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	ch.set_note_map(_library.load_map("GM Drums"))
	_assert(ch.note_map.pitches() == PackedInt32Array([36, 38]), "REQ-010: loading assigns the library entries")

	# Delete the library entry and reload the project: the map is still there.
	_assert(_library.delete_map("GM Drums"), "the library entry is deleted")
	_assert(_library.load_map("GM Drums") == null, "and really gone")
	var reloaded := _reload(project)
	var ch2: Object = _channel_named(reloaded, "Drums")
	_assert(ch2.note_map != null and ch2.note_map.pitches() == PackedInt32Array([36, 38]),
		"REQ-011: the project keeps its own copy after the library entry is deleted")
	_assert(ch2.note_map.get_name(36) == "Kick", "REQ-011: with its names intact")


func _test_edits_stay_in_the_project() -> void:
	var gm := NoteMap.new("GM Drums", "Drums", "Peter")
	gm.set_entry(36, "Kick", Color.RED)
	_library.save_map(gm, true)

	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	ch.set_note_map(_library.load_map("GM Drums"))

	# Edit the channel's copy.
	var edited = ch.note_map.duplicate_map()
	edited.set_entry(36, "Kick 2", Color.GREEN)
	ch.set_note_map(edited)
	_assert(ch.note_map.get_name(36) == "Kick 2", "the channel's copy is edited")
	_assert(_library.load_map("GM Drums").get_name(36) == "Kick",
		"REQ-026: the library entry is untouched until an explicit save")


func _test_save_auto_map_as_named() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["Kick", "Snare"])
	var ch: Object = d.channel
	d.pads[0].set_slot_note(36)
	d.pads[1].set_slot_note(38)

	# "Save as…" takes the resolved Auto map, names it and stores it.
	var as_named = _resolver.effective_map(ch).duplicate_map()
	as_named.map_name = "My Kit"
	as_named.category = "Kits"
	as_named.author = "Peter"
	_assert(_library.save_map(as_named, true), "REQ-027: an Auto map saves as a named map")

	var from_library = _library.load_map("My Kit")
	_assert(from_library.pitches() == PackedInt32Array([36, 38]), "REQ-027: with the Auto map's entries")
	_assert(from_library.get_name(38) == "Snare", "REQ-027: and its names")
	_assert(ch.note_map_mode == _channel_script.NoteMapMode.AUTO, "the save alone does not move the channel")

	# Saving then adopts the map, which is what ClipEditor._on_note_map_saved does,
	# so the user carries on editing the map they just named instead of the
	# read-only Auto one.
	ch.set_note_map(_library.load_map("My Kit"))
	_assert(ch.note_map_mode == _channel_script.NoteMapMode.NAMED,
		"REQ-027: the channel switches to the map it just saved")
	_assert(ch.note_map.map_name == "My Kit", "REQ-027: under that name")
	_assert(ch.note_map.pitches() == PackedInt32Array([36, 38]), "REQ-027: with the same entries")


func _test_drum_view_preference() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["Kick"])
	var drum_ch: Object = d.channel
	var synth_ch: Object = project.create_instrument_track("Synth").channel
	synth_ch.add_device(_device(synth_ch, "sonara.builtin.polysynth", "PolySynth"))

	_assert(drum_ch.drum_view == -1 and synth_ch.drum_view == -1, "REQ-028: neither channel has a stored choice")
	_assert(_resolver.wants_drum_view(drum_ch), "REQ-028: a new Drum Machine channel opens in Drum View")
	_assert(not _resolver.wants_drum_view(synth_ch), "REQ-028: a new PolySynth channel opens in the piano roll")

	# Toggle the Drum Machine channel to the piano roll and reload.
	drum_ch.set_drum_view(0)
	_assert(not _resolver.wants_drum_view(drum_ch), "REQ-028: an explicit choice wins over the default")
	var reloaded := _reload(project)
	var drum_ch2: Object = _channel_named(reloaded, "Drums")
	_assert(drum_ch2.drum_view == 0, "REQ-028: the choice round-trips through the project")
	_assert(not _resolver.wants_drum_view(drum_ch2), "REQ-028: and still resolves to the piano roll")


# --- watcher ---------------------------------------------------------------

func _test_watcher() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["Kick", "Snare"])
	var ch: Object = d.channel
	d.pads[0].set_slot_note(36)
	d.pads[1].set_slot_note(38)

	var watcher: Object = _watcher_script.new()
	var fires := [0]
	watcher.changed.connect(func(): fires[0] += 1)
	watcher.bind(ch)

	# Two signals in one frame (rename + recolour) coalesce into one emit.
	d.pads[0].set_name("Kick 2")
	project.get_channel_by_id(d.pads[0].return_channel_id).set_color(Color.GREEN)
	await process_frame
	await process_frame
	_assert(fires[0] == 1, "REQ-004: several changes in a frame coalesce to one emit (got %d)" % fires[0])
	_assert(_resolver.effective_map(ch).get_name(36) == "Kick 2", "REQ-004: the rename reaches the map")

	# A removed pad's signals are dropped: emitting on it must not fire again.
	var removed: Object = d.pads[1]
	ch.remove_device_instance(removed)
	await process_frame
	await process_frame
	var after_removal: int = fires[0]
	removed.set_name("Ghost")
	await process_frame
	await process_frame
	_assert(fires[0] == after_removal, "REQ-004: a removed pad no longer notifies (got %d, want %d)" % [fires[0], after_removal])

	# Unbinding stops everything.
	watcher.bind(null)
	d.pads[0].set_name("Kick 3")
	await process_frame
	await process_frame
	_assert(fires[0] == after_removal, "unbinding disconnects every signal")


# --- helpers ---------------------------------------------------------------

## Save a project to JSON and load it back, the way a .sonara round trip does.
func _reload(project: Object) -> Object:
	var text := JSON.stringify(project.to_json())
	return _project_script.from_json(JSON.parse_string(text))


func _channel_named(project: Object, name_value: String) -> Object:
	for ch in project.channels:
		if ch.name == name_value:
			return ch
	return null


func _remove_scratch() -> void:
	if _scratch.is_empty() or not DirAccess.dir_exists_absolute(_scratch):
		return
	for f in DirAccess.get_files_at(_scratch):
		DirAccess.remove_absolute(_scratch.path_join(f))
	DirAccess.remove_absolute(_scratch)
