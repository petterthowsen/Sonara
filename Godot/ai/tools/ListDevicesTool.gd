# ListDevicesTool.gd
class_name ListDevicesTool extends AiTool


func get_name() -> String:
	return "list_devices"


func get_description() -> String:
	return "List devices as nested rows: path, name, position, and (when set) bypass, loaded_file, slot_note, children. Optional channel; otherwise the focused channel, or all channels."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel": {"type": "string", "description": "Mixer channel name (omit for focused or all)"},
		},
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	if args.has("channel"):
		var channel = resolve_channel(project, args)
		if channel is Dictionary:
			return channel
		return ok(_channel_payload(project, channel))
	var focused: Channel = null
	if Sonara and Sonara.editor:
		focused = Sonara.editor.focused_channel
	if focused:
		return ok(_channel_payload(project, focused))
	var channels: Array = []
	for c in project.channels:
		channels.append(_channel_payload(project, c))
	return ok({"channels": channels})


## Nested device list for one mixer channel.
func _channel_payload(project: Project, channel: Channel) -> Dictionary:
	var devices: Array = []
	for d in channel.devices:
		if d is DeviceInstance and d.device:
			devices.append(compact_device(project, d))
	return {"channel": channel.name, "devices": devices}
