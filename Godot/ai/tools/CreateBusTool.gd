# CreateBusTool.gd
class_name CreateBusTool extends AiTool


func get_name() -> String:
	return "create_bus"


func get_description() -> String:
	return "Create a mixer bus channel (no arrangement track). Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Bus display name"},
			"output": {"type": "string", "description": "Route the bus's output: a channel name, Master, None, or Hardware Out [N] (default Master)"},
		},
		"required": ["name"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var bus_name := name_arg(args, "name", "Bus")
	if bus_name.is_empty():
		bus_name = "Bus"
	var cmd := BusCreateCommand.new(project, bus_name)
	HistoryUtil.execute(cmd)
	if cmd.channel == null:
		return fail("Failed to create bus")
	var text := "Created bus \"%s\"" % cmd.channel.name
	if args.has("output"):
		var dest_v = resolve_route_target(project, str(args.output))
		if dest_v is Dictionary:
			return dest_v
		var dest := int(dest_v)
		if dest != cmd.channel.id:
			HistoryUtil.execute_property("Route Channel", cmd.channel, "set_route", cmd.channel.output_channel_id, dest)
		text += ", output → %s" % describe_route_target(project, cmd.channel.output_channel_id)
	return ok_text(text, compact_channel(project, cmd.channel))
