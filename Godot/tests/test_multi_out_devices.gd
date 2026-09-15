# test_multi_out_devices.gd
# Headless tests for the multi-out device contract (docs/specs/001-multi-out-devices):
# one nested return per extra output, drum pads as outputs, no timeline tracks, source lookup,
# engine aux map, detach/undo keeping the same return channels, lone-return delete refusal,
# and loading projects.
#
# Project, DeviceInstance and the commands reference autoloads (AudioEngineOSC) by bare name, so
# they are loaded with load() inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_multi_out_devices.gd -- --test
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _aux: GDScript
var _history_script: GDScript
var _device_remove: GDScript
var _channel_delete: GDScript
var _track_delete: GDScript
var _pad_lane: GDScript
var _macro: GDScript


func suite_name() -> String:
	return "Multi-out device tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_aux = load("res://data/AuxReturnSync.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_device_remove = load("res://history/commands/DeviceRemoveCommand.gd")
	_channel_delete = load("res://history/commands/ChannelDeleteCommand.gd")
	_track_delete = load("res://history/commands/TrackDeleteCommand.gd")
	_pad_lane = load("res://devices/PadLane.gd")
	_macro = load("res://history/commands/MacroCommand.gd")
	_test_plugin_returns()
	_test_drum_pad_order()
	_test_no_tracks()
	_test_source_lookup()
	_test_aux_map_sent()
	_test_remove_source()
	_test_undo_pad_remove_restores_return()
	_test_undo_drum_remove_restores_all()
	_test_undo_plugin_remove_restores_all()
	_test_two_plugins_do_not_share_returns()
	_test_plugin_return_not_deleted()
	_test_delete_pad_return_removes_pad()
	_test_pad_lane_lists_pad_first()
	_test_pad_lane_remove_empties_pad()
	_test_pad_lane_front_is_pad()
	_test_pad_lane_append()
	_test_empty_pad_adopted_by_note()
	_test_pad_follows_note_change()
	_test_parent_delete_with_plugin_returns()
	_test_load_keeps_returns()


## DeviceInstance of a fake built-in device with `out_channels` audio outputs. The Device is
## registered with `AssetService.device_registry` so saved projects can load it back.
func _device(ch: Object, device_id: String, title: String, out_channels: int = 2) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	if out_channels != 2:
		device_id = "%s_%d" % [device_id, out_channels]
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
		device.audio_out_channels = out_channels
		registry._devices[device_id] = device
	return _device_instance_script.new(device, ch.id, 0)


## Instrument channel with a Drum Machine holding pads named `pad_names`. Returns {channel, drum, pads}.
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


## Names of `ch`'s mixer children in fold-out order.
func _child_names(project: Object, ch: Object) -> Array:
	var out: Array = []
	for child in project.get_channel_children(ch):
		out.append(child.name)
	return out


## {bus_index: target_id} of the last /channel/{id}/aux_out sends queued in AudioEngineOSC.
func _sent_aux_map(osc: Node, channel_id: int) -> Dictionary:
	var map := {}
	for item in osc._pending_sends:
		if item.address == "/channel/%d/aux_out" % channel_id:
			map[int(item.args[0])] = int(item.args[1])
	return map


func _test_plugin_returns() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var plugin := _device(ch, "test.multi_out", "Multi", 8)
	ch.add_device(plugin)
	var kids: Array = project.get_channel_children(ch)
	_assert(kids.size() == 3, "REQ-001: 8 outs → 3 returns, got %d" % kids.size())
	_assert(_child_names(project, ch) == ["Out 2", "Out 3", "Out 4"], "REQ-004: plugin returns named Out N: %s" % str(_child_names(project, ch)))
	for i in kids.size():
		_assert(kids[i].output_channel_id == ch.id and kids[i].parent_channel_id == ch.id, "REQ-001: return %d locked to parent" % i)
		_assert(kids[i].aux_bus_index == i, "REQ-001: return %d on bus %d, got %d" % [i, i, kids[i].aux_bus_index])

	var stereo := _device(ch, "test.stereo", "Stereo", 2)
	ch.add_device(stereo)
	_assert(project.get_channel_children(ch).size() == 3, "stereo device adds no returns")


