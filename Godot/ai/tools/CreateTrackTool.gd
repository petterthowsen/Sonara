# CreateTrackTool.gd
class_name CreateTrackTool extends AiTool


func get_name() -> String:
	return "create_track"


func get_description() -> String:
	return "Create an arrangement track. kind is instrument, audio, folder, or group. Prefer one create_track call with asset_path (or device_id) and output_channel_id over separate add_device/route_channel calls."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Track display name"},
			"kind": {
				"type": "string",
				"enum": ["instrument", "audio", "folder", "group"],
				"description": "Track kind (maps to TrackCreateCommand)",
			},
			"asset_path": {"type": "string", "description": "Instrument tracks only: SFZ/plugin asset path from search_assets, added to the new channel"},
			"device_id": {"type": "string", "description": "Instrument tracks only: built-in or plugin device id, added to the new channel"},
			"output_channel_id": {"type": "integer", "description": "Route the new channel's output: 0 none, 1 master, 2-999 bus, 1000+ hardware"},
		},
		"required": ["name", "kind"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var kind := str(args.get("kind", "instrument")).to_lower()
	if kind not in ["instrument", "audio", "folder", "group"]:
		return fail("kind must be instrument, audio, folder, or group")
	var track_name := str(args.get("name", "Track")).strip_edges()
	if track_name.is_empty():
		track_name = "Track"
	var cmd := TrackCreateCommand.new(project, kind, track_name)
	HistoryUtil.execute(cmd)
	if cmd.track == null:
		return fail("Failed to create track")
	var data := compact_track(cmd.track)
	var text := "Created %s track \"%s\" (track %d" % [kind, cmd.track.name, cmd.track.id]
	if cmd.channel:
		data["channel"] = compact_channel(cmd.channel)
		text += ", channel %d)" % cmd.channel.id
	else:
		text += ")"
	var warnings: Array[String] = []
	if cmd.channel and (args.has("asset_path") or args.has("device_id")):
		var device_v: Variant = _add_device(project, cmd.channel, args)
		if device_v is DeviceInstance:
			data["device"] = compact_device(project, device_v)
			text += " with %s (id %s)" % [device_v.get_display_name(), device_v.id]
		else:
			warnings.append("device not added: %s" % str(device_v.get("error", "")))
	if cmd.channel and args.has("output_channel_id"):
		var route_v: Variant = _route(project, cmd.channel, args)
		if route_v is String:
			text += ", output → %s" % route_v
		else:
			warnings.append("output not routed: %s" % str(route_v.get("error", "")))
	for w in warnings:
		text += "\nWarning: %s" % w
	return ok_text(text, data)


## Add the requested device/asset to the new channel. Returns the `DeviceInstance` or a fail dict.
func _add_device(_project: Project, channel: Channel, args: Dictionary) -> Variant:
	var asset := DeviceToolUtil.resolve_asset(args)
	if asset == null:
		return fail("Asset or device not found")
	var spec := {"asset_path": asset.path, "_asset": asset}
	return DeviceToolUtil.add_one(channel, null, spec, args)


## Route the new channel's output. Returns the destination's display string or a fail dict.
func _route(project: Project, channel: Channel, args: Dictionary) -> Variant:
	var dest := int(args.get("output_channel_id", 1))
	if dest == channel.id:
		return fail("Cannot route a channel to itself")
	if dest != 0 and dest != 1 and dest < 1000 and project.get_channel_by_id(dest) == null:
		return fail("Target channel not found: %d" % dest)
	HistoryUtil.execute_property("Route Channel", channel, "set_route", channel.output_channel_id, dest)
	return describe_route_target(project, dest)
