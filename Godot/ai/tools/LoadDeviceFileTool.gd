# LoadDeviceFileTool.gd
class_name LoadDeviceFileTool extends AiTool


func get_name() -> String:
	return "load_device_file"


func get_description() -> String:
	return "Load an audio or SFZ file into an existing Sampler/Sfizz. To add a new drum pad, use add_device on the Drum Machine instead."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Device path"},
			"instance_id": {"type": "string", "description": "Device instance id"},
			"channel_id": {"type": "integer", "description": "Channel id when path is relative"},
			"asset_path": {"type": "string", "description": "Asset path from search_assets"},
		},
		"required": ["asset_path"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var inst_v = resolve_device(project, args)
	if inst_v is Dictionary:
		return inst_v
	var inst: DeviceInstance = inst_v
	if AssetService == null:
		return fail("AssetService is not available")
	var asset_path := str(args.get("asset_path", "")).strip_edges()
	var asset := AssetService.find_asset(asset_path)
	if asset == null:
		return fail("Asset not found: %s" % asset_path)
	if not DeviceDropUtil.can_drop_file_on_device(inst, asset):
		return fail("Cannot load that file into %s" % inst.get_display_name())
	var old_path := inst.loaded_file_path
	var cmd := PropertyCommand.new("Load Device File", inst, "load_file", old_path, asset.path)
	HistoryUtil.execute(cmd)
	return ok(compact_device(project, inst))
