# test_linked_delete.gd
# Headless tests for TrackDeleteCommand / ChannelDeleteCommand: deleting a track removes its
# linked channel (and the reverse), and undo/redo restores ids, devices, routing and nesting.
#
# Project, Track, DeviceInstance and the commands reference autoloads (AudioEngineOSC) by bare
# name, so — like test_fuzzy_resolve.gd — they are loaded with load() inside run_tests() instead
# of being named by class.
# Run: godot --headless --path Godot -s tests/test_linked_delete.gd -- --test
extends TestBase

var _project_script: GDScript
var _track_delete: GDScript
var _channel_delete: GDScript
var _history_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript


func suite_name() -> String:
	return "Linked track/channel delete tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_delete = load("res://history/commands/TrackDeleteCommand.gd")
	_channel_delete = load("res://history/commands/ChannelDeleteCommand.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_test_track_delete_removes_channel()
	_test_channel_delete_removes_track()
	_test_route_to_deleted_bus_restored()
	_test_group_with_children()
	_test_shared_channel_kept()
	_test_drum_pad_returns()


## New DeviceInstance of a fake built-in device type `device_id` on `ch`.
func _device(ch: Object, device_id: String, title: String) -> Object:
	var device: Object = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	return _device_instance_script.new(device, ch.id, 0)


## Instrument track with one device on its channel. Returns {track, channel, device}.
func _instrument(project: Object, track_name: String) -> Dictionary:
	var result: Dictionary = project.create_instrument_track(track_name)
	var ch: Object = result.channel
	var inst := _device(ch, "sonara.builtin.polysynth", "PolySynth")
	ch.add_device(inst)
	result["device"] = inst
	return result


## Stable description of every track/channel field a delete + undo must preserve.
func _state(project: Object) -> String:
	var lines: PackedStringArray = []
	for ch in project.channels:
		var sends: PackedStringArray = []
		for s in ch.send_channels:
			sends.append(str(s.target_channel_id))
		var devs: PackedStringArray = []
		for d in ch.devices:
			devs.append(d.id)
		lines.append("ch %d '%s' out=%d parent=%d kids=%s sends=%s devs=%s" % [
			ch.id, ch.name, ch.output_channel_id, ch.parent_channel_id,
			str(ch.child_channel_ids), ",".join(sends), ",".join(devs)
		])
	for t in project.tracks:
		lines.append("tr %d '%s' ch=%d parent=%d order=%d kids=%s" % [
			t.id, t.name, t.default_channel_id, t.parent_track_id, t.order, str(t.child_track_ids)
		])
	return "\n".join(lines)


## Execute `cmd`, then check undo → redo → undo returns to the starting state each time.
func _run_do_undo_twice(project: Object, cmd: Object, label: String, check_removed: Callable) -> void:
	var hist: Object = _history_script.new()
	var before := _state(project)
	hist.execute(cmd)
	check_removed.call()
	hist.undo()
	var after := _state(project)
	_assert(after == before, "%s: undo restores state" % label if after == before
		else "%s: undo restores state\n--- before\n%s\n--- after\n%s" % [label, before, after])
	hist.redo()
	check_removed.call()
	hist.undo()
	_assert(_state(project) == before, "%s: second undo restores state" % label)


func _test_track_delete_removes_channel() -> void:
	var project: Object = _project_script.new()
	var drums := _instrument(project, "Drums")
	var bass := _instrument(project, "Bass")
	var track: Object = drums.track
	var ch: Object = drums.channel
	var cmd: Object = _track_delete.new(project, track)
	_run_do_undo_twice(project, cmd, "track delete", func() -> void:
		_assert(project.get_track_by_id(track.id) == null, "track removed")
		_assert(project.get_channel_by_id(ch.id) == null, "linked channel removed")
		_assert(project.get_channel_by_id(bass.channel.id) != null, "other channel untouched")
		_assert(cmd.name == "Delete Track and Channel", "command named for both: %s" % cmd.name)
		_assert(not project.get_master_channel().routed_tracks.has(track), "deleted track not registered on Master")
	)
	_assert(project.get_channel_by_id(ch.id) == ch, "undo re-adds the same Channel object")
	_assert(project.get_track_by_id(track.id) == track, "undo re-adds the same Track object")
	_assert(ch.devices.size() == 1 and ch.devices[0] == drums.device, "device kept on restored channel")
	_assert(track.get_linked_channel() == ch and ch.routed_tracks.has(track), "track relinked to its channel")


func _test_channel_delete_removes_track() -> void:
	var project: Object = _project_script.new()
	var keys := _instrument(project, "Keys")
	var track: Object = keys.track
	var ch: Object = keys.channel
	var cmd: Object = _channel_delete.new(project, ch)
	_run_do_undo_twice(project, cmd, "channel delete", func() -> void:
		_assert(project.get_channel_by_id(ch.id) == null, "channel removed")
		_assert(project.get_track_by_id(track.id) == null, "linked track removed")
		_assert(cmd.name == "Delete Channel and Track", "command named for both: %s" % cmd.name)
	)
	_assert(track.default_channel_id == ch.id, "track still points at its channel")

	var master_cmd: Object = _channel_delete.new(project, project.get_master_channel())
	master_cmd.do()
	_assert(project.get_master_channel() != null and project.get_master_channel().id == 1, "Master is never deleted")


func _test_route_to_deleted_bus_restored() -> void:
	var project: Object = _project_script.new()
	var lead := _instrument(project, "Lead")
	var bus: Object = project.create_bus_channel("FX")
	var folder: Dictionary = project.create_folder_track("Stack", true)
	var lead_ch: Object = lead.channel
	lead_ch.set_route(folder.channel.id)
	lead_ch.add_send(bus.id, -6.0)
	var other := _instrument(project, "Pad")
	other.channel.set_route(bus.id)
	# A trackless bus isn't in the track layout snapshot, so only the channel snapshot restores it.
	var sub_bus: Object = project.create_bus_channel("FX Sub")
	sub_bus.set_route(bus.id)

	var cmd: Object = _channel_delete.new(project, bus)
	_run_do_undo_twice(project, cmd, "bus delete", func() -> void:
		_assert(project.get_channel_by_id(bus.id) == null, "bus removed")
		_assert(other.channel.output_channel_id == 1, "channel routed to bus falls back to Master")
		_assert(sub_bus.output_channel_id == 1, "bus routed to bus falls back to Master")
		_assert(cmd.name == "Delete Channel", "bus without track is just 'Delete Channel': %s" % cmd.name)
	)
	_assert(other.channel.output_channel_id == bus.id, "route back to the bus after undo")
	_assert(sub_bus.output_channel_id == bus.id, "trackless bus routed back to the bus after undo")
	_assert(lead_ch.get_send(bus.id) != null, "send to bus still present")

	var folder_cmd: Object = _track_delete.new(project, folder.track)
	_run_do_undo_twice(project, folder_cmd, "folder bus delete", func() -> void:
		_assert(project.get_channel_by_id(folder.channel.id) == null, "folder bus removed with folder")
		_assert(lead_ch.output_channel_id == 1, "channel routed to folder bus falls back to Master")
	)
	_assert(lead_ch.output_channel_id == folder.channel.id, "route back to folder bus after undo")


func _test_group_with_children() -> void:
	var project: Object = _project_script.new()
	var group: Dictionary = project.create_group_track("Band")
	var a := _instrument(project, "Guitar")
	var b := _instrument(project, "Organ")
	var after := _instrument(project, "After")
	project.add_track_to_folder(a.track.id, group.track.id)
	project.add_track_to_folder(b.track.id, group.track.id)
	_assert(a.channel.parent_channel_id == group.channel.id, "setup: child channel nested in group")

	var cmd: Object = _track_delete.new(project, group.track)
	_run_do_undo_twice(project, cmd, "group delete", func() -> void:
		for ch in [group.channel, a.channel, b.channel]:
			_assert(project.get_channel_by_id(ch.id) == null, "channel %s removed" % ch.name)
		for t in [group.track, a.track, b.track]:
			_assert(project.get_track_by_id(t.id) == null, "track %s removed" % t.name)
		_assert(project.get_channel_by_id(after.channel.id) != null, "sibling outside the group kept")
	)
	_assert(group.channel.child_channel_ids == [a.channel.id, b.channel.id], "group children restored in order")
	_assert(a.channel.output_channel_id == group.channel.id, "child still routed to group")

	var child_cmd: Object = _channel_delete.new(project, b.channel)
	_run_do_undo_twice(project, child_cmd, "nested child delete", func() -> void:
		_assert(project.get_track_by_id(b.track.id) == null, "nested child's track removed")
		_assert(not group.channel.child_channel_ids.has(b.channel.id), "child dropped from group")
		_assert(project.get_channel_by_id(group.channel.id) != null, "group kept")
	)


func _test_shared_channel_kept() -> void:
	var project: Object = _project_script.new()
	var first := _instrument(project, "Strings")
	var second: Object = project.create_track("Strings Div")
	second.type = 1  # Track.TrackType.INSTRUMENT
	second.default_channel_id = first.channel.id

	var cmd: Object = _track_delete.new(project, first.track)
	_run_do_undo_twice(project, cmd, "shared channel", func() -> void:
		_assert(project.get_track_by_id(first.track.id) == null, "track removed")
		_assert(project.get_channel_by_id(first.channel.id) == first.channel, "channel used by another track kept")
		_assert(cmd.name == "Delete Track", "named 'Delete Track' when no channel removed: %s" % cmd.name)
		_assert(cmd.removed_channels().is_empty(), "no channels reported removed")
	)


func _test_drum_pad_returns() -> void:
	var project: Object = _project_script.new()
	var result: Dictionary = project.create_instrument_track("Drums")
	var ch: Object = result.channel
	var drum := _device(ch, "sonara.builtin.drum_machine", "Drum Machine")
	ch.add_device(drum)
	var pad := _device(ch, "sonara.builtin.polysynth", "PolySynth")
	pad.name = "KICK"
	ch.add_device(pad, -1, drum)
	var ret: Object = project.get_channel_by_id(pad.return_channel_id)
	_assert(ret != null and ret.is_aux_return() and ret.parent_channel_id == ch.id, "setup: pad return nested under drum channel")
	var ret_track: Object = project.get_channel_paired_track(ret)

	var cmd: Object = _channel_delete.new(project, ch)
	_run_do_undo_twice(project, cmd, "drum channel delete", func() -> void:
		_assert(project.get_channel_by_id(ret.id) == null, "pad return channel removed with drum channel")
		_assert(ret_track == null or project.get_track_by_id(ret_track.id) == null, "pad return track removed")
	)
	_assert(project.get_channel_by_id(pad.return_channel_id) == ret, "pad still points at its restored return")

	# Only the return track: its aux channel goes, the drum channel stays.
	if ret_track:
		var ret_cmd: Object = _track_delete.new(project, ret_track)
		_run_do_undo_twice(project, ret_cmd, "pad return track delete", func() -> void:
			_assert(project.get_channel_by_id(ret.id) == null, "return channel removed with its track")
			_assert(project.get_channel_by_id(ch.id) == ch, "drum channel kept")
		)
