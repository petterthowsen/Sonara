# test_simple_view_controls.gd
# Simple View control kinds backed by shared components (spec 015 Phase 5): `segmented` builds a
# SegmentedControl, `fader` builds a Fader, and HorSlider draws optional scale marks.
# Run: godot --headless --path Godot -s tests/test_simple_view_controls.gd -- --test
#
# Scripts that reach autoloads are loaded at runtime, not referenced as types.
extends TestBase

const CONTROL_SCENE := "res://devices/simple_view/SimpleControl.tscn"
const GAIN := 0
const STYLE := 1

var _device_script: GDScript
var _device_instance_script: GDScript
var _project_script: GDScript
var _param_script: GDScript
var _project: Object = null


func suite_name() -> String:
	return "Simple View control tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_project = _project_script.new()

	_test_kinds()
	await _test_segmented_uses_segmented_control()
	await _test_fader_binds_the_parameter()
	await _test_hslider_scale_marks()


func _instance() -> Object:
	var device: Object = _device_script.new("sonara.builtin.test_view_controls", "Test",
		_device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	var gain: Object = _param_script.new(GAIN, "Gain", "dB")
	gain.min_value = -12.0
	gain.max_value = 12.0
	gain.default_value = 0.0
	device.add_parameter(gain)
	var style: Object = _param_script.new(STYLE, "Style")
	style.param_type = "enum"
	style.enum_values.assign(["Clean", "Glue", "Punch", "Opto"])
	style.default_value = 0.0
	device.add_parameter(style)
	root.get_node("AssetService").device_registry._devices[device.device_id] = device
	var channel: Object = _project.create_instrument_track("View Controls").channel
	return _device_instance_script.new(device, channel.id, 0)


func _control(instance: Object, kind: String, param_id: int) -> Control:
	var control: Control = load(CONTROL_SCENE).instantiate()
	control.custom_minimum_size = Vector2(240, 120)
	root.add_child(control)
	control.position = Vector2(200, 200)
	control.size = Vector2(240, 120)
	control.bind(instance, {"kind": kind, "params": [param_id], "rect": [0, 0, 1, 1]})
	await process_frame
	return control


func _test_kinds() -> void:
	_assert(SimpleControlKinds.is_valid(SimpleControlKinds.FADER), "fader is a valid kind")
	_assert(SimpleControlKinds.footprint(SimpleControlKinds.FADER) == Vector2i(1, 3), "fader footprint is 1x3")


func _test_segmented_uses_segmented_control() -> void:
	var instance: Object = _instance()
	var control := await _control(instance, SimpleControlKinds.SEGMENTED, STYLE)
	var seg = control._inner
	_assert(seg is SegmentedControl, "segmented builds a SegmentedControl")
	if seg is SegmentedControl:
		_assert(seg.item_count() == 4, "one segment per enum value")
		seg.selected = 2
		_assert(is_equal_approx(instance.get_parameter_normalized(STYLE), 2.0 / 3.0), "picking a segment commits its normalized value")
		instance.set_parameter_normalized(STYLE, 1.0)
		control.refresh()
		_assert(seg.selected == 3, "refresh selects the segment without a click (%d)" % seg.selected)
	control.queue_free()


func _test_fader_binds_the_parameter() -> void:
	var instance: Object = _instance()
	var control := await _control(instance, SimpleControlKinds.FADER, GAIN)
	var fader = control._inner
	_assert(fader is Fader, "fader builds a Fader")
	if fader is Fader:
		_assert(is_equal_approx(fader.value, 0.5), "starts at the parameter's normalized value (%.2f)" % fader.value)
		fader.value = 0.75
		fader.value_changed.emit(0.75)
		_assert(is_equal_approx(instance.get_parameter_normalized(GAIN), 0.75), "a drag writes the parameter")
		instance.set_parameter_normalized(GAIN, 0.25)
		control.refresh()
		_assert(is_equal_approx(fader.value, 0.25), "refresh follows the device (%.2f)" % fader.value)
	control.queue_free()


func _test_hslider_scale_marks() -> void:
	var slider := HorSlider.new()
	slider.min_value = 0.0
	slider.max_value = 24.0
	slider.bidirectional = false
	slider.scale_marks = [{"value": 0.0, "label": "0"}, {"value": 12.0, "label": "12"}, {"value": 30.0}]
	var items := ScaleMarks.layout(slider.scale_marks, slider._value_to_norm, 0.0, 200.0)
	_assert(items.size() == 2, "marks outside the range are dropped (%d)" % items.size())
	_assert(is_equal_approx(items[1]["pos"], 100.0), "12 of 0..24 sits mid-track (%.1f)" % items[1]["pos"])
	slider.bidirectional = true
	slider.max_value = 1.0
	var bi := ScaleMarks.layout([{"value": 0.0}], slider._value_to_norm, 0.0, 200.0)
	_assert(is_equal_approx(bi[0]["pos"], 100.0), "a bidirectional slider centres 0")
	slider.free()
