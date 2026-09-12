# SetMixerTool.gd
class_name SetMixerTool extends AiTool


func get_name() -> String:
	return "set_mixer"


func get_description() -> String:
	return "Set mixer volume_db (-60 to 12), pan (-1 to 1), mute, and/or solo on a channel."


func is_read_only() -> bool:
	return false


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel_id": {"type": "integer", "description": "Mixer channel id"},
			"volume_db": {"type": "number", "description": "Fader level in dB"},
			"pan": {"type": "number", "description": "Stereo pan -1 (L) to 1 (R)"},
			"mute": {"type": "boolean"},
			"solo": {"type": "boolean"},
		},
		"required": ["channel_id"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var channel = resolve_channel(project, args)
	if channel is Dictionary:
		return channel
	var cmds: Array[Command] = []
	if args.has("volume_db"):
		var vol := clampf(float(args.volume_db), -60.0, 12.0)
		if vol != channel.volume:
			cmds.append(PropertyCommand.new("Set Volume", channel, "set_volume", channel.volume, vol))
	if args.has("pan"):
		var pan := clampf(float(args.pan), -1.0, 1.0)
		if pan != channel.pan:
			cmds.append(PropertyCommand.new("Set Pan", channel, "set_pan", channel.pan, pan))
	if args.has("mute"):
		var mute := bool(args.mute)
		if mute != channel.mute:
			cmds.append(PropertyCommand.new("Set Mute", channel, "set_mute", channel.mute, mute))
	if args.has("solo"):
		var solo := bool(args.solo)
		if solo != channel.solo:
			cmds.append(PropertyCommand.new("Set Solo", channel, "set_solo", channel.solo, solo))
	if cmds.is_empty():
		return ok(compact_channel(channel))
	if cmds.size() == 1:
		HistoryUtil.execute(cmds[0])
	else:
		HistoryUtil.execute(MacroCommand.new("Set Mixer", cmds))
	return ok(compact_channel(channel))
