# CreateTrackTool.gd
class_name CreateTrackTool extends AiTool


func get_name() -> String:
	return "create_track"


func get_description() -> String:
	return "Create an arrangement track. kind is instrument, audio, folder, or group. Prefer one create_track call with asset_path (or device_id) and output over separate add_device/route_channel calls."


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
			"output": {"type": "string", "description": "Route the new channel's output: a channel name, Master, None, or Hardware Out [N]"},
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
	# Resolve the device/asset before creating anything, so a bad id leaves no half-made track.
	var resolved: Dictionary = {}
	if args.has("asset_path") or args.has("device_id"):
		var resolved_v := DeviceToolUtil.resolve_asset_fuzzy(args)
		if resolved_v.get("ok") == false:
			return resolved_v
		resolved = resolved_v
	var cmd := TrackCreateCommand.new(project, kind, track_name)
	HistoryUtil.execute(cmd)
	if cmd.track == null:
		return fail("Failed to create track")
	var data := compact_track(cmd.track)
	var text := "Created %s track \"%s\"" % [kind, cmd.track.name]
	if cmd.channel:
		data["channel"] = compact_channel(project, cmd.channel)
	var warnings: Array[String] = []
	var note := ""
	if cmd.channel and not resolved.is_empty():
		var asset: Asset = resolved.asset
		var spec := {"asset_path": asset.path, "_asset": asset}
		var device_v: Variant = DeviceToolUtil.add_one(cmd.channel, null, spec, args)
		if device_v is DeviceInstance:
			data["device"] = compact_device(project, device_v)
			text += " with %s" % device_v.get_display_name()
			note = str(resolved.get("note", ""))
		else:
			warnings.append("device not added: %s" % str(device_v.get("error", "")))
	if cmd.channel and args.has("output"):
		var route_v: Variant = _route(project, cmd.channel, args)
		if route_v is String:
			text += ", output → %s" % route_v
		else:
			warnings.append("output not routed: %s" % str(route_v.get("error", "")))
	if not note.is_empty():
		text += "\n%s" % note
	for w in warnings:
		text += "\nWarning: %s" % w
	return ok_text(text, data)


## Route the new channel's output. Returns the destination's display string or a fail dict.
func _route(project: Project, channel: Channel, args: Dictionary) -> Variant:
	var dest_v = resolve_route_target(project, str(args.get("output", "Master")))
	if dest_v is Dictionary:
		return dest_v
	var dest := int(dest_v)
	if dest == channel.id:
		return fail("Cannot route a channel to itself")
	HistoryUtil.execute_property("Route Channel", channel, "set_route", channel.output_channel_id, dest)
	return describe_route_target(project, dest)
