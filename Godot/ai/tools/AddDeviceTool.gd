# AddDeviceTool.gd
class_name AddDeviceTool extends AiTool


func get_name() -> String:
	return "add_device"


func get_description() -> String:
	return "Add a device, SFZ, or drum-machine sample pad. For kits, pass a Drum Machine parent and samples/asset_paths (wav from search_assets). Optional name and MIDI note; omitted values are inferred (Kick=36, Snare=38, Hat=42, Open hat=46, Crash=49, Ride=51). Do not add an empty Sampler then load_device_file."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"channel_id": {"type": "integer", "description": "Mixer channel id"},
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
						"note": {"type": "integer", "description": "MIDI note 0–127"},
					},
				},
			},
			"device_id": {"type": "string", "description": "Built-in or plugin device id"},
			"name": {"type": "string", "description": "Pad/device display name (single add)"},
			"note": {"type": "integer", "description": "Drum pad MIDI note 0–127 (single add)"},
			"position": {"type": "integer", "description": "Insert index, -1 appends"},
			"parent": {"type": "string", "description": "Container path or relative name"},
			"parent_instance_id": {"type": "string", "description": "Container instance_id"},
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
	var parent_v = resolve_optional_parent(project, args)
	if parent_v is Dictionary:
		return parent_v
	var parent: DeviceInstance = parent_v
	var specs: Array = DeviceToolUtil.collect_pad_specs(args)
	if specs.is_empty():
		var asset := _resolve_asset(args)
		if asset == null:
			return fail("Provide asset_path, samples, asset_paths, or device_id")
		specs.append({"asset_path": asset.path, "name": str(args.get("name", "")).strip_edges(), "note": int(args.get("note", -1)), "_asset": asset})
	var added: Array = []
	for spec in specs:
		var one = _add_one(project, channel, parent, spec, args)
		if one is Dictionary and one.get("ok") == false:
			if added.is_empty():
				return one
			break
		if one is DeviceInstance:
			added.append(one)
	if added.is_empty():
		return fail("Device was not added")
	if added.size() == 1:
		return ok(compact_device(project, added[0]))
	var rows: Array = []
	for inst in added:
		rows.append(compact_device(project, inst))
	return ok({"devices": rows, "count": rows.size()})


## Add one asset (device, SFZ, or drum pad sample).
func _add_one(_project: Project, channel: Channel, parent: DeviceInstance, spec: Dictionary, args: Dictionary) -> Variant:
	var asset: Asset = spec.get("_asset", null)
	if asset == null:
		asset = _resolve_asset({"asset_path": spec.get("asset_path", "")})
	if asset == null:
		return fail("Asset not found: %s" % str(spec.get("asset_path", "")))
	if parent:
		if not DeviceDropUtil.can_drop_on_container(channel, parent, asset):
			return fail("Cannot add that asset into %s" % parent.get_display_name())
	elif not DeviceDropUtil.can_drop_asset_on_channel(channel, asset):
		if asset.type == Asset.TYPE.Audio:
			return fail("Audio samples go on a Drum Machine: pass parent (e.g. Drums/Drum Machine)")
		return fail("Cannot add that asset to channel %d (%s)" % [channel.id, channel.name])
	var host: Array[DeviceInstance] = parent.children if parent else channel.devices
	var before: Dictionary = {}
	for d in host:
		if d is DeviceInstance:
			before[d.id] = true
	var position := int(args.get("position", -1))
	if parent and asset.type == Asset.TYPE.Audio and parent.device and parent.device.device_id == "sonara.builtin.drum_machine":
		var identity := DeviceToolUtil.resolve_pad_identity(spec, asset.get_display_name(), _used_notes(parent))
		var note := int(identity.note)
		if note < 0:
			note = parent.next_free_drum_note()
		DeviceDropUtil.drop_on_drum_pad(channel, parent, note, asset)
		var pad := _find_added(host, before)
		if pad == null:
			return fail("Sample pad was not added")
		if not str(identity.name).is_empty():
			pad.set_name(str(identity.name))
		return pad
	elif parent:
		DeviceDropUtil.drop_on_container(channel, parent, asset)
	else:
		DeviceDropUtil.drop_asset(channel, asset, position, parent)
	var added := _find_added(host, before)
	if added == null or added.device == null:
		return fail("Device was not added")
	var extra_name := str(spec.get("name", "")).strip_edges()
	if not extra_name.is_empty():
		added.set_name(extra_name)
	return added


## MIDI notes already used by drum-machine children.
func _used_notes(parent: DeviceInstance) -> Dictionary:
	var used := {}
	if parent == null:
		return used
	for child in parent.children:
		if child and child.slot_note >= 0:
			used[child.slot_note] = true
	return used


## First host child whose id was not in `before`.
func _find_added(host: Array, before: Dictionary) -> DeviceInstance:
	for d in host:
		if d is DeviceInstance and not before.has(d.id):
			return d
	return null


func _resolve_asset(args: Dictionary) -> Asset:
	if AssetService == null:
		return null
	var path := str(args.get("asset_path", "")).strip_edges()
	if not path.is_empty():
		var by_path := AssetService.find_asset(path)
		if by_path:
			return by_path
	var device_id := str(args.get("device_id", "")).strip_edges()
	if device_id.is_empty():
		device_id = path
	if device_id.is_empty():
		return null
	var by_id := AssetService.find_asset(device_id)
	if by_id:
		return by_id
	var device := AssetService.get_device(device_id)
	if device == null:
		return null
	var fake := Asset.new()
	fake.type = Asset.TYPE.Device
	fake.path = device.device_id
	fake.name = device.name
	return fake
