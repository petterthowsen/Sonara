# SetDeviceTool.gd
class_name SetDeviceTool extends AiTool


func get_name() -> String:
	return "set_device"


func get_description() -> String:
	return "Set bypass and/or display name on a device (path or instance_id). Undoable."


func is_read_only() -> bool:
	return false


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Channel/device path"},
			"instance_id": {"type": "string", "description": "Device instance id"},
			"channel_id": {"type": "integer", "description": "Channel id when path is relative"},
			"bypass": {"type": "boolean", "description": "True to bypass (disable) the device"},
			"name": {"type": "string", "description": "New instance name (sibling-unique)"},
		},
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var inst_v = resolve_device(project, args)
	if inst_v is Dictionary:
		return inst_v
	var inst: DeviceInstance = inst_v
	var cmds: Array[Command] = []
	if args.has("bypass"):
		var enabled := not bool(args.bypass)
		if enabled != inst.enabled:
			cmds.append(PropertyCommand.new("Set Bypass", inst, "set_enabled", inst.enabled, enabled))
	if args.has("name"):
		var new_name := str(args.name).strip_edges()
		if new_name.is_empty():
			return fail("name must not be empty")
		if new_name != inst.name:
			cmds.append(PropertyCommand.new("Rename Device", inst, "set_name", inst.name, new_name))
	if cmds.is_empty():
		return ok(compact_device(project, inst))
	if cmds.size() == 1:
		HistoryUtil.execute(cmds[0])
	else:
		HistoryUtil.execute(MacroCommand.new("Set Device", cmds))
	return ok(compact_device(project, inst))
