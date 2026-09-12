# ListDevicesTool.gd
class_name ListDevicesTool extends AiTool


func get_name() -> String:
	return "list_devices"


func get_description() -> String:
	return "List devices on a mixer channel: position, name, device_id, category, bypass."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel_id": {"type": "integer", "description": "Mixer channel id"},
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
	var devices: Array = []
	for d in channel.devices:
		if not d is DeviceInstance or d.device == null:
			continue
		devices.append({
			"position": d.position,
			"name": d.device.name,
			"device_id": d.device.device_id,
			"category": Device.DeviceCategory.keys()[d.device.category],
			"bypass": not d.enabled,
		})
	return ok({"channel_id": channel.id, "devices": devices})
