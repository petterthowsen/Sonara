# test_drum_pad_strip.gd
# Headless tests for the Drum Machine pad strip (spec 020 phase 5): a mini UI for the primary
# pad's return channel. It follows the selection, edits that channel with undo, and is disabled
# for an empty pad.
# Run: godot --headless --path Godot -s tests/test_drum_pad_strip.gd -- --test
extends TestBase

const DRUM_ID := "sonara.builtin.drum_machine"
const CHAIN_ID := "sonara.builtin.chain"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _add_cmd: GDScript
var _history_util: GDScript


func suite_name() -> String:
	return "Drum pad strip"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true)
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	await _test_follows_primary()
	await _test_edits_reach_channel()
	await _test_empty_pad_disabled()


func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


func _pad(ch: Object, drum: Object, note: int) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.fx.%d" % note, _device_script.DeviceCategory.Effect), ch.id, -1)
	inst.slot_note = note
	var cmd: Object = _add_cmd.new(ch, inst, -1, drum)
	cmd.do()
	return cmd.device_instance


## A Drum Machine with pads on `notes` and its view in the tree.
func _setup(notes: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var drum: Object = _device_instance_script.new(_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true), ch.id, -1)
	ch.add_device(drum)
	var pads: Dictionary = {}
	for n in notes:
		pads[n] = _pad(ch, drum, n)
	var view: Control = (load("res://devices/builtin/DrumMachineDefaultView.tscn") as PackedScene).instantiate()
	root.add_child(view)
	view.bind_to_device(drum)
	await process_frame
	return {"project": project, "ch": ch, "drum": drum, "pads": pads, "view": view, "strip": view.get_node("Body/PadStrip")}


func _return_of(s: Dictionary, note: int) -> Object:
	return s.project.get_channel_by_id(s.pads[note].return_channel_id)


func _test_follows_primary() -> void:
	var s: Dictionary = await _setup([36, 38])
	var strip: Object = s.strip
	var kick: Object = _return_of(s, 36)
	var snare: Object = _return_of(s, 38)
	_assert(kick != null and snare != null and kick != snare, "each pad has its own return channel")
	_assert(strip.channel == null, "no pad selected: the strip is unbound")
	s.view._on_pad_activated(36, 0)
	await process_frame
	_assert(strip.channel == kick, "the strip binds to the primary pad's return channel")
	s.view._on_pad_activated(38, KEY_MASK_CTRL)
	await process_frame
	_assert(strip.channel == snare, "ctrl-click moves the strip to the new primary pad")
	# A pad added after the view binds gets its return after child_added; the strip still finds it.
	var tom: Object = _pad(s.ch, s.drum, 40)
	s.view._on_pad_activated(40, 0)
	await process_frame
	_assert(strip.channel != null and strip.channel.id == tom.return_channel_id, "a new pad's return is found")
	s.view._unbind()
	_assert(strip.channel == null, "unbinding the view unbinds the strip")
	s.view.queue_free()


func _test_edits_reach_channel() -> void:
	var s: Dictionary = await _setup([36])
	var strip: Object = s.strip
	var ret: Object = _return_of(s, 36)
	s.view._on_pad_activated(36, 0)
	await process_frame
	var recorded: Array = []
	_history_util.test_recorder = func(cmd: Object) -> void: recorded.append(cmd)

	var start_volume: float = ret.volume
	var meter: Object = strip.get_node("Meter")
	meter.volume_changed.emit(-12.0)
	_assert(is_equal_approx(ret.volume, -12.0), "the fader sets the return channel's volume")
	ret.set_volume(-3.0)
	_assert(is_equal_approx(meter.volume_db, -3.0), "the fader follows the channel")

	strip.get_node("SoloMute/Solo").toggled.emit(true)
	_assert(ret.solo, "solo reaches the return channel")
	strip.get_node("SoloMute/Mute").toggled.emit(true)
	_assert(ret.mute, "mute reaches the return channel")
	ret.set_mute(false)
	_assert(not strip.get_node("SoloMute/Mute").button_pressed, "the mute button follows the channel")

	var pan: Object = strip.get_node("Pan")
	_assert(pan.channel == ret, "the pan control is bound to the return channel")
	pan._on_single_slider_changed(-50.0)
	_assert(is_equal_approx(ret.pan, -0.5), "pan reaches the return channel")

	_assert(recorded.size() == 4, "volume, solo, mute and pan each record one undo step (got %d)" % recorded.size())
	for i in range(recorded.size() - 1, -1, -1):
		recorded[i].undo()
	_history_util.test_recorder = Callable()
	_assert(is_equal_approx(ret.pan, 0.0) and not ret.solo and is_equal_approx(ret.volume, start_volume), "undo restores the channel")

	ret.peak_updated.emit(0.5, 0.25, 0.1, 0.05)
	_assert(meter.max_peak_db > -7.0, "channel meters drive the strip's meter")
	s.view.queue_free()


func _test_empty_pad_disabled() -> void:
	var s: Dictionary = await _setup([36])
	var strip: Object = s.strip
	s.view._on_pad_activated(37, 0) # empty pad
	await process_frame
	_assert(strip.channel == null, "an empty pad leaves the strip unbound")
	_assert(strip.get_node("SoloMute/Solo").disabled and strip.get_node("SoloMute/Mute").disabled, "the strip is disabled for an empty pad")
	s.view._on_pad_activated(36, 0)
	await process_frame
	_assert(not strip.get_node("SoloMute/Solo").disabled, "selecting a filled pad enables the strip")
	s.view.queue_free()
