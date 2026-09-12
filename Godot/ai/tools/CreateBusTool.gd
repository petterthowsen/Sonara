# CreateBusTool.gd
class_name CreateBusTool extends AiTool


func get_name() -> String:
	return "create_bus"


func get_description() -> String:
	return "Create a mixer bus channel (no arrangement track). Undoable."


func is_read_only() -> bool:
	return false


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Bus display name"},
		},
		"required": ["name"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var bus_name := str(args.get("name", "Bus")).strip_edges()
	if bus_name.is_empty():
		bus_name = "Bus"
	var cmd := BusCreateCommand.new(project, bus_name)
	HistoryUtil.execute(cmd)
	if cmd.channel == null:
		return fail("Failed to create bus")
	return ok(compact_channel(cmd.channel))
