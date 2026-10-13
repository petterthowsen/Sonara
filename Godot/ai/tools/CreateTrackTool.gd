# CreateTrackTool.gd
class_name CreateTrackTool extends AiTool


func get_name() -> String:
	return "create_track"


func get_description() -> String:
	return "Create an arrangement track. kind is instrument, audio, folder, or group. Prefer one create_track call with asset_path (or device_id) and output over separate add_device/route_channel calls. into (or an output naming a group or folder bus) places the new track inside that group or folder, last."


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
			"asset_path": {"type": "string", "description": "Instrument tracks only: SFZ/plugin/audio asset path from search_assets, added to the new channel (an audio file makes a Sampler)"},
			"asset_paths": {"type": "array", "items": {"type": "string"}, "description": "Instrument tracks only: audio files for one multisample Sampler, a zone per file"},
			"device_id": {"type": "string", "description": "Instrument tracks only: built-in or plugin device id, added to the new channel"},
			"output": {"type": "string", "description": "Route the new channel's output: a channel name, Master, None, or Hardware Out [N]. A group or folder bus also places the track inside it"},
			"into": {"type": "string", "description": "Group or folder to create the track inside (added last). Its channel then routes to the group or folder bus"},
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
	var track_name := name_arg(args, "name", "Track")
	if track_name.is_empty():
		track_name = "Track"
	# Resolve the device/asset before creating anything, so a bad id leaves no half-made track.
	var resolved: Dictionary = {}
	if args.has("asset_path") or args.has("device_id"):
		var resolved_v := DeviceToolUtil.resolve_asset_fuzzy(args)
		if resolved_v.get("ok") == false:
			return resolved_v
		resolved = resolved_v
	var samples: Array = []
	var sample_notes: Array[String] = []
	for item in args.get("asset_paths", []):
		var sample_v := DeviceToolUtil.resolve_asset_fuzzy({"asset_path": str(item)}, "audio")
		if sample_v.get("ok") == false:
			return sample_v
		if sample_v.asset.type != Asset.TYPE.Audio:
			return fail("asset_paths takes audio files; %s is not one" % str(item))
		samples.append(sample_v.asset)
		if not str(sample_v.get("note", "")).is_empty():
			sample_notes.append(str(sample_v.note))
	if not samples.is_empty() and (kind != "instrument" or not resolved.is_empty()):
		return fail("asset_paths needs kind instrument and no asset_path or device_id")
	var container_v: Variant = _resolve_container(project, args)
	if container_v is Dictionary:
		return container_v
	var container: Track = container_v
	var cmd := TrackCreateCommand.new(project, kind, track_name)
	HistoryUtil.execute(cmd)
	if cmd.track == null:
		return fail("Failed to create track")
	var placed := false
	if container:
		placed = _place_inside(project, cmd.track, container)
	var data := compact_track(cmd.track)
	var text := "Created %s track \"%s\"" % [kind, cmd.track.name]
	if placed:
		text += " inside \"%s\"" % container.name
	if cmd.channel:
		data["channel"] = compact_channel(project, cmd.channel)
	var warnings: Array[String] = []
	var note := ""
	var device_text := ""
	if cmd.channel and not resolved.is_empty():
		var asset: Asset = resolved.asset
		var spec := {"asset_path": asset.path, "_asset": asset}
		var device_v: Variant = DeviceToolUtil.add_one(cmd.channel, null, spec, args)
		if device_v is DeviceInstance:
			await SfzKeyInfoUtil.watch(device_v).call()
			data["device"] = compact_device(project, device_v)
			text += " with %s" % device_v.get_display_name()
			note = str(resolved.get("note", ""))
			device_text = SfzKeyInfoUtil.text_for(device_v, data["device"].path)
		else:
			warnings.append("device not added: %s" % str(device_v.get("error", "")))
	if cmd.channel and not samples.is_empty():
		var sampler_v: Variant = DeviceToolUtil.add_sampler(cmd.channel, null, samples, {})
		if sampler_v is DeviceInstance:
			data["device"] = compact_device(project, sampler_v)
			text += " with %s" % sampler_v.get_display_name()
			if SamplerToolUtil.is_multisample(sampler_v):
				device_text = SamplerToolUtil.describe(sampler_v)
			note = "\n".join(sample_notes)
		else:
			warnings.append("Sampler not added: %s" % str(sampler_v.get("error", "")))
	# Inside a group or folder bus the output follows the parent; routing elsewhere would fight it.
	var routing_locked := placed and (container.is_group() or container.is_folder_bus())
	if cmd.channel and routing_locked:
		text += ", output → %s" % describe_route_target(project, cmd.channel.output_channel_id)
		if args.has("output"):
			var dest_v = resolve_route_target(project, str(args.output))
			if not dest_v is Dictionary and int(dest_v) != cmd.channel.output_channel_id:
				warnings.append("output ignored: tracks inside \"%s\" route to it" % container.name)
	elif container and not placed:
		warnings.append("could not place the track inside \"%s\"" % container.name)
	if cmd.channel and args.has("output") and not routing_locked:
		var route_v: Variant = _route(project, cmd.channel, args)
		if route_v is String:
			text += ", output → %s" % route_v
		else:
			warnings.append("output not routed: %s" % str(route_v.get("error", "")))
	if not note.is_empty():
		text += "\n%s" % note
	if not device_text.is_empty():
		text += "\n%s" % device_text
	for w in warnings:
		text += "\nWarning: %s" % w
	return ok_text(text, data)


## The group or folder to create the track inside: `into`, else an `output` that names a group
## channel or folder bus. Returns a Track, null (top level), or a fail dict.
func _resolve_container(project: Project, args: Dictionary) -> Variant:
	var into_name := str(args.get("into", "")).strip_edges()
	if not into_name.is_empty():
		if NameStyle.key(into_name) == "top":
			return null
		var parent: Track = project.find_by_name(into_name).get("track")
		if parent == null:
			return _not_found(project, "group or folder", into_name)
		if not parent.can_contain_tracks():
			return fail("\"%s\" is not a group or folder" % parent.name)
		return parent
	if not args.has("output"):
		return null
	var dest_v = resolve_route_target(project, str(args.output))
	if dest_v is Dictionary:
		return null # _route reports the bad output later
	var dest_ch: Channel = project.get_channel_by_id(int(dest_v))
	var paired: Track = project.get_channel_paired_track(dest_ch) if dest_ch else null
	if paired and (paired.is_group() or paired.is_folder_bus()):
		return paired
	return null


## Move the new track to the end of `container` as its own undo step. True when it moved.
func _place_inside(project: Project, track: Track, container: Track) -> bool:
	if not project.can_place_track(track, container.id):
		return false
	var siblings: Array[Track] = project._sorted_track_siblings(container.id)
	var after: Track = siblings[-1] if not siblings.is_empty() else null
	var before := TrackReorderCommand.capture_layout(project)
	if not project.place_track(track, container.id, after):
		return false
	HistoryUtil.record(TrackReorderCommand.new(project, before, TrackReorderCommand.capture_layout(project)))
	if not container.is_folder_expanded:
		container.is_folder_expanded = true
	return true


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