func _test_drum_pad_order() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK", "SNARE", "HAT"])
	var ch: Object = d.channel
	_assert(_child_names(project, ch) == ["KICK", "SNARE", "HAT"], "REQ-002: pad returns in pad order: %s" % str(_child_names(project, ch)))
	ch.move_device(2, 0, d.drum)
	_assert(_child_names(project, ch) == ["HAT", "KICK", "SNARE"], "REQ-002: move reorders returns: %s" % str(_child_names(project, ch)))
	ch.remove_device_instance(d.pads[1])
	_assert(_child_names(project, ch) == ["HAT", "KICK", "SNARE"], "REQ-007: SNARE pad emptied, its return stays: %s" % str(_child_names(project, ch)))
	var indices: Array = []
	for child in project.get_channel_children(ch):
		indices.append(child.aux_bus_index)
	_assert(indices == [0, 1, -1], "REQ-002: bus indices reindexed, empty pad has no bus: %s" % str(indices))

	# Inserting a pad in the middle on a new note must not steal a neighbour's return.
	var clap := _device(ch, "sonara.builtin.polysynth", "PolySynth")
	clap.name = "CLAP"
	clap.slot_note = 50
	ch.add_device(clap, 1, d.drum)
	_assert(_child_names(project, ch) == ["HAT", "CLAP", "KICK", "SNARE"], "REQ-002: inserted pad gets its own return: %s" % str(_child_names(project, ch)))
	var hat_ret: Object = project.get_channel_by_id(d.pads[2].return_channel_id)
	var kick_ret: Object = project.get_channel_by_id(d.pads[0].return_channel_id)
	_assert(hat_ret.name == "HAT" and kick_ret.name == "KICK" and kick_ret.aux_bus_index == 2, "REQ-002: neighbours keep their returns")


func _test_no_tracks() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK", "SNARE"])
	var ch: Object = project.create_instrument_track("Synth").channel
	var tracks_before: int = project.tracks.size()
	ch.add_device(_device(ch, "test.multi_out", "Multi", 8))
	d.channel.add_device(_device(d.channel, "sonara.builtin.polysynth", "PolySynth"), -1, d.drum)
	_assert(project.tracks.size() == tracks_before, "REQ-003: returns create no tracks (%d → %d)" % [tracks_before, project.tracks.size()])
	for ret in project.get_channel_children(d.channel) + project.get_channel_children(ch):
		_assert(project.get_channel_paired_track(ret) == null, "REQ-003: '%s' has no track" % ret.name)


func _test_source_lookup() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK", "SNARE"])
	for i in d.pads.size():
		var ret: Object = project.get_channel_by_id(d.pads[i].return_channel_id)
		var src: Dictionary = _aux.get_source(project, ret)
		_assert(src.get("device") == d.drum and src.get("index") == i, "REQ-005: pad return %d resolves to drum/%d" % [i, i])
		_assert(_aux.get_return_channel(project, d.drum, i) == ret, "REQ-005: drum out %d → its return" % i)
	var ch: Object = project.create_instrument_track("Synth").channel
	var plugin := _device(ch, "test.multi_out", "Multi", 6)
	ch.add_device(plugin)
	for i in 2:
		var ret: Object = _aux.get_return_channel(project, plugin, i)
		var src: Dictionary = _aux.get_source(project, ret)
		_assert(ret != null and src.get("device") == plugin and src.get("index") == i, "REQ-005: plugin out %d round-trips" % i)
	_assert(_aux.get_source(project, ch).is_empty(), "REQ-005: a top-level channel has no source")


func _test_aux_map_sent() -> void:
	var osc: Node = root.get_node_or_null("AudioEngineOSC")
	_assert(osc != null, "setup: AudioEngineOSC autoload present")
	if osc == null:
		return
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK", "SNARE", "HAT"])
	var ch: Object = d.channel
	ch._is_connected = true
	osc._pending_sends.clear()
	_aux.sync_aux_map_to_engine(ch)
	var kick: int = d.pads[0].return_channel_id
	var snare: int = d.pads[1].return_channel_id
	var hat: int = d.pads[2].return_channel_id
	_assert(_sent_aux_map(osc, ch.id) == {0: kick, 1: snare, 2: hat}, "REQ-006: full map sent: %s" % str(_sent_aux_map(osc, ch.id)))

	osc._pending_sends.clear()
	ch.remove_device_instance(d.pads[1])
	var map := _sent_aux_map(osc, ch.id)
	_assert(map.get(0) == kick and map.get(1) == hat and map.get(2) == 0, "REQ-006: removal remaps HAT to bus 1 and clears bus 2: %s" % str(map))
	ch._is_connected = false


