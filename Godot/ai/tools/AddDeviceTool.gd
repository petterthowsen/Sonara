# AddDeviceTool.gd
class_name AddDeviceTool extends AiTool


func get_name() -> String:
	return "add_device"


func get_description() -> String:
	return "Add a device or SFZ to a channel. Pass asset_path from search_assets or a device_id such as sonara.builtin.polysynth. Instruments only on instrument channels; no FX on master."


func is_read_only() -> bool:
	return false


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel_id": {"type": "integer", "description": "Mixer channel id"},
			"asset_path": {"type": "string", "description": "Asset path from search_assets"},
			"device_id": {"type": "string", "description": "Built-in or plugin device id"},
			"position": {"type": "integer", "description": "Insert index, -1 appends"},
		},
		"required": ["channel_id"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var channel = resolve_channel(project, args)
	if channel is Dictionary:
		return channel
	var asset := _resolve_asset(args)
	if asset == null:
		return fail("Provide asset_path or device_id that AssetService can resolve")
	if not DeviceDropUtil.can_drop_asset_on_channel(channel, asset):
		return fail("Cannot add that asset to channel %d (%s)" % [channel.id, channel.name])
	var position := int(args.get("position", -1))
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var before: Array[String] = []
	for d in channel.devices:
		if d is DeviceInstance:
			before.append(d.id)
	await DeviceDropUtil.drop_asset(channel, asset, position, null, tree)
	var added: DeviceInstance = null
	for d in channel.devices:
		if d is DeviceInstance and not before.has(d.id):
			added = d
			break
	if added == null and not channel.devices.is_empty():
		added = channel.devices[channel.devices.size() - 1]
	if added == null or added.device == null:
		return fail("Device was not added")
	return ok({
		"channel_id": channel.id,
		"position": added.position,
		"name": added.device.name,
		"device_id": added.device.device_id,
		"instance_id": added.id,
	})


func _resolve_asset(args: Dictionary) -> Asset:
	if AssetService == null:
		return null
	var path := str(args.get("asset_path", "")).strip_edges()
	if not path.is_empty():
		var by_path := AssetService.find_asset(path)
		if by_path:
			return by_path
	var device_id := str(args.get("device_id", "")).strip_edges()
	if device_id.is_empty():
		device_id = path
	if device_id.is_empty():
		return null
	var by_id := AssetService.find_asset(device_id)
	if by_id:
		return by_id
	var device := AssetService.get_device(device_id)
	if device == null:
		return null
	var fake := Asset.new()
	fake.type = Asset.TYPE.Device
	fake.path = device.device_id
	fake.name = device.name
	return fake
