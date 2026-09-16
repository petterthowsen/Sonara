# test_device_drop.gd
# Headless tests for device drag targets (DeviceDropTarget) on a mixer strip's compact device list:
# drops between panels insert at the gap, dropping in place is a no-op, files go onto a device that
# loads them, an empty list outlines itself, and drags a row can't take resolve to nothing (so no
# indicator shows). Also checks that DeviceDrag restores its dimmed source when the drag ends.
# Run: godot --headless --path Godot -s tests/test_device_drop.gd -- --test
#
# The list, project and drop classes reference autoloads, so they are loaded with load() instead of named.
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _asset_script: GDScript
var _drop_target: GDScript
var _device_drag: GDScript
var _list: Control
var _project: Object


func suite_name() -> String:
	return "Device drop tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_asset_script = load("res://browser/Asset.gd")
	_drop_target = load("res://devices/DeviceDropTarget.gd")
	_device_drag = load("res://devices/DeviceDrag.gd")
	await _test_insert_between_panels()
	await _test_drop_in_place_is_noop()
	await _test_file_drops_onto_loader()
	await _test_empty_list_outlines()
	await _test_rejected_drags_resolve_to_nothing()
	await _test_drag_restores_source()


## Registered fake device `device_id`.
func _device(device_id: String, category: int, loads_ext: String = "") -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		if not loads_ext.is_empty():
			device.supports_file_loading = true
			device.supported_file_extensions.assign([loads_ext])
		registry._devices[device_id] = device
	return device


## Fresh project + ChannelDeviceList bound to an instrument channel holding `names` effects.
func _setup(names: Array) -> Dictionary:
	if _list:
		_list.free()
	_project = _project_script.new()
	var ch: Object = _project.create_instrument_track("Inst").channel
	var devices: Array = []
	for n in names:
		var inst: Object = _device_instance_script.new(_device("test.fx." + n, _device_script.DeviceCategory.Effect), ch.id, -1)
		ch.add_device(inst)
		devices.append(inst)
	_list = (load("res://mixer/device_list/ChannelDeviceList.tscn") as PackedScene).instantiate()
	_list.size = Vector2(240, 600)
	root.add_child(_list)
	_list.bind_to_channel(ch)
	await process_frame
	await process_frame
	return {"channel": ch, "devices": devices}


func _panel(inst: Object) -> Control:
	return _list.device_panels.get(inst.id)


func _drag(inst: Object) -> Object:
	return _device_drag.new(_panel(inst), inst, null)


func _asset(type: int, path: String) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = type
	asset.path = path
	return asset


func _positions(ch: Object) -> Array:
	var out: Array = []
	for d in ch.devices:
		out.append(d.device.device_id.get_file().get_extension())
	return out


func _test_insert_between_panels() -> void:
	var s := await _setup(["a", "b", "c"])
	var a_rect: Rect2 = _panel(s.devices[0]).get_global_rect()
	var b_rect: Rect2 = _panel(s.devices[1]).get_global_rect()
	_assert(a_rect.size.y > 0 and b_rect.position.y >= a_rect.end.y, "panels laid out top to bottom")

	# Lower half of A: insert between A and B.
	var point := Vector2(a_rect.get_center().x, a_rect.end.y - 2)
	var target: Object = _drop_target.resolve(_list, _drag(s.devices[2]), point)
	_assert(target.kind == _drop_target.Kind.INSERT, "lower half of A inserts: %d" % target.kind)
	_assert(target.position == 1, "insert position 1: %d" % target.position)
	_assert(not target.outline, "insert draws a line")
	var gap_y := (a_rect.end.y + b_rect.position.y) * 0.5
	_assert(absf(target.indicator_rect.get_center().y - gap_y) <= 1.0, "line sits in the A/B gap")
	_assert(target.indicator_rect.size.y <= 4.0 and target.indicator_rect.size.x > 100.0, "line spans the list width")
	_assert(_positions(s.channel) == ["a", "b", "c"], "resolving moves nothing")

	_assert(target.commit(_drag(s.devices[2])), "commit moves C")
	_assert(_positions(s.channel) == ["a", "c", "b"], "C between A and B: %s" % str(_positions(s.channel)))
	await process_frame
	var order: Array = []
	for p in _list.drop_host.panels():
		order.append(p.device_instance.device.device_id.get_extension())
	_assert(order == ["a", "c", "b"], "panels follow the new order: %s" % str(order))


