# test_arpeggiator_view.gd
# Spec 027 (REQ-037, REQ-039): the Arpeggiator panel shows every parameter, disables Repeat Ends
# while Ping-Pong is off, and lights the held keys and the sounding key from the `note_state`
# blob the engine writes.
# Run: godot --headless --path Godot -s tests/test_arpeggiator_view.gd -- --test
extends TestBase

const PANEL_SCENE := "res://devices/device_lane/DevicePanel.tscn"

var _device_script: GDScript
var _device_instance_script: GDScript
var _project_script: GDScript
var _param_script: GDScript
var _strip_script: GDScript


func suite_name() -> String:
	return "Arpeggiator view"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_strip_script = load("res://devices/builtin/NoteStrip.gd")
	_test_blob_decodes()
	_test_strip_highlights()
	_test_strip_range()
	await _test_view_in_the_tree()


func _test_blob_decodes() -> void:
	# step none, sounding 60, no branch, two held keys.
	var state: Dictionary = _strip_script.decode(PackedByteArray([0xFF, 60, 0xFF, 2, 60, 67]))
	_assert(state["step"] == -1 and state["key"] == 60 and state["branch"] == -1, "0xFF fields decode to -1")
	_assert(state["held"] == PackedInt32Array([60, 67]), "held keys decode in order")
	_assert(_strip_script.decode(PackedByteArray([0xFF, 60])).is_empty(), "a short blob is rejected")
	_assert(_strip_script.decode(PackedByteArray([0, 0, 0, 3, 60])).is_empty(), "a blob missing held keys is rejected")


func _test_strip_highlights() -> void:
	var strip: Control = _strip_script.new()
	_assert(strip.set_state(_strip_script.decode(PackedByteArray([0xFF, 64, 0xFF, 3, 60, 64, 67]))), "set_state takes a good blob")
	_assert(strip.is_key_sounding(64) and not strip.is_key_sounding(60), "the sounding key is the one in the blob")
	_assert(strip.is_key_held(60) and strip.is_key_held(67) and not strip.is_key_held(62), "held keys are lit")
	_assert(not strip.set_state({}), "an empty state changes nothing")
	_assert(strip.is_key_sounding(64), "the highlight survives a rejected blob")
	strip.set_state(_strip_script.decode(PackedByteArray([0xFF, 67, 0xFF, 3, 60, 64, 67])))
	_assert(strip.is_key_sounding(67) and not strip.is_key_sounding(64), "the highlight moves with the next blob")
	strip.clear()
	_assert(strip.sounding_key == -1 and strip.held.is_empty(), "clear forgets the state")
	strip.free()


func _param(id: int, name: String, type := "float", values: Array = [], default_v := 0.0) -> Object:
	var p: Object = _param_script.new(id, name)
	p.param_type = type
	p.enum_values.assign(values)
	p.default_value = default_v
	return p


func _find_controls(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child.has_method("get_param_ids") and not child.is_queued_for_deletion():
			out.append(child)
		_find_controls(child, out)


func _test_view_in_the_tree() -> void:
	var device: Object = _device_script.new("sonara.builtin.arpeggiator", "Arpeggiator",
		_device_script.DeviceCategory.NoteEffect, _device_script.DeviceType.BuiltIn)
	device.add_parameter(_param(0, "Mode", "enum", ["Up", "Converge", "As Played", "Random"]))
	device.add_parameter(_param(1, "Reverse", "bool"))
	device.add_parameter(_param(2, "Ping-Pong", "bool"))
	device.add_parameter(_param(3, "Repeat Ends", "bool"))
	var octaves: Object = _param(4, "Octaves", "float", [], 1.0)
	octaves.min_value = 1.0
	octaves.max_value = 4.0
	device.add_parameter(octaves)
	device.add_parameter(_param(10, "Rate", "enum", ["1/1", "1/2", "1/4", "1/8", "1/16"]))
	var gate: Object = _param(11, "Gate", "float", [], 100.0)
	gate.min_value = 10.0
	gate.max_value = 200.0
	device.add_parameter(gate)
	var swing: Object = _param(12, "Swing", "float")
	swing.min_value = 0.0
	swing.max_value = 75.0
	device.add_parameter(swing)
	device.add_parameter(_param(20, "Latch", "bool"))
	load("res://devices/DeviceViewFactory.gd").register_builtin_views(device)
	_assert(device.has_panel_view(), "the Arpeggiator has its own panel view")
	root.get_node("AssetService").device_registry._devices[device.device_id] = device
	var project: Object = _project_script.new()
	var channel: Object = project.create_instrument_track("Arp").channel
	var instance: Object = _device_instance_script.new(device, channel.id, 0)

	var panel: Control = load(PANEL_SCENE).instantiate()
	root.add_child(panel)
	panel.position = Vector2(200, 200)
	await panel.bind_to_device(instance)
	for _i in 4:
		await process_frame
	var views: Array = []
	_find_nodes_of_script(panel, "res://devices/builtin/ArpeggiatorDefaultView.gd", views)
	_assert(views.size() == 1, "the panel uses the Arpeggiator view")
	var controls: Array = []
	_find_controls(panel, controls)
	var by_param := {}
	for control in controls:
		for id in control.get_param_ids():
			by_param[id] = control
	for id in [0, 1, 2, 3, 4, 10, 11, 12, 20]:
		_assert(by_param.has(id), "parameter %d has a control" % id)
	if by_param.has(2) and by_param.has(3):
		_assert(by_param[3].is_disabled(), "Repeat Ends starts disabled (Ping-Pong off)")
		instance.set_parameter_normalized(2, 1.0)
		_assert(not by_param[3].is_disabled(), "Ping-Pong on enables Repeat Ends")
		instance.set_parameter_normalized(2, 0.0)
		_assert(by_param[3].is_disabled(), "Ping-Pong off disables it again")
	if views.size() == 1:
		var view: Object = views[0]
		view._on_data(view._subscribed_path, "note_state", PackedByteArray([0xFF, 60, 0xFF, 1, 60]))
		view._subscribed_path = instance.osc_path()
		view._on_data(instance.osc_path(), "note_state", PackedByteArray([0xFF, 62, 0xFF, 1, 62]))
		_assert(view.strip.is_key_sounding(62), "a note_state blob for this device lights the strip")
		view._on_data("/channel/999/device/9", "note_state", PackedByteArray([0xFF, 70, 0xFF, 0]))
		_assert(view.strip.is_key_sounding(62), "a blob for another device is ignored")
	panel.queue_free()
	var store: GDScript = load("res://devices/simple_view/SimpleLayoutStore.gd")
	DirAccess.remove_absolute(store.path_for(device.device_id))
	store.clear_cache()


func _find_nodes_of_script(node: Node, script_path: String, out: Array) -> void:
	for child in node.get_children():
		var script: Script = child.get_script()
		if script != null and script.resource_path == script_path:
			out.append(child)
		_find_nodes_of_script(child, script_path, out)


func _test_strip_range() -> void:
	var strip: Control = _strip_script.new()
	_assert(strip.key_range() == Vector2i(36, 72), "an idle strip shows the default range")
	strip.set_state(_strip_script.decode(PackedByteArray([0xFF, 0xFF, 0xFF, 3, 60, 64, 67])))
	_assert(strip.key_range() == Vector2i(60, 72), "C3 E3 G3 span C3 to C4 (got %s)" % strip.key_range())
	strip.octaves = 3
	_assert(strip.key_range() == Vector2i(60, 96), "three octaves reach the C above G5 (got %s)" % strip.key_range())
	strip.free()
