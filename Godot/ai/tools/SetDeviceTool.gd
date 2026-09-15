# SetDeviceTool.gd
class_name SetDeviceTool extends AiTool


func get_name() -> String:
	return "set_device"


func get_description() -> String:
	return "Set bypass and/or display name on a device (path or instance_id). Undoable."


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
	var changes: Array[String] = []
	if args.has("bypass"):
		var enabled := not bool(args.bypass)
		if enabled != inst.enabled:
			cmds.append(PropertyCommand.new("Set Bypass", inst, "set_enabled", inst.enabled, enabled))
			changes.append("bypassed" if not enabled else "unbypassed")
	if args.has("name"):
		var new_name := str(args.name).strip_edges()
		if new_name.is_empty():
			return fail("name must not be empty")
		if new_name != inst.name:
			cmds.append(PropertyCommand.new("Rename Device", inst, "set_name", inst.name, new_name))
			changes.append("renamed to \"%s\"" % new_name)
	if not cmds.is_empty():
		HistoryUtil.execute_many("Set Device", cmds)
	var data := compact_device(project, inst)
	var text := "%s: %s" % [data.path, ", ".join(changes)] if not changes.is_empty() else "%s: no change" % data.path
	return ok_text(text, data)
