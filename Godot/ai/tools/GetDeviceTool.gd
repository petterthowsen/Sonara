# GetDeviceTool.gd
class_name GetDeviceTool extends AiTool


func get_name() -> String:
	return "get_device"


func get_description() -> String:
	return "Inspect one device (path or instance_id) and a page of parameters. Default limit 32. Optional group param/cc/all and query substring."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Channel/device path"},
			"instance_id": {"type": "string", "description": "Device instance id"},
			"channel_id": {"type": "integer", "description": "Channel id when path is relative"},
			"offset": {"type": "integer", "description": "Parameter page offset (default 0)"},
			"limit": {"type": "integer", "description": "Page size (default 32)"},
			"group": {
				"type": "string",
				"enum": ["all", "param", "cc"],
				"description": "Parameter group filter",
			},
			"query": {"type": "string", "description": "Case-insensitive parameter name substring"},
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
	var group := str(args.get("group", "all"))
	var query := str(args.get("query", ""))
	var filtered := DeviceToolUtil.filter_params(inst, group, query)
	var page := DeviceNaming.page_items(filtered, int(args.get("offset", 0)), int(args.get("limit", 32)))
	var params: Array = []
	for p in page.items:
		if p is DeviceParameter:
			params.append(DeviceToolUtil.param_dict(inst, p))
	var data := compact_device(project, inst)
	data["loading_state"] = inst.loading_state
	data["param_count"] = page.total
	data["offset"] = page.offset
	data["limit"] = page.limit
	data["next_offset"] = page.next_offset
	data["params"] = params
	if inst.device and inst.device.parameters.is_empty() and str(inst.loading_state).begins_with("loading"):
		data["params"] = []
	return ok(data)
