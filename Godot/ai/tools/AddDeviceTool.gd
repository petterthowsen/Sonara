# AddDeviceTool.gd
class_name AddDeviceTool extends AiTool


func get_name() -> String:
	return "add_device"


func get_description() -> String:
	return "Add a device, SFZ, Sampler, or drum-machine sample pad. Audio files on a channel make a Sampler: several become one multisample Sampler with a zone per file (keys from the note names in the file names). For kits, pass a Drum Machine parent path and samples/asset_paths (wav from search_assets): one pad per file, or with multisample true one pad holding them all. A samples item with folder instead of asset_path makes one multisample pad from every audio file in that library folder, so a kit with a folder per drum is one call. Multisample pads are laid out per as (default velocity_layers when the file names have no note names). Optional name and MIDI note; omitted values are inferred (Kick=36, Snare=38, Hat=42, Open hat=46, Crash=49, Ride=51); an asked note that is taken fails. Do not add an empty Sampler then load_device_file."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel": {"type": "string", "description": "Mixer channel name"},
			"asset_path": {"type": "string", "description": "Asset path from search_assets"},
			"asset_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Several audio paths: drum pads, or the zones of one multisample Sampler",
			},
			"samples": {
				"type": "array",
				"description": "Drum pads as {asset_path or folder, name, note}",
				"items": {
					"type": "object",
					"properties": {
						"asset_path": {"type": "string", "description": "Audio path from search_assets"},
						"folder": {"type": "string", "description": "Library folder (from list_assets): one multisample pad of every audio file directly in it"},
						"name": {"type": "string", "description": "Pad name"},
						"note": {"type": "integer", "description": "MIDI note 0-127"},
					},
				},
			},
			"device_id": {"type": "string", "description": "Built-in or plugin device id"},
			"name": {"type": "string", "description": "Pad/device display name (single add)"},
			"note": {"type": "integer", "description": "Drum pad MIDI note 0-127 (single add)"},
			"position": {"type": "integer", "description": "Insert index, -1 appends"},
			"multisample": {"type": "boolean", "description": "Drum Machine parent: put all the samples on one pad as a multisample Sampler"},
			"as": {"type": "string", "enum": SamplerToolUtil.SPREADS, "description": "Zone layout of a new multisample Sampler: keys (from note names in the file names; pitched instruments), velocity_layers (every key, velocity split in name order, softest first), round_robin (every key and velocity, taking turns). Default velocity_layers on a drum pad whose files have no note names, else keys"},
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
	var spread := str(args.get("as", "")).strip_edges().to_lower()
	if not spread.is_empty() and not spread in SamplerToolUtil.SPREADS:
		return fail("as must be one of %s" % ", ".join(SamplerToolUtil.SPREADS))
	var folder_items := _folder_items(args)
	if not folder_items.is_empty():
		return _add_folder_samplers(project, channel, parent, folder_items, args)
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
	if _one_sampler_for_all(specs, parent, args):
		var sampler_v = DeviceToolUtil.add_sampler(channel, parent, specs.map(func(s: Dictionary): return s._asset), args)
		if sampler_v is Dictionary:
			return sampler_v
		# On a Drum Machine the pad is a slot chain holding the Sampler.
		var sampler := SamplerToolUtil.find_sampler(sampler_v)
		var layout_text := _spread(sampler, spread)
		var sampler_result := _one_result(project, channel, sampler_v)
		if not layout_text.is_empty():
			sampler_result.text += "\n%s" % layout_text
		if SamplerToolUtil.is_multisample(sampler):
			sampler_result.text += "\n%s" % SamplerToolUtil.describe(sampler)
		if not notes.is_empty():
			sampler_result.text += "\n%s" % "\n".join(notes)
		return sampler_result
	var added: Array = []
	var key_info_waits: Array[Callable] = []
	for spec in specs:
		var one = DeviceToolUtil.add_one(channel, parent, spec, args)
		if one is Dictionary and one.get("ok") == false:
			if added.is_empty():
				return one
			break
		if one is DeviceInstance:
			added.append(one)
			# An SFZ's keyswitches arrive after its async load; wait for them below.
			key_info_waits.append(SfzKeyInfoUtil.watch(one))
	if added.is_empty():
		return fail("Device was not added")
	for key_info_wait in key_info_waits:
		await key_info_wait.call()
	var result: Dictionary
	if added.size() == 1:
		result = _one_result(project, channel, added[0])
	else:
		result = _several_result(project, channel, parent, added)
	if not notes.is_empty():
		result.text = "%s\n%s" % [result.text, "\n".join(notes)]
	return result


