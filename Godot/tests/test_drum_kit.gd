# test_drum_kit.gd
# Headless test for the Drum Machine "Synth Kit" preset (spec 013, Phase 4 wrap-up): five pads on
# their GM notes, the two hats choking each other, and the open hat ringing longer than the closed one.
# Run: godot --headless --path Godot -s tests/test_drum_kit.gd -- --test
#
# DrumKit, DeviceInstance, Channel and Project reach autoloads, so they are loaded with load()
# inside run_tests (after TestBase's frame wait) instead of named at parse time.
extends TestBase

const DRUM_MACHINE_ID := "sonara.builtin.drum_machine"
const CHAIN_ID := "sonara.builtin.chain"
const KICK_ID := "sonara.builtin.kick"
const SNARE_ID := "sonara.builtin.snare"
const HAT_ID := "sonara.builtin.hat"
const CLAP_ID := "sonara.builtin.clap"
## Hat Decay parameter id (the same as the engine's table).
const HAT_DECAY := 11

var _project_script: GDScript
var _drum_kit: GDScript
var _device_script: GDScript
var _instance_script: GDScript
var _project: Object


func suite_name() -> String:
	return "Drum kit preset"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_drum_kit = load("res://data/DrumKit.gd")
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_test_synth_kit()


## Register a fake built-in Device with the AssetService registry (as /builtin/info would).
func _register(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


## The Hat device with its Decay parameter, so the preset can set it.
func _register_hat() -> Object:
	var device: Object = _register(HAT_ID, _device_script.DeviceCategory.Instrument)
	var decay := DeviceParameter.new(HAT_DECAY, "Decay", "s")
	decay.min_value = 0.01
	decay.max_value = 2.0
	decay.is_logarithmic = true
	decay.default_value = 0.06
	device.add_parameter(decay)
	return device


## The drum inside pad `pad` (its slot chain's first child), or `pad` itself.
func _drum(pad: Object) -> Object:
	return pad.children[0] if pad.children.size() > 0 else pad


func _test_synth_kit() -> void:
	_register(CHAIN_ID, _device_script.DeviceCategory.Effect)
	_register(DRUM_MACHINE_ID, _device_script.DeviceCategory.Instrument, true)
	_register(KICK_ID, _device_script.DeviceCategory.Instrument)
	_register(SNARE_ID, _device_script.DeviceCategory.Instrument)
	_register(CLAP_ID, _device_script.DeviceCategory.Instrument)
	_register_hat()

	var registry: Object = root.get_node("AssetService").device_registry
	_project = _project_script.new()
	var channel: Object = _project.create_instrument_track("Drums").channel
	var drum: Object = _instance_script.new(registry.get_device(DRUM_MACHINE_ID), channel.id, -1)
	channel.add_device(drum)

	var pads: Array = _drum_kit.apply(channel, drum, registry)
	_assert(pads.size() == 5, "five pads added (%d)" % pads.size())
	_assert(drum.children.size() == 5, "the drum machine has five pads (%d)" % drum.children.size())
	if drum.children.size() != 5:
		return

	var notes: Array = []
	var names: Array = []
	for child in drum.children:
		notes.append(child.slot_note)
		names.append(child.get_display_name())
	_assert(notes == [36, 38, 39, 42, 46], "GM notes 36/38/39/42/46 (%s)" % [notes])
	var closed_hat: Object = drum.children[3]
	var open_hat: Object = drum.children[4]
	_assert(Array(closed_hat.choke_targets) == [open_hat.id] and Array(open_hat.choke_targets) == [closed_hat.id],
		"the hats choke each other (%s, %s)" % [closed_hat.choke_targets, open_hat.choke_targets])
	for i in range(3):
		_assert(drum.children[i].choke_targets.is_empty() and drum.choked_by(drum.children[i]).is_empty(),
			"%s has no choke targets" % names[i])
	_assert(names == ["Kick", "Snare", "Clap", "Closed Hat", "Open Hat"], "pad names (%s)" % [names])

	# The two hats are the same device: the preset sets Decay so one is short and one rings.
	var closed: float = _drum(drum.children[3]).get_parameter_real(HAT_DECAY)
	var open: float = _drum(drum.children[4]).get_parameter_real(HAT_DECAY)
	_assert(closed > 0.0 and open > closed * 5.0,
		"open hat rings longer than the closed one (%.3f s vs %.3f s)" % [open, closed])
