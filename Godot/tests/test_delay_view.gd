# test_delay_view.gd
# Delay view behaviour (spec 012 Phase 1): the Time knob shows its Sync division while Sync is
# not Off and greys (never hides) its ms value, and a Delay added to a BUS channel defaults to
# 100 % wet (the send workflow) while an insert keeps the device's own Mix.
# Run: godot --headless --path Godot -s tests/test_delay_view.gd -- --test
#
# Scripts that reach autoloads (DeviceInstance, SimpleControl, …) are loaded at runtime, not
# referenced as types: compiling them at start-up happens before the autoloads exist.
extends TestBase

const PANEL_SCENE := "res://devices/device_lane/DevicePanel.tscn"
const TIME_L := 0
const SYNC_L := 2
const MIX := 41
## Index of "1/8." in the engine's sync list (audio/dsp/tempo_sync.rs), the Delay's default.
const DEFAULT_SYNC := 17

var _device_script: GDScript
var _device_instance_script: GDScript
var _project_script: GDScript
var _param_script: GDScript

var _project: Object = null
var _tmp_dir := ""


func suite_name() -> String:
	return "Delay view tests"


func run_tests() -> void:
	# The device id is the real one, so keep its layout file out of the user's config dir.
	_tmp_dir = OS.get_temp_dir().path_join("sonara_delay_view_test_%d" % Time.get_ticks_usec())
	SimpleLayoutStore.base_dir_override = _tmp_dir
	SimpleLayoutStore.clear_cache()
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_project = _project_script.new()

	_test_strategy_marks_the_time_knob()
	await _test_time_knob_shows_the_division()
	_test_bus_add_defaults_mix_to_100()
	_cleanup()


func _cleanup() -> void:
	SimpleLayoutStore.base_dir_override = ""
	var dir := DirAccess.open(_tmp_dir)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(_tmp_dir)


## ----------------------------------------------------------------------------
## Helpers
## ----------------------------------------------------------------------------

## The engine's tempo_sync list: "Off", then 4/1…1/32 straight, dotted and triplet.
static func _sync_choices() -> Array[String]:
	var out: Array[String] = ["Off"]
	for division in ["4/1", "2/1", "1/1", "1/2", "1/4", "1/8", "1/16", "1/32"]:
		out.append(division)
		out.append(division + ".")
		out.append(division + "T")
	return out


## The Delay's parameters as /builtin/info advertises them (the Time/Sync pair and Mix).
func _delay_params() -> Array:
	return [
		_float_param(TIME_L, "Time L", "ms", 1.0, 5000.0, 375.0, true),
		_float_param(1, "Time R", "ms", 1.0, 5000.0, 375.0, true),
		_enum_param(SYNC_L, "Sync L", DEFAULT_SYNC),
		_enum_param(3, "Sync R", DEFAULT_SYNC),
		_float_param(MIX, "Mix", "%", 0.0, 100.0, 30.0),
	]


func _float_param(id: int, name: String, unit: String, min_v: float, max_v: float, default_v: float, logarithmic := false) -> Object:
	var p: Object = _param_script.new(id, name, unit)
	p.min_value = min_v
	p.max_value = max_v
	p.default_value = default_v
	p.is_logarithmic = logarithmic
	return p


func _enum_param(id: int, name: String, default_index: int) -> Object:
	var p: Object = _param_script.new(id, name)
	p.param_type = "enum"
	p.enum_values.assign(_sync_choices())
	p.default_value = float(default_index)
	return p


