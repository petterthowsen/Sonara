# AutomationToolUtil.gd
# Shared by the automation lane tools: resolve a `track` + `param` (+ `path`) to an AutomationTarget,
# build a lane, and describe lanes in real units.
class_name AutomationToolUtil extends RefCounted


## Parameter-argument schema fragment shared by the automation tools.
static func target_properties() -> Dictionary:
	return {
		"track": {"type": "string", "description": "Track name"},
		"param": {
			"type": "string",
			"description": "\"Volume\", \"Pan\", \"Send <bus name>\", \"CC <0-119>\", or a device parameter name (then pass path)",
		},
		"path": {
			"type": "string",
			"description": "Device path (as in get_device), required for a device parameter. The device must be on the track's own channel",
		},
	}


## The track's own mixer channel, or a fail dict (a plain folder has none, so no lanes).
static func linked_channel(track: Track) -> Variant:
	var ch := track.get_linked_channel()
	if ch == null:
		return AiTool.fail("\"%s\" has no mixer channel, so it can't have automation lanes" % track.name)
	return ch


## Resolve `param` (and `path` for a device parameter) on `track` to an `AutomationTarget`, or a
## fail dict (check `is Dictionary`).
static func resolve_target(project: Project, track: Track, args: Dictionary) -> Variant:
	var channel_v = linked_channel(track)
	if channel_v is Dictionary:
		return channel_v
	var channel: Channel = channel_v
	var param_name := str(args.get("param", "")).strip_edges()
	if param_name.is_empty():
		return AiTool.fail("param is required")
	var path := str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return _channel_target(project, channel, param_name)
	return _device_target(project, track, channel, args, param_name)


static func _channel_target(project: Project, channel: Channel, param_name: String) -> Variant:
	var key := NameStyle.key(param_name)
	if key == "volume":
		return AutomationTarget.channel_volume()
	if key == "pan":
		return AutomationTarget.channel_pan()
	if key.begins_with("cc"):
		var num := key.substr(2).strip_edges()
		if num.is_valid_int():
			var n := num.to_int()
			if n < 0 or n > Midi.CC_LANE_MAX:
				return AiTool.fail("CC must be 0-%d (got %d)" % [Midi.CC_LANE_MAX, n])
			return AutomationTarget.midi_cc(n)
	if key.begins_with("send"):
		var want := NameStyle.key(key.substr(4).lstrip(" :").strip_edges())
		if not want.is_empty():
			var names: PackedStringArray = []
			for i in range(channel.send_channels.size()):
				var target_ch := project.get_channel_by_id(channel.send_channels[i].target_channel_id)
				if target_ch == null:
					continue
				names.append(target_ch.name)
				if NameStyle.key(target_ch.name) == want:
					return AutomationTarget.send_amount(i)
			if names.is_empty():
				return AiTool.fail("\"%s\" has no sends. Add one with add_send first" % channel.name)
			return AiTool.fail("\"%s\" has no send to '%s'. Its sends: %s" % [channel.name, key.substr(4).lstrip(" :").strip_edges(), ", ".join(names)])
	return AiTool.fail("Unknown param '%s'. Use Volume, Pan, Send <bus>, CC <0-119>, or pass path for a device parameter" % param_name)


static func _device_target(project: Project, track: Track, channel: Channel, args: Dictionary, param_name: String) -> Variant:
	var inst_v = AiTool.resolve_device(project, {"path": args.path})
	if inst_v is Dictionary:
		return inst_v
	var inst: DeviceInstance = inst_v
	if inst.get_channel() != channel:
		return AiTool.fail("Device \"%s\" is not on %s's own channel (\"%s\"). Lanes drive the track's own channel" % [inst.name, track.name, channel.name])
	var param := DeviceToolUtil.match_param(inst.get_parameters(), param_name)
	if param == null:
		return AiTool.fail("No parameter '%s' on %s. Use get_device to list parameters" % [param_name, inst.name])
	if inst.is_controller_parameter(param):
		return AiTool.fail("\"%s\" is a MIDI controller; use param \"CC %d\" without path" % [param.name, param.id])
	if not param.is_automation_safe:
		return AiTool.fail("\"%s\" on %s can't be automated" % [param.name, inst.name])
	var indices := device_index_path(inst)
	if indices.is_empty():
		return AiTool.fail("Could not locate %s on its channel" % inst.name)
	var target := AutomationTarget.device_param(indices, param.id)
	if target.resolve(channel) != inst:
		return AiTool.fail("Could not address %s for automation" % inst.name)
	return target


## Indices from the channel root down to `inst` (each an index into `channel.devices` or the
## parent's `children`), as `AutomationTarget.device_path` wants. Empty when it can't be found.
static func device_index_path(inst: DeviceInstance) -> Array:
	var out: Array = []
	var current: DeviceInstance = inst
	while current != null:
		var parent := current.get_parent_device()
		var host: Array = parent.children if parent else (current.get_channel().devices if current.get_channel() else [])
		var idx := host.find(current)
		if idx < 0:
			return []
		out.push_front(idx)
		current = parent
	return out


## A lane unique within `track`. Ids are per-track because that is the OSC addressing scope.
static func unique_lane_id(track: Track) -> String:
	var used: Dictionary = {}
	for lane in track.automation_lanes:
		used[lane.id] = true
	var n := track.automation_lanes.size()
	while used.has("lane%d" % n):
		n += 1
	return "lane%d" % n


## A new, unattached lane for `target` with a fresh id and the configured height.
static func new_lane(track: Track, target: AutomationTarget) -> AutomationLane:
	var lane := AutomationLane.new(unique_lane_id(track), target)
	lane.height = track.height if Settings.get_value("arranger/sync_track_and_lane_height") \
		else Settings.get_value("appearance/automation_lane_height")
	return lane


## `{param, points, bypassed?, values | range}` for one lane, in real units.
static func describe_lane(track: Track, lane: AutomationLane) -> Dictionary:
	var channel := track.get_linked_channel()
	var project := track.get_project_ref()
	var row := {"param": lane.target.display_name(channel), "points": lane.points.size()}
	if lane.bypassed:
		row["bypassed"] = true
	if project == null or lane.points.is_empty():
		return row
	if lane.points.size() <= 16:
		var values: Array = []
		for p in lane.points:
			values.append([_bbt(project, p.tick), lane.target.format_value(channel, p.value)])
		row["values"] = values
	else:
		row["range"] = [_bbt(project, lane.points[0].tick), _bbt(project, lane.points[-1].tick)]
	return row


static func _bbt(project: Project, ticks: int) -> String:
	return ClipTextTime.format_bbt(ticks, project.ppq, project.time_numerator, project.time_denominator)
