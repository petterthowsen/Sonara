# RemoveDeviceTool.gd
class_name RemoveDeviceTool extends AiTool


func get_name() -> String:
	return "remove_device"


func get_description() -> String:
	return "Remove a device by path (Channel/Device/Child). Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Channel/device path"},
		},
		"required": ["path"],
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
	var path: String = snapshot.path
	HistoryUtil.execute(DeviceRemoveCommand.new(channel, inst))
	return ok_text("Removed %s" % path, snapshot)
