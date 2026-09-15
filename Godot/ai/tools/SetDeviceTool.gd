# SetDeviceTool.gd
class_name SetDeviceTool extends AiTool


func get_name() -> String:
	return "set_device"


func get_description() -> String:
	return "Set bypass and/or display name on a device by path. Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Channel/device path"},
			"bypass": {"type": "boolean", "description": "True to bypass (disable) the device"},
			"name": {"type": "string", "description": "New instance name (sibling-unique)"},
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
	var cmds: Array[Command] = []
	var changes: Array[String] = []
	if args.has("bypass"):
		var enabled := not bool(args.bypass)
		if enabled != inst.enabled:
			cmds.append(PropertyCommand.new("Set Bypass", inst, "set_enabled", inst.enabled, enabled))
			changes.append("bypassed" if not enabled else "unbypassed")
	if args.has("name"):
		var new_name := name_arg(args, "name")
		if new_name.is_empty():
			return fail("name must not be empty")
		# Record the final (possibly suffixed) name so redo reapplies exactly that.
		var final_name := inst.unique_name_for(new_name)
		if final_name != inst.name:
			cmds.append(PropertyCommand.new("Rename Device", inst, "set_name", inst.name, final_name))
			changes.append("renamed to \"%s\"" % final_name)
	if not cmds.is_empty():
		HistoryUtil.execute_many("Set Device", cmds)
	var data := compact_device(project, inst)
	var text := "%s: %s" % [data.path, ", ".join(changes)] if not changes.is_empty() else "%s: no change" % data.path
	return ok_text(text, data)
