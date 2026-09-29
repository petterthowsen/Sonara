# SetMixerTool.gd
class_name SetMixerTool extends AiTool


func get_name() -> String:
	return "set_mixer"


func get_description() -> String:
	return "Set mixer volume_db (-60 to 12), pan mode and pan values, mute, and/or solo on a channel. Pan values must fit the mode: pan (balance, combined, mono), pan_width (combined), pan_left/pan_right (dual)."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel": {"type": "string", "description": "Mixer channel name"},
			"volume_db": {"type": "number", "description": "Fader level in dB"},
			"pan_mode": {"type": "string", "enum": ["balance", "combined", "dual", "mono"], "description": "Pan mode. Switching keeps the current placement where possible"},
			"pan": {"type": "number", "description": "Pan position -1 (L) to 1 (R). Balance, combined and mono only"},
			"pan_width": {"type": "number", "description": "Stereo width -1 to 1 (negative swaps sides). Combined only"},
			"pan_left": {"type": "number", "description": "Left channel position -1 to 1. Dual only"},
			"pan_right": {"type": "number", "description": "Right channel position -1 to 1. Dual only"},
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
			changes.append("volume %s dB" % str(snappedf(vol, 0.01)))
	var pan_result := _pan_command(channel, args)
	if pan_result.has("error"):
		return fail(pan_result.error)
	if pan_result.has("cmd"):
		cmds.append(pan_result.cmd)
		changes.append(pan_result.change)
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


## Validates the pan arguments against the target mode and builds one `set_pan_state` command.
## Returns {} (nothing to do), {error} (refused, nothing changed) or {cmd, change}.
static func _pan_command(channel: Channel, args: Dictionary) -> Dictionary:
	var mode: int = channel.pan_mode
	if args.has("pan_mode"):
		var key := "STEREO_" + str(args.pan_mode).to_upper() if str(args.pan_mode).to_lower() != "mono" else "MONO"
		if not Channel.PanMode.has(key):
			return {"error": "Unknown pan_mode \"%s\". Use balance, combined, dual or mono." % args.pan_mode}
		mode = Channel.PanMode[key]
	var uses_position := mode != Channel.PanMode.STEREO_DUAL
	var mode_name: String = Channel.PanMode.keys()[mode].trim_prefix("STEREO_").to_lower()
	for key in ["pan", "pan_width", "pan_left", "pan_right"]:
		if not args.has(key):
			continue
		var fits: bool
		match key:
			"pan": fits = uses_position
			"pan_width": fits = mode == Channel.PanMode.STEREO_COMBINED
			_: fits = mode == Channel.PanMode.STEREO_DUAL
		if not fits:
			return {"error": "%s does not apply in %s pan mode; pass pan_mode to switch first." % [key, mode_name]}
	var before := channel.get_pan_state()
	var state := before.duplicate()
	if mode != channel.pan_mode:
		state = Channel.convert_pan_state(before, mode as Channel.PanMode)
	if args.has("pan"):
		state["pan"] = clampf(float(args.pan), -1.0, 1.0)
	if args.has("pan_width"):
		state["width"] = clampf(float(args.pan_width), -1.0, 1.0)
	if args.has("pan_left"):
		state["left"] = clampf(float(args.pan_left), -1.0, 1.0)
	if args.has("pan_right"):
		state["right"] = clampf(float(args.pan_right), -1.0, 1.0)
	if state == before:
		return {}
	var cmd := PropertyCommand.new("Set Pan", channel, "set_pan_state", before, state)
	var probe := Channel.new(0)
	probe.set_pan_state(state)
	return {"cmd": cmd, "change": "pan " + AiTool.describe_pan(probe)}
