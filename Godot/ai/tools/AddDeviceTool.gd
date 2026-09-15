# AddDeviceTool.gd
class_name AddDeviceTool extends AiTool


func get_name() -> String:
	return "add_device"


func get_description() -> String:
	return "Add a device, SFZ, or drum-machine sample pad. For kits, pass a Drum Machine parent path and samples/asset_paths (wav from search_assets). Optional name and MIDI note; omitted values are inferred (Kick=36, Snare=38, Hat=42, Open hat=46, Crash=49, Ride=51). Do not add an empty Sampler then load_device_file."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel": {"type": "string", "description": "Mixer channel name"},
			"asset_path": {"type": "string", "description": "Asset path from search_assets"},
			"asset_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Several audio paths to add as drum pads",
			},
			"samples": {
				"type": "array",
				"description": "Drum pads as {asset_path, name, note}",
				"items": {
					"type": "object",
					"properties": {
						"asset_path": {"type": "string", "description": "Audio path from search_assets"},
						"name": {"type": "string", "description": "Pad name"},
						"note": {"type": "integer", "description": "MIDI note 0-127"},
					},
				},
			},
			"device_id": {"type": "string", "description": "Built-in or plugin device id"},
			"name": {"type": "string", "description": "Pad/device display name (single add)"},
			"note": {"type": "integer", "description": "Drum pad MIDI note 0-127 (single add)"},
			"position": {"type": "integer", "description": "Insert index, -1 appends"},
			"parent": {"type": "string", "description": "Container path (channel or, for a nested drum machine, channel + machine path)"},
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
	var parent_v = resolve_optional_parent(project, args)
	if parent_v is Dictionary:
		return parent_v
	var parent: DeviceInstance = parent_v
	var specs: Array = DeviceToolUtil.collect_pad_specs(args)
	var notes: Array[String] = []
	if specs.is_empty():
		if not args.has("asset_path") and not args.has("device_id"):
			return fail("Provide asset_path, samples, asset_paths, or device_id")
		var resolved := DeviceToolUtil.resolve_asset_fuzzy(args)
		if resolved.get("ok") == false:
			return resolved
		var asset: Asset = resolved.asset
		_add_note(notes, resolved)
		specs.append({"asset_path": asset.path, "name": str(args.get("name", "")).strip_edges(), "note": int(args.get("note", -1)), "_asset": asset})
	else:
		# Resolve every entry before adding anything, so a bad path in a batch adds nothing.
		for i in range(specs.size()):
			var spec: Dictionary = specs[i]
			var resolved := DeviceToolUtil.resolve_asset_fuzzy({"asset_path": spec.get("asset_path", "")})
			if resolved.get("ok") == false:
				return resolved
			spec["_asset"] = resolved.asset
			spec["asset_path"] = resolved.asset.path
			_add_note(notes, resolved)
			specs[i] = spec
	var added: Array = []
	for spec in specs:
		var one = DeviceToolUtil.add_one(channel, parent, spec, args)
		if one is Dictionary and one.get("ok") == false:
			if added.is_empty():
				return one
			break
		if one is DeviceInstance:
			added.append(one)
	if added.is_empty():
		return fail("Device was not added")
	var result: Dictionary
	if added.size() == 1:
		result = _one_result(project, channel, added[0])
	else:
		result = _several_result(project, channel, parent, added)
	if not notes.is_empty():
		result.text = "%s\n%s" % [result.text, "\n".join(notes)]
	return result


## Append `resolved.note` to `notes` when the lookup was a fuzzy match.
func _add_note(notes: Array[String], resolved: Dictionary) -> void:
	var note := str(resolved.get("note", ""))
	if not note.is_empty():
		notes.append(note)


## `Added <name> to <channel> -> path "<path>"`, with `, pad note N` for drum pads.
func _one_result(project: Project, channel: Channel, inst: DeviceInstance) -> Dictionary:
	var data := compact_device(project, inst)
	var text := "Added %s to %s → path \"%s\"" % [inst.get_display_name(), channel.name, data.path]
	if inst.slot_note >= 0:
		text += ", pad note %d" % inst.slot_note
	return ok_text(text, data)


## `Added N pads to <parent path>:` then `- <name> (note N)` per pad.
func _several_result(project: Project, channel: Channel, parent: DeviceInstance, added: Array) -> Dictionary:
	var host_path := parent.address_path(project) if parent else channel.name
	var rows: Array = []
	var lines: Array = ["Added %d pads to %s:" % [added.size(), host_path]]
	for inst in added:
		rows.append(compact_device(project, inst))
		var note_part := (" (note %d)" % inst.slot_note) if inst.slot_note >= 0 else ""
		lines.append("- %s%s" % [inst.get_display_name(), note_part])
	return ok_text("\n".join(lines), {"devices": rows, "count": rows.size()})
