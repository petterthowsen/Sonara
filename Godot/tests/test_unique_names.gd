# test_unique_names.gd
# Headless tests for project-unique track/channel names (ProjectNaming via Project):
# suffixing on create and rename, linked pairs sharing a name, reserved names, undo/redo
# stability, deduping on load, and drum pad returns (`KICK 2`) that don't loop.
#
# Project, Track, DeviceInstance and the commands reference autoloads (AudioEngineOSC) by bare
# name, so — like test_linked_delete.gd — they are loaded with load() inside run_tests() instead
# of being named by class.
# Run: godot --headless --path Godot -s tests/test_unique_names.gd -- --test
extends TestBase

var _project_script: GDScript
var _track_delete: GDScript
var _track_create: GDScript
var _link_bus: GDScript
var _property_command: GDScript
var _history_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _aux_return_sync: GDScript


func suite_name() -> String:
	return "Unique track/channel name tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_delete = load("res://history/commands/TrackDeleteCommand.gd")
	_track_create = load("res://history/commands/TrackCreateCommand.gd")
	_link_bus = load("res://history/commands/TrackLinkBusCommand.gd")
	_property_command = load("res://history/commands/PropertyCommand.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_aux_return_sync = load("res://data/AuxReturnSync.gd")
	_test_duplicate_create_suffixed()
	_test_rename_bus_to_track_name_undo_stable()
	_test_linked_pair_shares_name()
	_test_reserved_names()
	_test_from_json_dedupes()
	_test_undo_delete_after_recreate()
	_test_create_command_redo_keeps_name()
	_test_folder_bus_keeps_folder_name()
	_test_find_by_name()
	_test_pad_returns_do_not_loop()


## New DeviceInstance of a fake built-in device type `device_id` on `ch`.
func _device(ch: Object, device_id: String, title: String) -> Object:
	var device: Object = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	return _device_instance_script.new(device, ch.id, 0)


## Rename `target` through an undoable PropertyCommand the way TrackItem does: record the final name.
func _rename(hist: Object, target: Object, desired: String) -> void:
	var final_name: String = target.unique_name_for(desired)
	hist.execute(_property_command.new("Rename", target, "set_name", target.name, final_name))


func _test_duplicate_create_suffixed() -> void:
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("Drums")
	var b: Dictionary = project.create_instrument_track("Drums")
	var c: Dictionary = project.create_audio_track("drums")
	_assert(a.track.name == "Drums" and a.channel.name == "Drums", "first pair keeps 'Drums'")
	_assert(b.track.name == "Drums 2" and b.channel.name == "Drums 2", "second pair is 'Drums 2': %s / %s" % [b.track.name, b.channel.name])
	_assert(c.track.name == "drums 3" and c.channel.name == "drums 3", "case-insensitive: %s" % c.track.name)
	var bus: Object = project.create_bus_channel("Drums")
	_assert(bus.name == "Drums 4", "bus after pairs is 'Drums 4': %s" % bus.name)
	var folder: Dictionary = project.create_folder_track("Drums")
	_assert(folder.track.name == "Drums 5", "plain folder is suffixed too: %s" % folder.track.name)


func _test_rename_bus_to_track_name_undo_stable() -> void:
	var project: Object = _project_script.new()
	project.create_instrument_track("Keys")
	var bus: Object = project.create_bus_channel("Bus")
	var hist: Object = _history_script.new()
	_rename(hist, bus, "Keys")
	_assert(bus.name == "Keys 2", "bus renamed to a track's name gets a suffix: %s" % bus.name)
	hist.undo()
	_assert(bus.name == "Bus", "undo restores 'Bus': %s" % bus.name)
	hist.redo()
	_assert(bus.name == "Keys 2", "redo reapplies 'Keys 2': %s" % bus.name)
	hist.undo()
	hist.redo()
	_assert(bus.name == "Keys 2", "second redo is stable: %s" % bus.name)

	var track: Object = project.create_instrument_track("Lead").track
	_rename(hist, track, "keys")
	_assert(track.name == "keys 3" and track.get_linked_channel().name == "keys 3", "track rename suffixed with its channel: %s" % track.name)
	hist.undo()
	_assert(track.name == "Lead" and track.get_linked_channel().name == "Lead", "track rename undo")
	hist.redo()
	_assert(track.name == "keys 3", "track rename redo stable: %s" % track.name)


func _test_linked_pair_shares_name() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Drums")
	pair.track.name = "Beats"
	_assert(pair.track.name == "Beats" and pair.channel.name == "Beats", "track rename renames its channel without a suffix")
	pair.channel.set_name("Drums")
	_assert(pair.channel.name == "Drums" and pair.track.name == "Drums", "channel rename renames its track without a suffix")
	pair.track.set_name("DRUMS")
	_assert(pair.track.name == "DRUMS" and pair.channel.name == "DRUMS", "case-only rename of a pair is allowed")
	var group: Dictionary = project.create_group_track("Band")
	_assert(group.track.name == "Band" and group.channel.name == "Band", "group pair shares its name")
	group.channel.set_name("Band")
	_assert(group.channel.name == "Band", "renaming a group channel to its own name keeps it")


func _test_reserved_names() -> void:
	var project: Object = _project_script.new()
	_assert(project.create_instrument_track("Master").track.name == "Master 2", "'Master' refused for a user track")
	_assert(project.create_bus_channel("none").name == "none 2", "'none' refused")
	_assert(project.create_instrument_track("hardware out").track.name == "hardware out (2)", "'hardware out' refused")
	_assert(project.create_bus_channel("Hardware Out 3").name == "Hardware Out 3 (2)", "'Hardware Out N' refused")
	var t: Object = project.create_track("Solo")
	t.name = "MASTER"
	_assert(t.name == "MASTER 3", "rename to 'MASTER' refused (after 'Master 2'): %s" % t.name)
	var master: Object = project.get_master_channel()
	master.set_name("Master")
	_assert(master.name == "Master", "channel 1 may keep 'Master'")


func _test_from_json_dedupes() -> void:
	var source: Object = _project_script.new()
	var a: Dictionary = source.create_instrument_track("Drums")
	var b: Dictionary = source.create_instrument_track("Bass")
	var bus: Object = source.create_bus_channel("FX")
	var data: Dictionary = source.to_json()
	# Force duplicates the way an old save could contain them.
	for ch_data in data.channels:
		if int(ch_data.id) == b.channel.id or int(ch_data.id) == bus.id:
			ch_data["name"] = "Drums"
	for tr_data in data.tracks:
		if int(tr_data.id) == b.track.id:
			tr_data["name"] = "Drums"

	var project: Object = _project_script.from_json(data)
	var names := {}
	var unique := true
	for ch in project.channels:
		var key: String = ch.name.to_lower()
		var partner: Object = project.get_channel_paired_track(ch)
		if names.has(key):
			unique = false
		names[key] = true
		if partner:
			_assert(partner.default_channel_id == ch.id and partner.name == ch.name, "loaded pair %d stays linked with one name: '%s' / '%s'" % [ch.id, partner.name, ch.name])
	for t in project.tracks:
		if project.get_channel_by_id(t.default_channel_id) == null or t.default_channel_id <= 1:
			unique = unique and not names.has(t.name.to_lower())
	_assert(unique, "channel names unique after load")
	_assert(project.get_channel_by_id(a.channel.id).name == "Drums", "lowest channel id keeps 'Drums'")
	_assert(project.get_channel_by_id(b.channel.id).name == "Drums 2", "second 'Drums' pair renamed: %s" % project.get_channel_by_id(b.channel.id).name)
	_assert(project.get_track_by_id(b.track.id).name == "Drums 2", "its track follows")
	_assert(project.get_channel_by_id(bus.id).name == "Drums 3", "duplicate bus renamed: %s" % project.get_channel_by_id(bus.id).name)


func _test_undo_delete_after_recreate() -> void:
	var project: Object = _project_script.new()
	var old: Dictionary = project.create_instrument_track("Drums")
	var hist: Object = _history_script.new()
	hist.execute(_track_delete.new(project, old.track))
	var fresh: Dictionary = project.create_instrument_track("Drums")
	_assert(fresh.track.name == "Drums", "new track reuses the freed name")
	hist.undo()
	_assert(project.get_track_by_id(old.track.id) == old.track and project.get_channel_by_id(old.channel.id) == old.channel, "undo re-adds the same objects")
	_assert(old.track.name == "Drums 2" and old.channel.name == "Drums 2", "re-added pair is 'Drums 2': %s / %s" % [old.track.name, old.channel.name])
	_assert(old.track.get_linked_channel() == old.channel, "re-added pair still linked")
	_assert(fresh.track.name == "Drums" and fresh.channel.name == "Drums", "new pair keeps 'Drums'")


func _test_create_command_redo_keeps_name() -> void:
	var project: Object = _project_script.new()
	var hist: Object = _history_script.new()
	var cmd: Object = _track_create.new(project, "instrument", "Piano")
	hist.execute(cmd)
	var track: Object = cmd.track
	var ch: Object = cmd.channel
	hist.undo()
	hist.redo()
	_assert(track.name == "Piano" and ch.name == "Piano", "redo of create keeps 'Piano': %s / %s" % [track.name, ch.name])
	_assert(track.default_channel_id == ch.id and track.get_linked_channel() == ch, "redo of create keeps the pair linked")


func _test_folder_bus_keeps_folder_name() -> void:
	var project: Object = _project_script.new()
	var folder: Dictionary = project.create_folder_track("Strings")
	var bus: Object = project.create_and_link_folder_bus(folder.track)
	_assert(bus.name == "Strings" and folder.track.name == "Strings", "linking a new bus keeps the folder name: %s / %s" % [folder.track.name, bus.name])

	var other: Dictionary = project.create_folder_track("Brass")
	var hist: Object = _history_script.new()
	var cmd: Object = _link_bus.new(project, other.track, null, true)
	hist.execute(cmd)
	_assert(cmd.bus != null and cmd.bus.name == "Brass", "link to new bus keeps 'Brass'")
	hist.undo()
	hist.redo()
	_assert(other.track.name == "Brass" and cmd.bus.name == "Brass", "redo of link-new-bus keeps 'Brass': %s / %s" % [other.track.name, cmd.bus.name])


func _test_find_by_name() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Drums")
	var bus: Object = project.create_bus_channel("Verb")
	var folder: Dictionary = project.create_folder_track("Stack")
	var hit: Dictionary = project.find_by_name("drums")
	_assert(hit.track == pair.track and hit.channel == pair.channel, "pair found by name")
	hit = project.find_by_name("VERB")
	_assert(hit.track == null and hit.channel == bus, "bus found as channel only")
	hit = project.find_by_name("Stack")
	_assert(hit.track == folder.track and hit.channel == null, "plain folder found as track only")
	hit = project.find_by_name("nothing")
	_assert(hit.track == null and hit.channel == null, "unknown name finds nothing")


func _test_pad_returns_do_not_loop() -> void:
	var project: Object = _project_script.new()
	var pads: Array = []
	for i in 2:
		var ch: Object = project.create_instrument_track("Drums").channel
		var drum := _device(ch, "sonara.builtin.drum_machine", "Drum Machine")
		ch.add_device(drum)
		var pad := _device(ch, "sonara.builtin.polysynth", "PolySynth")
		pad.name = "KICK"
		ch.add_device(pad, -1, drum)
		pads.append(pad)
	var first: Object = project.get_channel_by_id(pads[0].return_channel_id)
	var second: Object = project.get_channel_by_id(pads[1].return_channel_id)
	_assert(first != null and second != null, "setup: both pads have returns")
	if first == null or second == null:
		return
	_assert(first.name == "KICK", "first return is 'KICK': %s" % first.name)
	_assert(second.name == "KICK 2", "second return is 'KICK 2': %s" % second.name)
	_assert(project.get_channel_paired_track(second) == null, "pad returns have no timeline track")

	var renames := [0]
	var count_rename := func(_n: String) -> void: renames[0] += 1
	second.name_changed.connect(count_rename)
	_aux_return_sync.ensure_all(project)
	pads[1].name_changed.emit("KICK")
	_assert(second.name == "KICK 2" and first.name == "KICK", "re-sync keeps 'KICK' / 'KICK 2'")
	_assert(renames[0] == 0, "re-sync doesn't rename the return (no loop): %d renames" % renames[0])

	pads[1].set_name("SNARE")
	_assert(second.name == "SNARE", "pad rename renames its return: %s" % second.name)
	pads[1].set_name("KICK")
	_assert(second.name == "KICK 2", "renaming back to a taken name settles on 'KICK 2': %s" % second.name)
	_assert(renames[0] == 2, "exactly one rename per pad rename: %d" % renames[0])
	# A lambda still connected when the test script is freed crashes Godot at exit.
	second.name_changed.disconnect(count_rename)
