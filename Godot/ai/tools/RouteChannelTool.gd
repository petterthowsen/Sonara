# RouteChannelTool.gd
class_name RouteChannelTool extends AiTool


func get_name() -> String:
	return "route_channel"


func get_description() -> String:
	return "Set a channel's output. 1 = Master, 0 = no output, 1000+ = hardware out, other ids = buses."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel_id": {"type": "integer", "description": "Source channel id"},
			"output_channel_id": {
				"type": "integer",
				"description": "Destination: 0 none, 1 master, 2-999 bus, 1000+ hardware",
			},
		},
		"required": ["channel_id", "output_channel_id"],
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
	var dest := int(args.get("output_channel_id", 1))
	if dest == channel.id:
		return fail("Cannot route a channel to itself")
	HistoryUtil.execute_property("Route Channel", channel, "set_route", channel.output_channel_id, dest)
	var text := "Routed %s (%d) → %s" % [channel.name, channel.id, describe_route_target(project, dest)]
	return ok_text(text, compact_channel(channel))
