# ListChannelsTool.gd
class_name ListChannelsTool extends AiTool


func get_name() -> String:
	return "list_channels"


func get_description() -> String:
	return "List mixer channels: id, name, type, volume_db, pan, mute, solo, output_channel_id, sends, device names. Master is id 1. Hardware outs are 1000+."


func execute(_args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var channels: Array = []
	for c in project.channels:
		channels.append(compact_channel(c))
	return ok({"channels": channels})
