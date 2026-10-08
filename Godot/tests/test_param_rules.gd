# test_param_rules.gd
# Spec 027 (REQ-037): ParamRules says which parameters don't apply in the device's current state,
# and the Simple View shows those controls disabled, updating on every parameter change.
# Run: godot --headless --path Godot -s tests/test_param_rules.gd -- --test
#
# Scripts that reach autoloads are loaded at runtime, not referenced as types.
extends TestBase

const PANEL_SCENE := "res://devices/device_lane/DevicePanel.tscn"
const ROOTS := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
const SCALE_TYPES := ["Major", "Natural Minor", "Harmonic Minor", "Melodic Minor", "Dorian", "Phrygian", "Lydian", "Mixolydian", "Locrian", "Major Pentatonic", "Minor Pentatonic", "Blues"]

var _rules: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _project_script: GDScript
var _param_script: GDScript
var _project: Object = null


func suite_name() -> String:
	return "Parameter rules"


func run_tests() -> void:
	_rules = load("res://devices/simple_view/ParamRules.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_project = _project_script.new()
	load("res://devices/simple_view/SimpleLayoutStore.gd").clear_cache()
	_test_transpose_rules()
	_test_later_wave_rules()
	await _test_simple_view_disables_controls()


## Disabled ids of `device_id` for `values` (param id → normalized; missing = 0).
func _disabled(device_id: String, values: Dictionary) -> Array:
	return _rules.disabled_ids("sonara.builtin." + device_id, func(id: int) -> float: return float(values.get(id, 0.0)))


func _test_transpose_rules() -> void:
	_assert(_disabled("transpose", {10: 0.0}) == [11, 12], "Scale Off disables Root and Scale Type")
	_assert(_disabled("transpose", {10: 0.5}) == [11, 12], "Scale Follow Project disables Root and Scale Type")
	_assert(_disabled("transpose", {10: 1.0}).is_empty(), "Scale Custom enables Root and Scale Type")
	_assert(_disabled("delay", {}).is_empty() and _disabled("unknown", {}).is_empty(), "devices without rules disable nothing")


func _test_later_wave_rules() -> void:
	_assert(_disabled("chord", {1: 0.0}) == [2], "Chord: Strum Direction disabled while Strum is 0")
	_assert(_disabled("chord", {1: 0.2}).is_empty(), "Chord: Strum Direction enabled while Strum is above 0")
	_assert(_disabled("note_echo", {1: 1.0}) == [3], "Note Echo: Sync on disables Time ms")
	_assert(_disabled("note_echo", {1: 0.0}) == [2], "Note Echo: Sync off disables Time Rate")
	_assert(_disabled("note_length", {1: 1.0}) == [3], "Note Length: Sync on disables Length ms")
	_assert(_disabled("note_length", {1: 0.0}) == [2], "Note Length: Sync off disables Length Rate")
	_assert(_disabled("arpeggiator", {2: 0.0}) == [3], "Arpeggiator: Ping-Pong off disables Repeat Ends")
	_assert(_disabled("arpeggiator", {2: 1.0}).is_empty(), "Arpeggiator: Ping-Pong on enables Repeat Ends")


func _enum_param(id: int, name: String, values: Array) -> Object:
	var p: Object = _param_script.new(id, name)
	p.param_type = "enum"
	p.enum_values.assign(values)
	p.default_value = 0.0
	return p


func _find_controls(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child.has_method("get_param_ids") and not child.is_queued_for_deletion():
			out.append(child)
		_find_controls(child, out)


func _test_simple_view_disables_controls() -> void:
	var device: Object = _device_script.new("sonara.builtin.transpose", "Transpose",
		_device_script.DeviceCategory.NoteEffect, _device_script.DeviceType.BuiltIn)
	var semitones: Object = _param_script.new(0, "Semitones")
	semitones.min_value = -48.0
	semitones.max_value = 48.0
	semitones.default_value = 0.0
	device.add_parameter(semitones)
	device.add_parameter(_enum_param(10, "Scale", ["Off", "Follow Project", "Custom"]))
	device.add_parameter(_enum_param(11, "Root", ROOTS))
	device.add_parameter(_enum_param(12, "Scale Type", SCALE_TYPES))
	root.get_node("AssetService").device_registry._devices[device.device_id] = device
	var channel: Object = _project.create_instrument_track("Transpose").channel
	var instance: Object = _device_instance_script.new(device, channel.id, 0)

	var panel: Control = load(PANEL_SCENE).instantiate()
	root.add_child(panel)
	panel.position = Vector2(200, 200)
	await panel.bind_to_device(instance)
	for _i in 4:
		await process_frame
	var controls: Array = []
	_find_controls(panel, controls)
	var by_param := {}
	for control in controls:
		for id in control.get_param_ids():
			by_param[id] = control
	_assert(by_param.has(0) and by_param.has(10) and by_param.has(11) and by_param.has(12), "the Simple View shows all four Transpose parameters")
	if by_param.size() >= 4:
		_assert(not by_param[0].is_disabled() and not by_param[10].is_disabled(), "Semitones and Scale stay enabled")
		_assert(by_param[11].is_disabled() and by_param[12].is_disabled(), "Root and Scale Type start disabled (Scale Off)")
		instance.set_parameter_normalized(10, 1.0)
		_assert(not by_param[11].is_disabled() and not by_param[12].is_disabled(), "Scale Custom enables Root and Scale Type")
		instance.set_parameter_normalized(10, 0.0)
		_assert(by_param[11].is_disabled() and by_param[12].is_disabled(), "Scale Off disables them again")
	panel.queue_free()
	# The view generated and saved a layout for this real device id; don't leave it in the user's config.
	var store: GDScript = load("res://devices/simple_view/SimpleLayoutStore.gd")
	DirAccess.remove_absolute(store.path_for(device.device_id))
	store.clear_cache()
