# Chain panel view: the scene's slot button and Mix/Volume knobs bind whether the device arrives
# before or after the view enters the tree, follow parameter changes, and a missing parameter
# hides its knob.
# Run: godot --headless --path Godot -s tests/test_chain_view.gd -- --test
extends TestBase

const SCENE := "res://devices/builtin/chain/ChainDefaultView.tscn"
const P_VOLUME := 0
const P_MIX := 1

var _device_script: GDScript
var _instance_script: GDScript


func suite_name() -> String:
	return "Chain view"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	await _test_bind_before_tree()
	await _test_bind_after_tree()
	await _test_missing_mix_hides_knob()


func _make_instance(with_mix := true) -> Object:
	var device: Object = _device_script.new("sonara.builtin.chain", "Chain", _device_script.DeviceCategory.Effect)
	var volume := DeviceParameter.new(P_VOLUME, "Volume", "dB")
	volume.min_value = -60.0
	volume.max_value = 6.0
	volume.default_value = 0.0
	device.add_parameter(volume)
	if with_mix:
		var mix := DeviceParameter.new(P_MIX, "Mix", "%")
		mix.min_value = 0.0
		mix.max_value = 100.0
		mix.default_value = 100.0
		device.add_parameter(mix)
	return _instance_script.new(device, 2, 0)


func _mount(inst: Object, bind_first: bool) -> Control:
	var view: Control = load(SCENE).instantiate()
	if bind_first:
		view.bind_to_device(inst)
	root.add_child(view)
	if not bind_first:
		view.bind_to_device(inst)
	await process_frame
	return view


func _check_bound(view: Control, inst: Object, label: String) -> void:
	_assert(view.slot_button != null and view.volume_knob != null and view.mix_knob != null, "%s: scene nodes resolve" % label)
	_assert(view.volume_knob.visible and view.mix_knob.visible, "%s: both knobs shown" % label)
	_assert(view.volume_knob.text == "VOL" and view.mix_knob.text == "MIX", "%s: captions come from the scene" % label)
	_assert(is_equal_approx(view.mix_knob.knob.value, inst.get_parameter_normalized(P_MIX)), "%s: Mix knob starts at the parameter" % label)
	inst.set_parameter_normalized(P_MIX, 0.25)
	_assert(is_equal_approx(view.mix_knob.knob.value, 0.25), "%s: Mix knob follows the parameter" % label)
	inst.set_parameter_normalized(P_VOLUME, 0.5)
	_assert(is_equal_approx(view.volume_knob.knob.value, 0.5), "%s: Volume knob follows the parameter" % label)


func _test_bind_before_tree() -> void:
	var inst := _make_instance()
	var view := await _mount(inst, true)
	_check_bound(view, inst, "bound before tree")
	view.queue_free()
	await process_frame


func _test_bind_after_tree() -> void:
	var inst := _make_instance()
	var view := await _mount(inst, false)
	_check_bound(view, inst, "bound after tree")
	view.queue_free()
	await process_frame


func _test_missing_mix_hides_knob() -> void:
	var view := await _mount(_make_instance(false), true)
	_assert(not view.mix_knob.visible, "no Mix parameter hides the Mix knob")
	_assert(view.volume_knob.visible, "Volume knob still shown")
	view.queue_free()
	await process_frame
