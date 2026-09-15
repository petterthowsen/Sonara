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
			"channel_id": {"type": "integer", "description": "Source channel id"},
			"target_channel_id": {"type": "integer", "description": "Bus / destination channel id"},
			"amount_db": {"type": "number", "description": "Send level in dB (default -12)"},
			"pre_fader": {"type": "boolean", "description": "Pre-fader send (default false)"},
		},
		"required": ["channel_id", "target_channel_id"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var channel = resolve_channel(project, args)
	if channel is Dictionary:
		return channel
	var target_id := int(args.get("target_channel_id", -1))
	var target: Channel = project.get_channel_by_id(target_id)
	if target == null:
		return fail("Target channel not found: %d" % target_id)
	if target_id == channel.id:
		return fail("Cannot send to self")
	var amount := float(args.get("amount_db", -12.0))
	var pre := bool(args.get("pre_fader", false))
	HistoryUtil.execute(SendAddCommand.new(channel, target_id, amount, pre))
	var text := "Added send %s → %s (%g dB%s)" % [channel.name, target.name, amount, ", pre-fader" if pre else ""]
	return ok_text(text, compact_channel(channel))
