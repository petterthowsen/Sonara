# test_drum_kit.gd
# Headless test for the Drum Machine "Synth Kit" preset (spec 013, Phase 4 wrap-up): 13 pads on
# their GM notes, the two hats choking each other, and the open hat ringing longer than the closed one.
# Spec 056 grew the kit to 13 pads (toms, crash, ride, cowbell, rimshot, shaker).
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
const RIMSHOT_ID := "sonara.builtin.rimshot"
const TOM_ID := "sonara.builtin.tom"
const CYMBAL_ID := "sonara.builtin.cymbal"
const COWBELL_ID := "sonara.builtin.cowbell"
const SHAKER_ID := "sonara.builtin.shaker"
## Hat Decay parameter id (the same as the engine's table; 11 is Metal).
const HAT_DECAY := 1
## Tom Tune, Cymbal Decay (the engine's tables).
const TOM_TUNE := 0
const CYMBAL_DECAY := 1

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


## A drum device with one real-valued parameter `id`, so the preset can set it.
func _register_with_param(device_id: String, id: int, name: String, unit: String, min_v: float, max_v: float, default_v: float) -> void:
	var device: Object = _register(device_id, _device_script.DeviceCategory.Instrument)
	var param := DeviceParameter.new(id, name, unit)
	param.min_value = min_v
	param.max_value = max_v
	param.is_logarithmic = true
	param.default_value = default_v
	device.add_parameter(param)


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
	_register(RIMSHOT_ID, _device_script.DeviceCategory.Instrument)
	_register(COWBELL_ID, _device_script.DeviceCategory.Instrument)
	_register(SHAKER_ID, _device_script.DeviceCategory.Instrument)
	_register_with_param(TOM_ID, TOM_TUNE, "Tune", "Hz", 40.0, 500.0, 110.0)
	_register_with_param(CYMBAL_ID, CYMBAL_DECAY, "Decay", "s", 0.2, 8.0, 1.8)

	var registry: Object = root.get_node("AssetService").device_registry
	_project = _project_script.new()
	var channel: Object = _project.create_instrument_track("Drums").channel
	var drum: Object = _instance_script.new(registry.get_device(DRUM_MACHINE_ID), channel.id, -1)
	channel.add_device(drum)

	var pads: Array = _drum_kit.apply(channel, drum, registry)
	var kit_notes := [36, 37, 38, 39, 42, 46, 45, 48, 50, 49, 51, 56, 70]
	var kit_names := ["Kick", "Rimshot", "Snare", "Clap", "Closed Hat", "Open Hat", "Low Tom", "Mid Tom",
		"High Tom", "Crash", "Ride", "Cowbell", "Shaker"]
	var count := kit_notes.size()
	_assert(pads.size() == count, "%d pads added (%d)" % [count, pads.size()])
	_assert(drum.children.size() == count, "the drum machine has %d pads (%d)" % [count, drum.children.size()])
	if drum.children.size() != count:
		return

	var notes: Array = []
	var names: Array = []
	for child in drum.children:
		notes.append(child.slot_note)
		names.append(child.get_display_name())
	_assert(notes == kit_notes, "GM notes in kit order (%s)" % [notes])
	_assert(names == kit_names, "pad names (%s)" % [names])
	var closed_hat: Object = drum.children[4]
	var open_hat: Object = drum.children[5]
	_assert(Array(closed_hat.choke_targets) == [open_hat.id] and Array(open_hat.choke_targets) == [closed_hat.id],
		"the hats choke each other (%s, %s)" % [closed_hat.choke_targets, open_hat.choke_targets])
	for i in range(count):
		if i == 4 or i == 5:
			continue
		_assert(drum.children[i].choke_targets.is_empty() and drum.choked_by(drum.children[i]).is_empty(),
			"%s has no choke targets" % names[i])

	# The two hats are the same device: the preset sets Decay so one is short and one rings.
	var closed: float = _drum(closed_hat).get_parameter_real(HAT_DECAY)
	var open: float = _drum(open_hat).get_parameter_real(HAT_DECAY)
	_assert(absf(closed - 0.06) < 0.002 and absf(open - 0.6) < 0.02,
		"hat Decay is set on ID 1 (%.3f s, %.3f s)" % [closed, open])
	_assert(closed > 0.0 and open > closed * 5.0,
		"open hat rings longer than the closed one (%.3f s vs %.3f s)" % [open, closed])

	# The toms differ in Tune and the ride rings longer than the crash.
	var low_tune: float = _drum(drum.children[6]).get_parameter_real(TOM_TUNE)
	var high_tune: float = _drum(drum.children[8]).get_parameter_real(TOM_TUNE)
	_assert(absf(low_tune - 90.0) < 1.0 and absf(high_tune - 180.0) < 2.0,
		"low and high tom Tune (%.1f Hz, %.1f Hz)" % [low_tune, high_tune])
	var crash_decay: float = _drum(drum.children[9]).get_parameter_real(CYMBAL_DECAY)
	var ride_decay: float = _drum(drum.children[10]).get_parameter_real(CYMBAL_DECAY)
	_assert(absf(ride_decay - 4.0) < 0.1 and ride_decay > crash_decay * 2.0,
		"ride Decay is 4 s, longer than the crash (%.2f s vs %.2f s)" % [ride_decay, crash_decay])
