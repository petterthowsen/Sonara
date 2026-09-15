# ListChannelsTool.gd
class_name ListChannelsTool extends AiTool


func get_name() -> String:
	return "list_channels"


func get_description() -> String:
	return "List mixer channels: name, type, volume_db, pan, mute, solo, output, sends, device names. Route targets are Master, None, Hardware Out [N], or a channel name."


func execute(_args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var channels: Array = []
	for c in project.channels:
		channels.append(compact_channel(project, c))
	return ok({"channels": channels})