func _test_remove_source() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK", "SNARE"])
	var ch: Object = d.channel
	var kick_id: int = d.pads[0].return_channel_id
	var snare_id: int = d.pads[1].return_channel_id
	ch.remove_device_instance(d.pads[0])
	_assert(project.get_channel_by_id(kick_id) != null and project.get_channel_by_id(snare_id) != null, "REQ-007: removing a pad device keeps its return")
	ch.remove_device_instance(d.drum)
	_assert(project.get_channel_by_id(snare_id) == null and project.get_channel_by_id(kick_id) == null and project.get_channel_children(ch).is_empty(), "REQ-007: removing the drum removes every pad return, empty ones too")

	var synth: Object = project.create_instrument_track("Synth").channel
	var plugin := _device(synth, "test.multi_out", "Multi", 6)
	synth.add_device(plugin)
	synth.remove_device_instance(plugin)
	_assert(project.get_channel_children(synth).is_empty(), "REQ-007: removing a plugin removes its returns")


func _test_undo_pad_remove_restores_return() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK", "SNARE"])
	var ch: Object = d.channel
	var ret: Object = project.get_channel_by_id(d.pads[0].return_channel_id)
	ret.set_volume(-6.0)
	var fx := _device(ret, "sonara.builtin.delay", "Delay")
	ret.add_device(fx)
	var channel_count: int = project.channels.size()

	var hist: Object = _history_script.new()
	hist.execute(_device_remove.new(ch, d.pads[0]))
	_assert(project.get_channel_by_id(ret.id) == ret and ret.devices.size() == 1, "REQ-016: removing the pad device keeps the KICK return and its devices")
	_assert(ret.aux_bus_index == -1 and _aux.get_pad_device(ret) == null, "REQ-016: KICK pad is empty")
	hist.undo()
	_assert(_aux.get_pad_device(ret) == d.pads[0] and ret.aux_bus_index == 0, "REQ-008: undo puts the pad device back on the KICK return")
	_assert(project.channels.size() == channel_count, "REQ-008: no extra return created (%d vs %d)" % [project.channels.size(), channel_count])
	_assert(is_equal_approx(ret.volume, -6.0), "REQ-008: volume kept: %s" % ret.volume)
	_assert(_child_names(project, ch) == ["KICK", "SNARE"], "REQ-008: order kept: %s" % str(_child_names(project, ch)))


func _test_undo_drum_remove_restores_all() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK", "SNARE"])
	var ch: Object = d.channel
	var ids: Array = [d.pads[0].return_channel_id, d.pads[1].return_channel_id]
	ch.remove_device_instance(d.pads[0])  # KICK becomes an empty pad; it must come back too.
	var hist: Object = _history_script.new()
	hist.execute(_device_remove.new(ch, d.drum))
	_assert(project.get_channel_children(ch).is_empty(), "setup: drum returns removed")
	hist.undo()
	var restored: Array = []
	for child in project.get_channel_children(ch):
		restored.append(child.id)
	_assert(restored == ids, "REQ-008: undo of drum removal restores both returns with their ids: %s vs %s" % [str(restored), str(ids)])


func _test_undo_plugin_remove_restores_all() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var plugin := _device(ch, "test.multi_out", "Multi", 6)
	ch.add_device(plugin)
	var ids: Array = plugin.return_channel_ids.duplicate()
	var hist: Object = _history_script.new()
	hist.execute(_device_remove.new(ch, plugin))
	hist.undo()
	var restored: Array = []
	for child in project.get_channel_children(ch):
		restored.append(child.id)
	_assert(restored == ids, "REQ-008: undo of plugin removal restores both returns: %s vs %s" % [str(restored), str(ids)])


func _test_two_plugins_do_not_share_returns() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var a := _device(ch, "test.multi_out", "Multi", 4)
	var b := _device(ch, "test.multi_out", "Multi", 4)
	ch.add_device(a)
	ch.add_device(b)
	_assert(a.return_channel_ids[0] != b.return_channel_ids[0], "second multi-out device gets its own return")