## A Delay instance on `channel`, or on a fresh instrument track when none is given.
func _instance(title: String, channel: Object = null) -> Object:
	var device: Object = _device_script.new("sonara.builtin.delay", "Delay",
		_device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	for param in _delay_params():
		device.add_parameter(param)
	root.get_node("AssetService").device_registry._devices[device.device_id] = device
	if channel == null:
		channel = _project.create_instrument_track(title).channel
	return _device_instance_script.new(device, channel.id, 0)


## A DevicePanel bound to `instance`, away from the headless pointer at (0, 0).
func _panel_for(instance: Object) -> Control:
	var panel: Control = load(PANEL_SCENE).instantiate()
	root.add_child(panel)
	panel.position = Vector2(200, 200)
	await panel.bind_to_device(instance)
	for _i in 4:
		await process_frame
	return panel


## The SimpleControl showing `param_id`, or null.
func _control_for(view: Control, param_id: int) -> Object:
	for control in view._controls:
		if control.handles_param(param_id) and param_id in control.control_data.get("params", []):
			return control
	return null


## ----------------------------------------------------------------------------
## Tests
## ----------------------------------------------------------------------------

## The DelayStrategy marks each Time knob with its Sync sibling; the layout itself stays free of
## the annotation (SimpleView resolves it at bind time).
func _test_strategy_marks_the_time_knob() -> void:
	var strategy: Object = load("res://devices/simple_view/strategies/DelayStrategy.gd").new()
	var params: Array = _delay_params()
	var time := {"kind": SimpleControlKinds.KNOB, "params": [TIME_L], "rect": [0, 0, 1, 1]}
	var marked: Dictionary = strategy.decorate_control(time, params)
	_assert(marked.get("sync", -1) == SYNC_L, "Time L is marked with Sync L (%s)" % [marked.get("sync")])
	_assert(not time.has("sync"), "the original layout control is left alone")
	var sync := {"kind": SimpleControlKinds.DROPDOWN, "params": [SYNC_L], "rect": [1, 0, 1, 1]}
	_assert(not strategy.decorate_control(sync, params).has("sync"), "the Sync control isn't marked")
	_assert(not strategy.decorate_control({"kind": "knob", "params": [MIX], "rect": [2, 0, 1, 1]}, params).has("sync"),
		"Mix isn't marked")


## The Time knob leads with the division while Sync is not Off, keeps the ms value behind it,
## and greys rather than hides the control. Sync Off gives the plain ms readout back.
func _test_time_knob_shows_the_division() -> void:
	var instance: Object = _instance("Delay Sync")
	var panel: Control = await _panel_for(instance)
	var view: Control = panel._panel_view
	var control: Object = _control_for(view, TIME_L)
	_assert(control != null, "the Time L knob is in the layout")
	if control == null:
		panel.queue_free()
		return
	var knob: Object = control._inner
	_assert(knob != null and knob.has_method("get_value_text"), "Time L renders as a knob")
	# The Delay's default Sync is 1/8., so the knob leads with the division out of the box.
	_assert(knob.get_value_text().begins_with("1/8."), "the default shows the division it plays (%s)" % knob.get_value_text())
	_assert(knob.get_value_text().contains("375"), "the ms value stays visible (%s)" % knob.get_value_text())
	_assert(knob.modulate.a < 1.0, "the ms value is greyed (alpha %.2f)" % knob.modulate.a)
	_assert(control.visible and control._inner != null, "the Time knob is greyed, not hidden")

	instance.set_parameter_normalized(SYNC_L, 1.0 / 24.0)  # "4/1"
	_assert(knob.get_value_text().begins_with("4/1"), "the readout follows the Sync (%s)" % knob.get_value_text())

	instance.set_parameter_normalized(SYNC_L, 0.0)  # Off
	_assert(not knob.get_value_text().begins_with("4/1"), "Sync Off returns to the ms readout (%s)" % knob.get_value_text())
	_assert(is_equal_approx(knob.modulate.a, 1.0), "Sync Off un-greys the knob")
	panel.queue_free()


## A Delay added to a BUS channel is 100 % wet; on a track it keeps its own Mix default.
func _test_bus_add_defaults_mix_to_100() -> void:
	var bus: Object = _project.create_bus_channel("Delay Bus")
	var on_bus: Object = _instance("Bus Delay", bus)
	bus.add_device(on_bus)
	_assert(is_equal_approx(on_bus.get_parameter_normalized_by_name("Mix"), 1.0),
		"a Delay added to a BUS channel is 100 %% wet (got %.2f)" % on_bus.get_parameter_normalized_by_name("Mix"))

	var track: Object = _project.create_instrument_track("Delay Insert").channel
	var on_track: Object = _instance("Insert Delay", track)
	track.add_device(on_track)
	_assert(is_equal_approx(on_track.get_parameter_normalized_by_name("Mix"), 0.3),
		"an insert keeps the device's own Mix default (got %.2f)" % on_track.get_parameter_normalized_by_name("Mix"))
