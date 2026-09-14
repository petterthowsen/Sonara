# SetDeviceParamsTool.gd
class_name SetDeviceParamsTool extends AiTool


func get_name() -> String:
	return "set_device_params"


func get_description() -> String:
	return "Set several device parameters at once. params is a map of parameter name to real value, bool, or enum label. Unknown names fail the whole call. Undoable."


func is_read_only() -> bool:
	return false


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Channel/device path"},
			"instance_id": {"type": "string", "description": "Device instance id"},
			"channel_id": {"type": "integer", "description": "Channel id when path is relative"},
			"params": {
				"type": "object",
				"description": "Map of parameter name to value",
				"additionalProperties": true,
			},
		},
		"required": ["params"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var inst_v = resolve_device(project, args)
	if inst_v is Dictionary:
		return inst_v
	var inst: DeviceInstance = inst_v
	if inst.device == null:
		return fail("Device has no type metadata")
	var raw = args.get("params", {})
	if not raw is Dictionary or raw.is_empty():
		return fail("params must be a non-empty object")
	var planned: Array = []
	for key in raw.keys():
		var pname := str(key).strip_edges()
		var param := inst.get_parameter_by_name(pname)
		if param == null:
			return fail("Unknown parameter '%s'" % pname)
		var parsed := DeviceToolUtil.parse_param_value(param, raw[key])
		if not parsed.get("ok", false):
			return fail(str(parsed.get("error", "Invalid value for '%s'" % pname)))
		var new_n := float(parsed.normalized)
		var old_n := inst.get_parameter_normalized(param.id)
		if abs(old_n - new_n) <= 0.0001:
			continue
		planned.append({"param": param, "old": old_n, "new": new_n})
	if planned.is_empty():
		return ok(compact_device(project, inst))
	var cmds: Array[Command] = []
	for item in planned:
		var param: DeviceParameter = item.param
		var cmd := PropertyCommand.new(
			"Set %s" % param.name,
			inst,
			"",
			[param.id, item.old],
			[param.id, item.new]
		)
		cmd.set_callable(func(argv): inst.set_parameter_normalized(argv[0], argv[1])).set_unpack_array(true)
		cmds.append(cmd)
	if cmds.size() == 1:
		HistoryUtil.execute(cmds[0])
	else:
		HistoryUtil.execute(MacroCommand.new("Set Device Params", cmds))
	var data := compact_device(project, inst)
	var applied: Array = []
	for item in planned:
		var p: DeviceParameter = item.param
		applied.append({
			"name": p.name,
			"value": DeviceToolUtil.current_param_value(inst, p),
		})
	data["changed"] = applied
	return ok(data)
