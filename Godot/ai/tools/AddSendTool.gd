# AddSendTool.gd
class_name AddSendTool extends AiTool


func get_name() -> String:
	return "add_send"


func get_description() -> String:
	return "Add a send from a channel to a bus. amount_db defaults to -12. Optional pre_fader."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel": {"type": "string", "description": "Source channel name"},
			"target": {"type": "string", "description": "Bus / destination channel name"},
			"amount_db": {"type": "number", "description": "Send level in dB (default -12)"},
			"pre_fader": {"type": "boolean", "description": "Pre-fader send (default false)"},
		},
		"required": ["channel", "target"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var channel = resolve_channel(project, args)
	if channel is Dictionary:
		return channel
	var target = resolve_channel(project, args, "target")
	if target is Dictionary:
		return target
	if target.id == channel.id:
		return fail("Cannot send to self")
	var amount := float(args.get("amount_db", -12.0))
	var pre := bool(args.get("pre_fader", false))
	HistoryUtil.execute(SendAddCommand.new(channel, target.id, amount, pre))
	var text := "Added send %s → %s (%s dB%s)" % [channel.name, target.name, str(snappedf(amount, 0.01)), ", pre-fader" if pre else ""]
	return ok_text(text, compact_channel(project, channel))