func _test_plugin_return_not_deleted() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var plugin := _device(ch, "test.multi_out", "Multi", 4)
	ch.add_device(plugin)
	var ret: Object = project.get_channel_by_id(plugin.return_channel_ids[0])
	var cmd: Object = _channel_delete.new(project, ret)
	cmd.do()
	_assert(project.get_channel_by_id(ret.id) == ret, "REQ-009: a plugin return can't be deleted on its own")


func _test_delete_pad_return_removes_pad() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK", "SNARE"])
	var ret: Object = project.get_channel_by_id(d.pads[0].return_channel_id)
	var hist: Object = _history_script.new()
	hist.execute(_channel_delete.new(project, ret))
	_assert(project.get_channel_by_id(ret.id) == null, "REQ-007: deleting the KICK return removes it")
	_assert(not d.drum.children.has(d.pads[0]) and d.drum.children.size() == 1, "REQ-007: deleting the KICK return removes the KICK pad device")
	hist.undo()
	_assert(project.get_channel_by_id(ret.id) == ret and _aux.get_pad_device(ret) == d.pads[0], "REQ-007: undo restores the pad and its return")
	_assert(_child_names(project, d.channel) == ["KICK", "SNARE"], "REQ-007: undo keeps order: %s" % str(_child_names(project, d.channel)))
	hist.redo()
	hist.undo()
	_assert(_aux.get_pad_device(ret) == d.pads[0] and ret.aux_bus_index == 0, "REQ-007: redo/undo stable")


## Names of the devices in `ret`'s pad lane.
func _lane_names(ret: Object) -> Array:
	var out: Array = []
	for dev in _pad_lane.devices(ret):
		out.append(dev.name)
	return out


## Apply a pad lane edit to `target` as one undo step on `hist`.
func _lane_edit(hist: Object, ret: Object, target: Array, has_pad: bool) -> void:
	# Typed like Array[DeviceInstance] without naming the class (it needs autoloads to compile).
	var typed := Array(target, TYPE_OBJECT, _device_instance_script.get_instance_base_type(), _device_instance_script)
	hist.execute(_macro.new("Lane", _pad_lane.commands(ret, typed, has_pad)))


func _test_pad_lane_lists_pad_first() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK"])
	var ret: Object = project.get_channel_by_id(d.pads[0].return_channel_id)
	var fx := _device(ret, "sonara.builtin.delay", "Delay")
	ret.add_device(fx)
	_assert(_pad_lane.is_pad_lane(ret), "REQ-015: pad return is a pad lane")
	_assert(_lane_names(ret) == ["KICK", "Delay"], "REQ-015: lane is [pad device][own devices]: %s" % str(_lane_names(ret)))
	_assert(not _pad_lane.is_pad_lane(d.channel), "REQ-015: the drum channel is not a pad lane")
	var synth: Object = project.create_instrument_track("Synth").channel
	var plugin := _device(synth, "test.multi_out", "Multi", 4)
	synth.add_device(plugin)
	_assert(not _pad_lane.is_pad_lane(project.get_channel_by_id(plugin.return_channel_ids[0])), "REQ-015: a plugin return is not a pad lane")


func _test_pad_lane_remove_empties_pad() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK"])
	var ret: Object = project.get_channel_by_id(d.pads[0].return_channel_id)
	var note: int = d.pads[0].slot_note
	ret.add_device(_device(ret, "sonara.builtin.delay", "Delay"))
	# The lane's context menu removes the pad device through its own channel/parent.
	d.channel.remove_device_instance(d.pads[0])
	_assert(d.drum.children.is_empty(), "REQ-016: no Drum Machine child on the pad note")
	_assert(project.get_channel_by_id(ret.id) == ret and ret.aux_pad_note == note, "REQ-016: KICK return stays on note %d" % note)
	_assert(_lane_names(ret) == ["Delay"], "REQ-016: lane shows the remaining devices: %s" % str(_lane_names(ret)))


