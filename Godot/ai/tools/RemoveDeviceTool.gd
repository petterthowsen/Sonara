# RemoveDeviceTool.gd
class_name RemoveDeviceTool extends AiTool


func get_name() -> String:
	return "remove_device"


func get_description() -> String:
	return "Remove a device by path (Channel/Device/Child) or instance_id. Undoable."


func is_read_only() -> bool:
	return false


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Channel/device path"},
			"instance_id": {"type": "string", "description": "Device instance id"},
			"channel_id": {"type": "integer", "description": "Channel id when path is relative"},
		},
		"required": [],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var inst_v = resolve_device(project, args)
	if inst_v is Dictionary:
		return inst_v
	var inst: DeviceInstance = inst_v
	var channel: Channel = project.get_channel_by_id(inst.channel_id)
	if channel == null:
		return fail("Channel not found for device")
	var snapshot := compact_device(project, inst)
	HistoryUtil.execute(DeviceRemoveCommand.new(channel, inst))
	return ok(snapshot)
