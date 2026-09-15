# SetMixerTool.gd
class_name SetMixerTool extends AiTool


func get_name() -> String:
	return "set_mixer"


func get_description() -> String:
	return "Set mixer volume_db (-60 to 12), pan (-1 to 1), mute, and/or solo on a channel."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel": {"type": "string", "description": "Mixer channel name"},
			"volume_db": {"type": "number", "description": "Fader level in dB"},
			"pan": {"type": "number", "description": "Stereo pan -1 (L) to 1 (R)"},
			"mute": {"type": "boolean"},
			"solo": {"type": "boolean"},
		},
		"required": ["channel"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var channel = resolve_channel(project, args)
	if channel is Dictionary:
		return channel
	var cmds: Array[Command] = []
	var changes: Array[String] = []
	if args.has("volume_db"):
		var vol := clampf(float(args.volume_db), -60.0, 12.0)
		if vol != channel.volume:
			cmds.append(PropertyCommand.new("Set Volume", channel, "set_volume", channel.volume, vol))
			changes.append("volume %g dB" % vol)
	if args.has("pan"):
		var pan := clampf(float(args.pan), -1.0, 1.0)
		if pan != channel.pan:
			cmds.append(PropertyCommand.new("Set Pan", channel, "set_pan", channel.pan, pan))
			changes.append("pan %g" % pan)
	if args.has("mute"):
		var mute := bool(args.mute)
		if mute != channel.mute:
			cmds.append(PropertyCommand.new("Set Mute", channel, "set_mute", channel.mute, mute))
			changes.append("mute" if mute else "unmute")
	if args.has("solo"):
		var solo := bool(args.solo)
		if solo != channel.solo:
			cmds.append(PropertyCommand.new("Set Solo", channel, "set_solo", channel.solo, solo))
			changes.append("solo" if solo else "unsolo")
	if not cmds.is_empty():
		HistoryUtil.execute_many("Set Mixer", cmds)
	var text := "%s: %s" % [channel.name, ", ".join(changes)] if not changes.is_empty() else "%s: no change" % channel.name
	return ok_text(text, compact_channel(project, channel))
