# SetDeviceParamsTool.gd
class_name SetDeviceParamsTool extends AiTool


func get_name() -> String:
	return "set_device_params"


func get_description() -> String:
	return "Set several device parameters at once. params is a map of parameter name to real value, bool, or enum label. Unknown names fail the whole call. Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Channel/device path"},
			"params": {
				"type": "object",
				"description": "Map of parameter name to value",
				"additionalProperties": true,
			},
		},
		"required": ["path", "params"],
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
	var all_params: Array[DeviceParameter] = inst.get_parameters()
	# Report every bad key at once: one-at-a-time errors made models loop, since key order varies.
	var unknown: PackedStringArray = []
	var errors: PackedStringArray = []
	var planned: Array = []
	for key in raw.keys():
		var pname := str(key).strip_edges()
		var param := DeviceToolUtil.match_param(all_params, pname)
		if param == null:
			unknown.append("'%s'" % pname)
			continue
		var parsed := DeviceToolUtil.parse_param_value(param, raw[key])
		if not parsed.get("ok", false):
			errors.append("%s: %s" % [param.name, str(parsed.get("error", "invalid value"))])
			continue
		var new_n := float(parsed.normalized)
		var old_n := inst.get_parameter_normalized(param.id)
		if abs(old_n - new_n) <= 0.0001:
			continue
		planned.append({"param": param, "old": old_n, "new": new_n})
	if not unknown.is_empty() or not errors.is_empty():
		var parts: PackedStringArray = []
		if not unknown.is_empty():
			parts.append("Unknown parameter %s. Valid names: %s" % [", ".join(unknown), _name_list(all_params)])
		if not errors.is_empty():
			parts.append("Invalid values: %s" % "; ".join(errors))
		return fail("%s. Nothing was changed." % ". ".join(parts))
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
	HistoryUtil.execute_many("Set Device Params", cmds)
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


## Up to 40 parameter names, comma-separated, for error hints.
func _name_list(params: Array[DeviceParameter]) -> String:
	var names: PackedStringArray = []
	for p in params:
		if names.size() >= 40:
			names.append("… (use get_device query)")
			break
		names.append(p.name)
	return ", ".join(names)
