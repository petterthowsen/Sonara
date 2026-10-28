# test_device_lane_cache.gd
# Headless tests for the DeviceLane's per-channel rows: switching back to a channel reuses its
# panels, the hidden row's views are suspended, changes made while hidden show up on return, and
# the rows of removed or disabled channels are freed.
# Run: godot --headless --path Godot -s tests/test_device_lane_cache.gd -- --test
#
# The lane, project and device classes reference autoloads, so they are loaded with load() instead of named.
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _nodes: Array[Node] = []
var _project: Object


func suite_name() -> String:
	return "Device lane cache"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	await _test_switching_back_reuses_panels()
	await _test_hidden_changes_show_on_return()
	await _test_removed_channel_frees_its_row()
	await _test_disabled_channel_frees_its_row()


## Registered fake effect `n` added to `ch`.
func _fx(ch: Object, n: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var id := "test.fx." + n
	var device: Object = registry._devices.get(id)
	if device == null:
		device = _device_script.new(id, id, _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
		registry._devices[id] = device
	var inst: Object = _device_instance_script.new(device, ch.id, -1)
	ch.add_device(inst)
	return inst


## Fresh project with two instrument channels, each holding one effect, and a lane watching it.
func _fixture() -> Dictionary:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	_project = _project_script.new()
	var a: Object = _project.create_instrument_track("A").channel
	var b: Object = _project.create_instrument_track("B").channel
	var fa := _fx(a, "a")
	var fb := _fx(b, "b")
	var lane: Control = (load("res://devices/device_lane/DeviceLane.tscn") as PackedScene).instantiate()
	lane.size = Vector2(1600, 400)
	root.add_child(lane)
	_nodes.append(lane)
	# Headless there is no editor to hand the lane its project.
	lane._connect_to_project(_project)
	return {"lane": lane, "a": a, "b": b, "fa": fa, "fb": fb}


func _settle() -> void:
	await process_frame
	await process_frame


func _test_switching_back_reuses_panels() -> void:
	var f := _fixture()
	var lane: Control = f.lane
	lane.bind_to_channel(f.a)
	await _settle()
	var panel_a: Control = lane.find_device_panel(f.fa)
	var row_a: Control = lane.devices
	_assert(panel_a != null, "A's device gets a panel")
	lane.bind_to_channel(f.b)
	await _settle()
	_assert(lane.find_device_panel(f.fb) != null, "B's device gets a panel")
	_assert(lane.find_device_panel(f.fa) == null, "A's panel isn't part of B's lane")
	_assert(is_instance_valid(panel_a) and not row_a.visible, "A's row is kept, hidden")
	_assert(row_a.suspended, "and its views are suspended")
	lane.bind_to_channel(f.a)
	await _settle()
	_assert(lane.find_device_panel(f.fa) == panel_a, "switching back shows the same panel")
	_assert(lane.devices == row_a and row_a.visible and not row_a.suspended, "A's row is shown and resumed")


func _test_hidden_changes_show_on_return() -> void:
	var f := _fixture()
	var lane: Control = f.lane
	lane.bind_to_channel(f.a)
	await _settle()
	var panel_a: Control = lane.find_device_panel(f.fa)
	lane.bind_to_channel(f.b)
	await _settle()
	var added := _fx(f.a, "added")
	lane.bind_to_channel(f.a)
	await _settle()
	_assert(lane.find_device_panel(added) != null, "a device added while A was hidden shows on return")
	_assert(lane.find_device_panel(f.fa) == panel_a, "the existing panel is kept")


func _test_removed_channel_frees_its_row() -> void:
	var f := _fixture()
	var lane: Control = f.lane
	lane.bind_to_channel(f.a)
	await _settle()
	var row_a: Control = lane.devices
	lane.bind_to_channel(f.b)
	await _settle()
	_project.remove_channel(f.a.id)
	await _settle()
	_assert(not is_instance_valid(row_a), "removing a hidden channel frees its row")
	_assert(not lane._rows.has(f.a), "and forgets it")


func _test_disabled_channel_frees_its_row() -> void:
	var f := _fixture()
	var lane: Control = f.lane
	lane.bind_to_channel(f.a)
	await _settle()
	var row_a: Control = lane.devices
	f.a.set_enabled(false)
	await _settle()
	_assert(is_instance_valid(row_a) and lane.devices == row_a, "the shown channel keeps its row while disabled")
	lane.bind_to_channel(f.b)
	await _settle()
	_assert(not is_instance_valid(row_a), "switching away from a disabled channel frees its row")
	var row_b: Control = lane.devices
	lane.bind_to_channel(f.a)
	await _settle()
	f.b.set_enabled(false)
	await _settle()
	_assert(not is_instance_valid(row_b), "disabling a hidden channel frees its row")