func _test_pad_lane_front_is_pad() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK"])
	var ret: Object = project.get_channel_by_id(d.pads[0].return_channel_id)
	var sampler: Object = d.pads[0]
	var note: int = sampler.slot_note
	var delay := _device(ret, "sonara.builtin.delay", "Delay")
	ret.add_device(delay)
	var hist: Object = _history_script.new()

	# Sampler behind Delay: Delay plays the pad, Sampler becomes a return device.
	_lane_edit(hist, ret, [delay, sampler], true)
	_assert(_lane_names(ret) == ["Delay", "KICK"], "REQ-017: lane is [Delay][Sampler]: %s" % str(_lane_names(ret)))
	_assert(_aux.get_pad_device(ret) == delay and delay.slot_note == note and d.drum.children == [delay], "REQ-017: Delay is the pad device on note %d" % note)
	_assert(ret.devices.size() == 1 and ret.devices[0] == sampler, "REQ-017: Sampler is the return's first device")
	hist.undo()
	_assert(_lane_names(ret) == ["KICK", "Delay"] and _aux.get_pad_device(ret) == sampler and ret.devices == [delay], "REQ-017: undo restores [Sampler][Delay]: %s" % str(_lane_names(ret)))

	# Empty pad, new PolySynth at the front.
	d.channel.remove_device_instance(sampler)
	var poly := _device(d.channel, "sonara.builtin.polysynth", "PolySynth")
	var channels_before: int = project.channels.size()
	_lane_edit(hist, ret, [poly, delay], true)
	_assert(_aux.get_pad_device(ret) == poly and poly.slot_note == note, "REQ-017: PolySynth at the front plays the empty pad")
	_assert(project.channels.size() == channels_before and ret.aux_bus_index == 0, "REQ-019: it adopts the KICK return")
	_assert(ret.name == "KICK", "REQ-019: adopting doesn't rename the return: %s" % ret.name)
	hist.undo()
	_assert(_aux.get_pad_device(ret) == null and _lane_names(ret) == ["Delay"], "REQ-017: undo empties the pad again: %s" % str(_lane_names(ret)))
	_assert(project.get_channel_by_id(ret.id) == ret, "REQ-017: undo keeps the KICK return")

	# Adding at the front of an occupied pad pushes the old pad device onto the return.
	_lane_edit(hist, ret, [poly, delay], true)
	var eq := _device(d.channel, "sonara.builtin.eq", "EQ")
	_lane_edit(hist, ret, [eq, poly, delay], true)
	_assert(_aux.get_pad_device(ret) == eq and ret.devices == [poly, delay], "REQ-017: [EQ][PolySynth][Delay] with EQ as pad device: %s" % str(_lane_names(ret)))
	hist.undo()
	_assert(_aux.get_pad_device(ret) == poly and ret.devices == [delay], "REQ-017: undo restores [PolySynth][Delay]: %s" % str(_lane_names(ret)))


func _test_pad_lane_append() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK"])
	var ret: Object = project.get_channel_by_id(d.pads[0].return_channel_id)
	var delay := _device(ret, "sonara.builtin.delay", "Delay")
	var hist: Object = _history_script.new()
	_lane_edit(hist, ret, [d.pads[0], delay], true)
	_assert(ret.devices == [delay] and _aux.get_pad_device(ret) == d.pads[0], "REQ-018: appended Delay goes on the return channel")
	var comp := _device(ret, "sonara.builtin.comp", "Comp")
	_lane_edit(hist, ret, [d.pads[0], comp, delay], true)
	_assert(ret.devices == [comp, delay], "REQ-018: insert at lane index 1 → return index 0: %s" % str(_lane_names(ret)))
	_lane_edit(hist, ret, [d.pads[0], delay, comp], true)
	_assert(ret.devices == [delay, comp], "REQ-018: reorder within the return chain: %s" % str(_lane_names(ret)))
	hist.undo()
	_assert(ret.devices == [comp, delay], "REQ-018: undo reorder")


func _test_empty_pad_adopted_by_note() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK"])
	var ret: Object = project.get_channel_by_id(d.pads[0].return_channel_id)
	var note: int = d.pads[0].slot_note
	d.channel.remove_device_instance(d.pads[0])
	var channels_before: int = project.channels.size()
	var poly := _device(d.channel, "sonara.builtin.polysynth", "PolySynth")
	poly.slot_note = note
	d.channel.add_device(poly, -1, d.drum)
	_assert(project.channels.size() == channels_before, "REQ-019: no new channel for a device on an empty pad's note")
	_assert(poly.return_channel_id == ret.id and _aux.get_pad_device(ret) == poly, "REQ-019: PolySynth feeds the KICK return")


