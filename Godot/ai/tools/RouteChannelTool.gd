# RouteChannelTool.gd
class_name RouteChannelTool extends AiTool


func get_name() -> String:
	return "route_channel"


func get_description() -> String:
	return "Set a channel's output. Master, None, Hardware Out [N], or another channel name (a bus)."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel": {"type": "string", "description": "Source channel name"},
			"output": {
				"type": "string",
				"description": "Destination: a channel name, Master, None, or Hardware Out [N]",
			},
		},
		"required": ["channel", "output"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var channel = resolve_channel(project, args)
	if channel is Dictionary:
		return channel
	if channel.is_master:
		return fail("Cannot change Master's output with this tool")
	var dest_v = resolve_route_target(project, str(args.get("output", "")))
	if dest_v is Dictionary:
		return dest_v
	var dest := int(dest_v)
	if dest == channel.id:
		return fail("Cannot route a channel to itself")
	HistoryUtil.execute_property("Route Channel", channel, "set_route", channel.output_channel_id, dest)
	var text := "Routed %s → %s" % [channel.name, describe_route_target(project, dest)]
	return ok_text(text, compact_channel(project, channel))
