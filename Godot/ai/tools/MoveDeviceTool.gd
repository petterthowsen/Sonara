# MoveDeviceTool.gd
class_name MoveDeviceTool extends AiTool


func get_name() -> String:
	return "move_device"


func get_description() -> String:
	return "Reorder a device or move it into a container. Use path/instance_id, to_position, and optional parent path. Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Device to move"},
			"instance_id": {"type": "string", "description": "Device instance id"},
			"channel_id": {"type": "integer", "description": "Channel id when path is relative"},
			"to_position": {"type": "integer", "description": "Index in the destination host, -1 appends"},
			"parent": {"type": "string", "description": "Destination container path; omit to stay on the same host"},
			"parent_instance_id": {"type": "string", "description": "Destination container instance_id"},
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
	var channel: Channel = project.get_channel_by_id(inst.channel_id)
	if channel == null:
		return fail("Channel not found for device")
	var to_parent: DeviceInstance = inst.get_parent_device()
	if args.has("parent") or args.has("parent_instance_id"):
		var parent_v = resolve_optional_parent(project, args)
		if parent_v is Dictionary:
			return parent_v
		to_parent = parent_v
	var to_position := int(args.get("to_position", -1))
	if not DeviceDropUtil.can_drop_instance_on_host(channel, inst, to_parent):
		return fail("Cannot move that device onto the destination host")
	DeviceDropUtil.drop_instance(channel, inst, to_parent, to_position)
	var data := compact_device(project, inst)
	return ok_text("Moved %s to \"%s\"" % [inst.get_display_name(), data.path], data)
