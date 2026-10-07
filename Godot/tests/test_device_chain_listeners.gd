# test_device_chain_listeners.gd
# Headless tests that a device's OSC listeners follow it when siblings shift: inserting a device
# mid-chain, or removing one, moves the later devices to new positions, and engine echoes for the
# new position must reach the new device, not the one that used to sit there.
# Run: godot --headless --path Godot -s tests/test_device_chain_listeners.gd -- --test
#
# Project and DeviceInstance reference autoloads (AudioEngineOSC), so they are loaded with load().
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _osc: Node


func suite_name() -> String:
	return "Device chain listeners"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_osc = root.get_node_or_null("AudioEngineOSC")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	_test_insert_mid_chain()
	_test_remove_mid_chain()


func _fx(ch: Object, n: String, position := -1) -> Object:
	var device: Object = _device_script.new("test.fx." + n, n, _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	var inst: Object = _device_instance_script.new(device, ch.id, -1)
	ch.add_device(inst, position)
	return inst


## Deliver an engine echo for `/channel/{id}/device/{pos}/enabled`.
func _echo_enabled(ch: Object, pos: int, on: bool) -> void:
	_osc._on_osc_message_received("/channel/%d/device/%d/enabled" % [ch.id, pos], [1 if on else 0], 0)


func _listens(inst: Object, pos: int) -> bool:
	var addr := "/channel/%d/device/%d/enabled" % [inst.channel_id, pos]
	return _osc.listeners.has(addr) and _osc.listeners[addr].has(inst._on_enabled_received)


func _test_insert_mid_chain() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Hi Bass").channel
	ch._is_connected = true
	var synth := _fx(ch, "synth")
	var chorus := _fx(ch, "chorus")
	var phaser := _fx(ch, "phaser")
	for d in [synth, chorus, phaser]:
		d.connect_to_engine()

	var delay := _fx(ch, "delay", 1)
	_assert(delay.position == 1 and chorus.position == 2 and phaser.position == 3, "insert reindexes the chain")
	_assert(_listens(delay, 1) and not _listens(chorus, 1), "device/1 listener belongs to the inserted delay only")
	_assert(_listens(chorus, 2) and _listens(phaser, 3), "shifted devices listen at their new positions")
	_assert(not _listens(phaser, 2), "phaser dropped its old device/2 listener")

	_echo_enabled(ch, 1, false)
	_assert(not delay.enabled and chorus.enabled, "bypassing device/1 bypasses the delay, not the chorus")
	_echo_enabled(ch, 2, false)
	_assert(not chorus.enabled and phaser.enabled, "device/2 echo reaches the chorus")

	for d in ch.devices:
		d.disconnect_from_engine()
	ch._is_connected = false


func _test_remove_mid_chain() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Lead").channel
	ch._is_connected = true
	var synth := _fx(ch, "synth")
	var delay := _fx(ch, "delay")
	var chorus := _fx(ch, "chorus")
	for d in [synth, delay, chorus]:
		d.connect_to_engine()

	ch.remove_device(1)
	_assert(chorus.position == 1, "remove reindexes the chain")
	_assert(_listens(chorus, 1) and not _listens(chorus, 2), "chorus moved its listener to device/1")
	_assert(not _listens(delay, 1), "removed delay no longer listens")

	_echo_enabled(ch, 1, false)
	_assert(not chorus.enabled, "device/1 echo reaches the chorus after removal")

	for d in ch.devices:
		d.disconnect_from_engine()
	ch._is_connected = false
