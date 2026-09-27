# test_device_drop_channels.gd
# Headless tests for device drops that cross channels or create them: moving a device into another
# channel's compact list (and undoing it), devices that must stay on their channel, the master
# channel taking effects, a container's body taking drops into it, compact lists and device lanes
# dropping the panel of a device that left the chain, and devices dropped on empty mixer space
# creating an instrument/audio track (left pane) or a bus (right pane).
# Run: godot --headless --path Godot -s tests/test_device_drop_channels.gd -- --test
#
# The lists, project and drop classes reference autoloads, so they are loaded with load() instead of named.
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _asset_script: GDScript
var _drop_target: GDScript
var _device_drag: GDScript
var _drop_util: GDScript
var _nodes: Array[Node] = []
var _project: Object


func suite_name() -> String:
	return "Device drops across channels"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_asset_script = load("res://browser/Asset.gd")
	_drop_target = load("res://devices/DeviceDropTarget.gd")
	_device_drag = load("res://devices/DeviceDrag.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	await _test_move_to_other_channel()
	await _test_devices_that_stay_on_their_channel()
	await _test_master_takes_effects()
	await _test_container_body_takes_drops()
	await _test_lists_drop_panels_of_moved_devices()
	await _test_empty_mixer_space_creates_channels()


## Registered fake device `device_id`.
func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


func _fx(ch: Object, n: String, parent: Object = null) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.fx." + n, _device_script.DeviceCategory.Effect), ch.id, -1)
	ch.add_device(inst, -1, parent)
	return inst


func _asset(type: int, path: String) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = type
	asset.path = path
	return asset


func _fresh_project() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	_project = _project_script.new()


## Compact device list bound to `ch`, laid out at `x`.
func _list(ch: Object, x: float = 0.0) -> Control:
	var list: Control = (load("res://mixer/device_list/ChannelDeviceList.tscn") as PackedScene).instantiate()
	list.position = Vector2(x, 0)
	list.size = Vector2(240, 600)
	root.add_child(list)
	_nodes.append(list)
	list.bind_to_channel(ch)
	await process_frame
	await process_frame
	return list


## Device lane bound to `ch` (headless there is no editor to bind it on channel focus).
func _lane(ch: Object) -> Control:
	var lane: Control = (load("res://devices/device_lane/DeviceLane.tscn") as PackedScene).instantiate()
	lane.size = Vector2(1200, 400)
	root.add_child(lane)
	_nodes.append(lane)
	lane.bind_to_channel(ch)
	await process_frame
	await process_frame
	return lane


func _names(host: Array) -> Array:
	var out: Array = []
	for d in host:
		out.append(d.device.device_id.get_extension())
	return out


func _test_move_to_other_channel() -> void:
	_fresh_project()
	var one: Object = _project.create_instrument_track("One").channel
	var two: Object = _project.create_instrument_track("Two").channel
	var a := _fx(one, "a")
	var b := _fx(two, "b")
	var list_one := await _list(one)
	var list_two := await _list(two, 300)
	var b_rect: Rect2 = list_two.device_panels[b.id].get_global_rect()

	var drag: Object = _device_drag.new(list_one.device_panels[a.id], a, null)
	var target: Object = _drop_target.resolve(list_two, drag, Vector2(b_rect.get_center().x, b_rect.position.y + 2))
	_assert(target.kind == _drop_target.Kind.INSERT and target.position == 0, "another channel's list inserts: %d at %d" % [target.kind, target.position])
	_assert(_names(one.devices) == ["a"], "resolving moves nothing")
	_assert(target.commit(drag), "commit moves A")
	_assert(_names(one.devices).is_empty() and _names(two.devices) == ["a", "b"], "A moved to Two: %s" % str(_names(two.devices)))
	_assert(a.channel_id == two.id and a.get_channel() == two, "A belongs to Two")
	await process_frame
	_assert(list_one.drop_host.panels().is_empty(), "One's list dropped A's panel")
	_assert(list_two.drop_host.panels().size() == 2, "Two's list shows A and B")

	var cmd: Object = load("res://history/commands/DeviceTransferCommand.gd").new(a, one, null, -1)
	cmd.do()
	cmd.undo()
	_assert(_names(two.devices) == ["a", "b"] and a.get_channel() == two, "transfer undo puts A back")

	# A strip-wide drop (not over a panel) appends to the channel through its list's host.
	var bus: Object = _project.create_bus_channel("Bus")
	_assert(list_two.drop_host.is_noop(_device_drag.new(null, b, null)), "appending the last device in its own chain is a no-op")
	var bus_list := await _list(bus, 600)
	_assert(bus_list.drop_host.drop(_device_drag.new(null, b, null)), "bus host takes B")
	_assert(_names(bus.devices) == ["b"], "B moved to the bus")


func _test_devices_that_stay_on_their_channel() -> void:
	_fresh_project()
	var inst_ch: Object = _project.create_instrument_track("Inst").channel
	var bus: Object = _project.create_bus_channel("Bus")
	var synth: Object = _device_instance_script.new(_device("test.synth", _device_script.DeviceCategory.Instrument), inst_ch.id, -1)
	inst_ch.add_device(synth)
	var bus_host: Object = load("res://devices/DeviceChainDropHost.gd").new()
	bus_host.bind(bus)
	_assert(not bus_host.can_drop(_device_drag.new(null, synth, null)), "an instrument can't move to a bus")

	var plugin := _fx(inst_ch, "multiout")
	plugin.return_channel_ids.assign([42])
	_assert(not bus_host.can_drop(_device_drag.new(null, plugin, null)), "a device with return channels stays")
	_assert(_drop_util.new_channel_kind(_device_drag.new(null, plugin, null), true) == "", "and doesn't start a new channel")


func _test_master_takes_effects() -> void:
	_fresh_project()
	var master: Object = _project.get_master_channel()
	_assert(master != null, "project has a master")
	var fx: Object = _device("test.fx.master", _device_script.DeviceCategory.Effect)
	var synth: Object = _device("test.synth", _device_script.DeviceCategory.Instrument)
	_assert(_drop_util.can_drop_asset_on_channel(master, _asset(_asset_script.TYPE.Device, fx.device_id)), "master takes an effect asset")
	_assert(not _drop_util.can_drop_asset_on_channel(master, _asset(_asset_script.TYPE.Device, synth.device_id)), "master rejects an instrument")
	var other: Object = _project.create_bus_channel("Bus")
	var moved := _fx(other, "m")
	var host: Object = load("res://devices/DeviceChainDropHost.gd").new()
	host.bind(master)
	_assert(host.drop(_device_drag.new(null, moved, null)), "an effect moves onto master")
	_assert(master.devices.has(moved), "master holds it")


func _test_container_body_takes_drops() -> void:
	_fresh_project()
	var ch: Object = _project.create_instrument_track("Inst").channel
	var chain: Object = _device_instance_script.new(_device("test.chain", _device_script.DeviceCategory.Effect, true), ch.id, -1)
	ch.add_device(chain)
	var loose := _fx(ch, "loose")
	var lane := await _lane(ch)
	var panel: Control = lane.find_device_panel(chain)
	var rect: Rect2 = panel.get_global_rect()
	var header: Rect2 = panel.header.get_global_rect()
	var body := Vector2(rect.get_center().x, header.end.y + (rect.end.y - header.end.y) * 0.5)
	_assert(rect.size.x > 60.0 and body.y < rect.end.y, "container panel has a body: %s" % str(rect))
	var fx: Object = _device("test.fx.new", _device_script.DeviceCategory.Effect)
	var target: Object = _drop_target.resolve(lane, _asset(_asset_script.TYPE.Device, fx.device_id), body)
	_assert(target.kind == _drop_target.Kind.ONTO and target.device == chain, "asset over the body goes into the container: %d" % target.kind)
	_assert(target.outline and target.indicator_rect == header, "the container header glows")
	var edge: Object = _drop_target.resolve(lane, _asset(_asset_script.TYPE.Device, fx.device_id), Vector2(rect.end.x - 2, body.y))
	_assert(edge.kind == _drop_target.Kind.INSERT and edge.position == 1, "near the end it inserts beside: %d" % edge.kind)

	var drag: Object = _device_drag.new(lane.find_device_panel(loose), loose, null)
	var move: Object = _drop_target.resolve(lane, drag, body)
	_assert(move.kind == _drop_target.Kind.ONTO, "a dragged device over the body goes in too")
	_assert(move.commit(drag) and chain.children.has(loose), "commit nests the device")
	await process_frame
	_assert(lane.find_device_panel(loose) == null or lane.find_device_panel(loose).get_parent() != lane.devices, "the nested device's root panel is gone")


func _test_lists_drop_panels_of_moved_devices() -> void:
	_fresh_project()
	var ch: Object = _project.create_instrument_track("Inst").channel
	var a := _fx(ch, "a")
	var b := _fx(ch, "b")
	var list := await _list(ch)
	# Removing A reindexes B to A's old position; B's panel must survive.
	ch.remove_device_instance(a)
	await process_frame
	var left: Array = []
	for p in list.drop_host.panels():
		left.append(p.device_instance)
	_assert(left == [b], "only A's compact panel went away")

	var c := _fx(ch, "c")
	var lane := await _lane(ch)
	_assert(lane.find_device_panel(b) != null and lane.find_device_panel(c) != null, "lane shows B and C")
	ch.remove_device_instance(b)
	await process_frame
	_assert(lane.find_device_panel(b) == null, "lane dropped B's panel")
	_assert(lane.find_device_panel(c) != null, "lane kept C's panel")


func _test_empty_mixer_space_creates_channels() -> void:
	_fresh_project()
	var mixer: Control = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	mixer.size = Vector2(1400, 600)
	root.add_child(mixer)
	_nodes.append(mixer)
	mixer._on_project_opened(_project)
	var src: Object = _project.create_instrument_track("Src").channel
	var moving := _fx(src, "moving")
	await process_frame
	await process_frame

	var fx: Object = _device("test.fx.verb", _device_script.DeviceCategory.Effect)
	var synth: Object = _device("test.synth", _device_script.DeviceCategory.Instrument)
	var fx_asset := _asset(_asset_script.TYPE.Device, fx.device_id)
	var synth_asset := _asset(_asset_script.TYPE.Device, synth.device_id)
	_assert(_drop_util.new_channel_kind(fx_asset, false) == "audio", "effect on the track side makes an audio track")
	_assert(_drop_util.new_channel_kind(fx_asset, true) == "bus", "effect on the bus side makes a bus")
	_assert(_drop_util.new_channel_kind(synth_asset, false) == "instrument", "instrument makes an instrument track")
	_assert(_drop_util.new_channel_kind(synth_asset, true) == "", "instrument can't make a bus")

	var left: Rect2 = mixer.left_pane.get_global_rect()
	var right: Rect2 = mixer.right_pane.get_global_rect()
	var src_strip: Control = mixer.find_mixer_channel_ui_for_channel(src)
	var left_empty := Vector2(left.end.x - 30, left.get_center().y)
	var right_empty := Vector2(right.position.x + 30, right.get_center().y)
	_assert(not src_strip.get_global_rect().has_point(left_empty), "probe point is empty track space")
	_assert(mixer.new_channel_side(left_empty) == mixer.SIDE_TRACKS, "left empty space is the track side")
	_assert(mixer.new_channel_side(right_empty) == mixer.SIDE_BUSES, "right empty space is the bus side")
	_assert(mixer.new_channel_side(src_strip.get_global_rect().get_center()) == mixer.SIDE_NONE, "a strip is not empty space")
	_assert(not mixer.can_drop_new_channel(synth_asset, right_empty), "instrument rejected on the bus side")

	var buses: Array = mixer.drop_new_channel(fx_asset, right_empty)
	_assert(buses.size() == 1 and buses[0].is_bus, "effect on the bus side created a bus")
	_assert(_names(buses[0].devices) == ["verb"], "the bus holds the effect: %s" % str(_names(buses[0].devices)))

	var drag: Object = _device_drag.new(null, moving, null)
	var tracks: Array = mixer.drop_new_channel(drag, left_empty)
	_assert(tracks.size() == 1 and tracks[0].channel_type == load("res://data/Channel.gd").ChannelType.AUDIO, "dragged effect made an audio channel")
	_assert(tracks[0].devices.has(moving) and not src.devices.has(moving), "the device moved to it")
	_assert(drag.did_commit, "the drag is marked committed")
	var rect: Rect2 = mixer._new_channel_line_rect(false)
	_assert(rect.size.x <= 4.0 and rect.size.y > 100.0, "new-channel indicator is a vertical line")
