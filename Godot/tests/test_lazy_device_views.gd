# test_lazy_device_views.gd
# A DevicePanel builds only what is on screen: the parameter list makes its controls the first
# time it is shown (its count is known before that), and the Simple View places its page once,
# after layout, and doesn't rebuild when shown again unless its parameters changed meanwhile.
# Run: godot --headless --path Godot -s tests/test_lazy_device_views.gd -- --test
extends TestBase

const PANEL_SCENE := "res://devices/device_lane/DevicePanel.tscn"

var _device_script: GDScript
var _device_instance_script: GDScript
var _param_script: GDScript
var _project: Object = null


func suite_name() -> String:
	return "Lazy device views"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_project = load("res://data/Project.gd").new()
	load("res://devices/simple_view/SimpleLayoutStore.gd").clear_cache()

	await _test_parameter_list_builds_when_shown()
	await _test_simple_view_builds_once()
	await _test_simple_view_reloads_after_hidden_change()


## Instance of a fake built-in effect with `count` float parameters, on a fresh channel.
func _instance(title: String, count: int) -> Object:
	var device_id := "sonara.test.%s.%d" % [title.to_lower().replace(" ", "_"), Time.get_ticks_usec()]
	var device: Object = _device_script.new(device_id, title,
		_device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	for i in count:
		device.add_parameter(_param_script.new(i, "Param %d" % i))
	root.get_node("AssetService").device_registry._devices[device_id] = device
	var channel: Object = _project.create_instrument_track(title).channel
	return _device_instance_script.new(device, channel.id, 0)


func _panel_for(instance: Object) -> Control:
	var panel: Control = load(PANEL_SCENE).instantiate()
	root.add_child(panel)
	panel.position = Vector2(200, 200)
	await panel.bind_to_device(instance)
	await _frames()
	return panel


func _frames() -> void:
	for _i in 4:
		await process_frame


func _live_children(node: Node) -> Array:
	return node.get_children().filter(func(c): return not c.is_queued_for_deletion())


func _test_parameter_list_builds_when_shown() -> void:
	var panel := await _panel_for(_instance("Lazy List", 6))
	var list: Control = panel._param_list
	_assert(not panel.parameters_pane.visible, "the Parameters tab is closed beside a view")
	_assert(list.get_control_count() == 6, "the list knows its 6 parameters: %d" % list.get_control_count())
	_assert(_live_children(list).is_empty(), "but builds no controls while hidden")
	panel.params_button.button_pressed = true
	_assert(_live_children(list).size() == 6, "opening the tab builds them: %d" % _live_children(list).size())
	panel.params_button.button_pressed = false
	await _frames()
	panel.params_button.button_pressed = true
	_assert(_live_children(list).size() == 6, "reopening keeps them, no duplicates")
	panel.queue_free()


func _test_simple_view_builds_once() -> void:
	var panel := await _panel_for(_instance("Built Once", 4))
	var view: Control = panel._panel_view
	_assert(view != null and view._controls.size() == 4, "the Simple View places its 4 controls")
	var first: Array = view._controls.duplicate()
	panel.set_suspended(true)
	panel.set_suspended(false)
	await _frames()
	_assert(view._controls == first, "showing it again keeps the same controls")
	panel.queue_free()


func _test_simple_view_reloads_after_hidden_change() -> void:
	var instance := _instance("Hidden Change", 2)
	var panel := await _panel_for(instance)
	var view: Control = panel._panel_view
	panel.set_suspended(true)
	instance.device.add_parameter(_param_script.new(2, "Late"))
	instance.parameters_updated.emit()
	_assert(view._controls.size() == 2, "a hidden view waits with the new parameter")
	panel.set_suspended(false)
	await _frames()
	_assert(view._controls.size() == 3, "and picks it up when shown: %d" % view._controls.size())
	panel.queue_free()