func _test_pad_follows_note_change() -> void:
	var project: Object = _project_script.new()
	var d := _drum(project, ["KICK"])
	var ret: Object = project.get_channel_by_id(d.pads[0].return_channel_id)
	d.pads[0].set_slot_note(60)
	_assert(ret.aux_pad_note == 60, "REQ-019: return follows its pad device to note 60: %d" % ret.aux_pad_note)
	d.channel.remove_device_instance(d.pads[0])
	var other := _device(d.channel, "sonara.builtin.polysynth", "PolySynth")
	other.slot_note = 36
	d.channel.add_device(other, -1, d.drum)
	_assert(other.return_channel_id != ret.id, "REQ-019: a device on the old note gets its own return")


func _test_parent_delete_with_plugin_returns() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	var ch: Object = pair.channel
	var plugin := _device(ch, "test.multi_out", "Multi", 6)
	ch.add_device(plugin)
	var ids: Array = plugin.return_channel_ids.duplicate()
	var hist: Object = _history_script.new()
	hist.execute(_track_delete.new(project, pair.track))
	for id in ids:
		_assert(project.get_channel_by_id(id) == null, "REQ-010: return %d removed with its parent" % id)
	hist.undo()
	for id in ids:
		var r: Object = project.get_channel_by_id(id)
		_assert(r != null and r.parent_channel_id == ch.id, "REQ-010: return %d restored under its parent" % id)
	_assert(_aux.get_source(project, project.get_channel_by_id(ids[0])).get("device") == plugin, "REQ-010: restored return still resolves to the plugin")


func _test_load_keeps_returns() -> void:
	var source: Object = _project_script.new()
	var d := _drum(source, ["KICK", "SNARE"])
	var kick: Object = source.get_channel_by_id(d.pads[0].return_channel_id)
	kick.set_volume(-3.0)
	var data: Dictionary = source.to_json()

	var project: Object = _project_script.from_json(data)
	var ch: Object = project.get_channel_by_id(d.channel.id)
	var kids: Array = project.get_channel_children(ch)
	_assert(ch.devices.size() == 1 and ch.devices[0].children.size() == 2, "setup: drum machine and pads loaded")
	_assert(kids.size() == 2, "REQ-011: exactly 2 pad returns after load, got %d" % kids.size())
	for i in kids.size():
		_assert(_aux.get_source(project, kids[i]).get("index") == i, "REQ-011: loaded return %d linked to its pad" % i)
	var loaded_kick: Object = project.get_channel_by_id(kick.id)
	_assert(loaded_kick != null and is_equal_approx(loaded_kick.volume, -3.0), "REQ-011: KICK return keeps id and volume")
	_assert(project.tracks.size() == source.tracks.size(), "REQ-011: load adds no tracks")

	var again: Object = _project_script.from_json(project.to_json())
	_assert(again.channels.size() == project.channels.size(), "REQ-011: save → load round trip adds no channels")

	# Older saves without return ids: the aux children are adopted, not duplicated.
	for ch_data in data.channels:
		for dev_data in ch_data.get("devices", []):
			for child_data in dev_data.get("children", []):
				child_data.erase("return_channel_id")
	var legacy: Object = _project_script.from_json(data)
	var legacy_ch: Object = legacy.get_channel_by_id(d.channel.id)
	_assert(legacy.get_channel_children(legacy_ch).size() == 2, "REQ-011: saves without return ids adopt existing returns")
	_assert(legacy_ch.devices[0].children[0].return_channel_id == kick.id, "REQ-011: adopted KICK return keeps its id")

	# A deleted return's pad gets a fresh one on load.
	var missing: Dictionary = source.to_json()
	missing.channels = missing.channels.filter(func(c: Dictionary) -> bool: return int(c.id) != kick.id)
	for c in missing.channels:
		if int(c.id) == d.channel.id:
			c.child_channel_ids = (c.child_channel_ids as Array).filter(func(id) -> bool: return int(id) != kick.id)
	var repaired: Object = _project_script.from_json(missing)
	var repaired_ch: Object = repaired.get_channel_by_id(d.channel.id)
	_assert(_child_names(repaired, repaired_ch) == ["KICK", "SNARE"], "REQ-011: missing return re-created in pad order: %s" % str(_child_names(repaired, repaired_ch)))