func _test_drop_in_place_is_noop() -> void:
	var s := await _setup(["a", "b"])
	var a_rect: Rect2 = _panel(s.devices[0]).get_global_rect()
	# Upper and lower half of A itself: both land in A's own slot.
	for y in [a_rect.position.y + 2, a_rect.end.y - 2]:
		var target: Object = _drop_target.resolve(_list, _drag(s.devices[0]), Vector2(a_rect.get_center().x, y))
		_assert(target.is_valid(), "own slot still shows a target")
		_assert(not target.commit(_drag(s.devices[0])), "dropping in place changes nothing")
	_assert(_positions(s.channel) == ["a", "b"], "order unchanged")


func _test_file_drops_onto_loader() -> void:
	var s := await _setup([])
	var sampler: Object = _device_instance_script.new(_device("test.sampler", _device_script.DeviceCategory.Instrument, ".wav"), s.channel.id, -1)
	s.channel.add_device(sampler)
	await process_frame
	await process_frame
	var panel := _panel(sampler)
	_assert(panel != null, "sampler panel exists")
	var header: Rect2 = panel.header.get_global_rect()
	var target: Object = _drop_target.resolve(_list, _asset(_asset_script.TYPE.Audio, "/tmp/kick.wav"), header.get_center())
	_assert(target.kind == _drop_target.Kind.ONTO, "wav on a sampler header goes onto it: %d" % target.kind)
	_assert(target.device == sampler and target.outline and target.indicator_rect == header, "outlines the sampler header")
	var mp3: Object = _drop_target.resolve(_list, _asset(_asset_script.TYPE.Audio, "/tmp/kick.mp3"), header.get_center())
	_assert(not mp3.is_valid(), "unsupported file shows no target")


func _test_empty_list_outlines() -> void:
	await _setup([])
	var rect: Rect2 = _list.get_global_rect()
	var fx: Object = _device("test.fx.new", _device_script.DeviceCategory.Effect)
	var target: Object = _drop_target.resolve(_list, _asset(_asset_script.TYPE.Device, fx.device_id), rect.get_center())
	_assert(target.kind == _drop_target.Kind.INSERT and target.position == 0, "empty list inserts first")
	_assert(target.outline and target.indicator_rect == rect, "empty list outlines itself")


func _test_rejected_drags_resolve_to_nothing() -> void:
	var s := await _setup(["a"])
	var center: Vector2 = _panel(s.devices[0]).get_global_rect().get_center()
	var strip_drag: Object = load("res://mixer/MixerChannelDrag.gd").new(null, s.channel, null)
	_assert(not _drop_target.resolve(_list, strip_drag, center).is_valid(), "strip drag is not a device drop")
	_assert(not _drop_target.accepts(strip_drag), "device rows ignore strip drags (no indicator processing)")
	var midi: Object = _asset(_asset_script.TYPE.Midi, "/tmp/x.mid")
	_assert(not _drop_target.resolve(_list, midi, center).is_valid(), "MIDI asset is not a device drop")
	var outside := _list.get_global_rect().end + Vector2(10, 10)
	_assert(not _drop_target.resolve(_list, _drag(s.devices[0]), outside).is_valid(), "outside the list resolves to nothing")


func _test_drag_restores_source() -> void:
	var s := await _setup(["a"])
	var panel := _panel(s.devices[0])
	var preview := Control.new()
	root.add_child(preview)
	var drag: Object = _device_drag.new(panel, s.devices[0], preview)
	panel.modulate.a = 0.5
	_assert(_device_drag.unwrap(drag) == s.devices[0], "unwrap returns the dragged device")
	preview.free()
	_assert(is_equal_approx(panel.modulate.a, 1.0), "source undimmed when the preview goes away")