## The `samples` items that name a `folder`.
func _folder_items(args: Dictionary) -> Array:
	var raw = args.get("samples", [])
	if not raw is Array:
		return []
	return raw.filter(func(item) -> bool: return item is Dictionary and not str(item.get("folder", "")).strip_edges().is_empty())


## One Sampler per folder item (a pad on a Drum Machine `parent`), each holding every audio file
## of its folder. Every folder is resolved before anything is added.
func _add_folder_samplers(project: Project, channel: Channel, parent: DeviceInstance, items: Array, args: Dictionary) -> Dictionary:
	var raw: Array = args.get("samples", [])
	if items.size() != raw.size() or args.has("asset_path") or args.has("asset_paths"):
		return fail("Pass either folder items or asset paths in one call, not both")
	var folders: Array = []
	for item in items:
		var found = SamplerToolUtil.folder_audio(str(item.folder))
		if found is Dictionary:
			return found
		folders.append(found)
	var spread := str(args.get("as", "")).strip_edges().to_lower()
	var lines: Array = []
	var rows: Array = []
	for i in items.size():
		var item: Dictionary = items[i]
		var sampler_args := {"name": item.get("name", ""), "note": int(item.get("note", -1)), "position": args.get("position", -1)}
		var sampler_v = DeviceToolUtil.add_sampler(channel, parent, folders[i], sampler_args)
		if sampler_v is Dictionary:
			if rows.is_empty():
				return sampler_v
			lines.append("Stopped at %s: %s" % [str(item.folder), str(sampler_v.get("error", ""))])
			break
		var added: DeviceInstance = sampler_v
		var sampler := SamplerToolUtil.find_sampler(added)
		var layout_text := _spread(sampler, str(item.get("as", spread)).strip_edges().to_lower())
		rows.append(compact_device(project, added))
		var note_part := ", note %d" % added.slot_note if added.slot_note >= 0 else ""
		var zones := sampler.multisample.zones.size() if SamplerToolUtil.is_multisample(sampler) else 1
		lines.append("- %s (path \"%s\"%s): %d %s from %s.%s" % [
			added.get_display_name(), added.address_path(project), note_part, zones,
			"zones" if zones != 1 else "sample", str(item.folder), " " + layout_text if not layout_text.is_empty() else "",
		])
	var host_path := parent.address_path(project) if parent else channel.name
	lines.push_front("Added %d Samplers to %s:" % [rows.size(), host_path])
	return ok_text("\n".join(lines), {"devices": rows, "count": rows.size()})


## Lay out a new multisample `sampler` per `spread` ("" = SamplerToolUtil.default_spread) as its
## own undo step. Returns the layout sentence for the result ("" when the keys layout was kept).
func _spread(sampler: DeviceInstance, spread: String) -> String:
	if not SamplerToolUtil.is_multisample(sampler):
		return ""
	var ms := sampler.multisample
	var names: Array = ms.zones.map(func(z: SamplerZone): return z.name)
	if spread.is_empty():
		spread = SamplerToolUtil.default_spread(sampler, names)
	if spread == "keys":
		return SamplerToolUtil.spread_hint(names)
	var ids: Array = ms.zones.map(func(z: SamplerZone): return z.id)
	SamplerActions.edit(sampler, "Lay Out Zones", func(model: SamplerMultisample): SamplerToolUtil.apply_spread(model, ids, spread))
	return SamplerToolUtil.spread_text(spread)


## Several audio files go into one multisample Sampler, except on a Drum Machine, where each gets
## its own pad unless `multisample` is set.
func _one_sampler_for_all(specs: Array, parent: DeviceInstance, args: Dictionary) -> bool:
	if specs.size() < 2 or not specs.all(func(s: Dictionary) -> bool: return s._asset.type == Asset.TYPE.Audio):
		return false
	return not DeviceToolUtil.is_drum_machine(parent) or bool(args.get("multisample", false))


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
	var key_text := SfzKeyInfoUtil.text_for(inst, data.path)
	if not key_text.is_empty():
		text += "\n%s" % key_text
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
