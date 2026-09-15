# DeviceToolUtil.gd
# Parameter paging/parsing helpers for AI device tools.
class_name DeviceToolUtil extends RefCounted


## Parameters matching optional group (`param` / `cc` / `all`) and name substring.
static func filter_params(inst: DeviceInstance, group: String, query: String) -> Array[DeviceParameter]:
	var out: Array[DeviceParameter] = []
	if inst == null or inst.device == null:
		return out
	var g := group.strip_edges().to_lower()
	var q := query.strip_edges().to_lower()
	var src: Array[DeviceParameter] = inst.get_parameters()
	if g == "param" or g == "cc":
		src = inst.get_parameters_in_group(g)
	for p in src:
		if p == null:
			continue
		if not q.is_empty() and not p.name.to_lower().contains(q):
			continue
		out.append(p)
	return out


## JSON-friendly current value: bool, enum label, or real float.
static func current_param_value(inst: DeviceInstance, param: DeviceParameter) -> Variant:
	if inst == null or param == null:
		return 0.0
	var real := inst.get_parameter_real(param.id)
	if param.param_type == "bool":
		return real >= 0.5
	if param.param_type == "enum":
		return param.format_value(real)
	return real


## Compact one parameter for `get_device`.
static func param_dict(inst: DeviceInstance, param: DeviceParameter) -> Dictionary:
	var enums: Array = []
	for e in param.enum_values:
		enums.append(e)
	return {
		"id": param.id,
		"name": param.name,
		"type": param.param_type,
		"unit": param.unit,
		"min": param.min_value,
		"max": param.max_value,
		"default": param.default_value,
		"enum_values": enums,
		"group": param.group if not param.group.is_empty() else "param",
		"value": current_param_value(inst, param),
	}


## Convert a tool value to normalized 0–1. `{ok:true, normalized}` or `{ok:false, error}`.
static func parse_param_value(param: DeviceParameter, value: Variant) -> Dictionary:
	if param == null:
		return {"ok": false, "error": "Unknown parameter"}
	return param.parse_tool_value(value)


## Flatten `samples` / `asset_paths` / `asset_path` into pad specs.
static func collect_pad_specs(args: Dictionary) -> Array:
	var out: Array = []
	_append_pad_items(out, args.get("samples", null))
	_append_pad_items(out, args.get("asset_paths", null))
	var single := str(args.get("asset_path", "")).strip_edges()
	if not single.is_empty():
		var spec := pad_spec_from({
			"asset_path": single,
			"name": args.get("name", ""),
			"note": args.get("note", -1),
		})
		if not spec.is_empty():
			out.append(spec)
	return out


## One `{asset_path, name, note}` from a path string or object.
static func pad_spec_from(item: Variant) -> Dictionary:
	if item is String:
		var path := str(item).strip_edges()
		if path.is_empty():
			return {}
		return {"asset_path": path, "name": "", "note": -1}
	if item is Dictionary:
		var path := str(item.get("asset_path", item.get("path", ""))).strip_edges()
		if path.is_empty():
			return {}
		var note := -1
		if item.has("note"):
			note = int(item.note)
		return {
			"asset_path": path,
			"name": str(item.get("name", "")).strip_edges(),
			"note": note,
		}
	return {}


## Fill empty pad name/note from the sample label; skip notes already used.
static func resolve_pad_identity(spec: Dictionary, hint: String, used_notes: Dictionary) -> Dictionary:
	var pad_name := str(spec.get("name", "")).strip_edges()
	var note := int(spec.get("note", -1))
	var guess_src := pad_name if not pad_name.is_empty() else hint
	if note < 0 or note > 127:
		note = ClipTextKey.guess_drum_note(guess_src)
	if note >= 0 and used_notes.has(note):
		note = -1
	if pad_name.is_empty() and note >= 0:
		pad_name = ClipTextKey.drum_label(note)
	elif pad_name.is_empty() and not hint.is_empty():
		pad_name = DeviceNaming.sanitize(hint.replace("_", " ").replace("-", " "))
	return {"name": pad_name, "note": note}


## Append pad specs from an array of paths or objects.
static func _append_pad_items(out: Array, raw: Variant) -> void:
	if not raw is Array:
		return
	for item in raw:
		var spec := pad_spec_from(item)
		if not spec.is_empty():
			out.append(spec)


## Resolve an asset from `asset_path` or `device_id`, or a fake `Asset.TYPE.Device` row.
static func resolve_asset(args: Dictionary) -> Asset:
	if AssetService == null:
		return null
	var path := str(args.get("asset_path", "")).strip_edges()
	if not path.is_empty():
		var by_path := AssetService.resolve_asset(path)
		if by_path:
			return by_path
	var device_id := str(args.get("device_id", "")).strip_edges()
	if device_id.is_empty():
		device_id = path
	if device_id.is_empty():
		return null
	var by_id := AssetService.resolve_asset(device_id)
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


## Add one asset (device, SFZ, or drum pad sample) to a channel or container. Returns the
## new `DeviceInstance`, or `AiTool.fail(...)` on error.
static func add_one(channel: Channel, parent: DeviceInstance, spec: Dictionary, args: Dictionary) -> Variant:
	var asset: Asset = spec.get("_asset", null)
	if asset == null:
		asset = resolve_asset({"asset_path": spec.get("asset_path", "")})
	if asset == null:
		return AiTool.fail("Asset not found: %s" % str(spec.get("asset_path", "")))
	if parent:
		if not DeviceDropUtil.can_drop_on_container(channel, parent, asset):
			return AiTool.fail("Cannot add that asset into %s" % parent.get_display_name())
	elif not DeviceDropUtil.can_drop_asset_on_channel(channel, asset):
		if asset.type == Asset.TYPE.Audio:
			return AiTool.fail("Audio samples go on a Drum Machine: pass parent (e.g. Drums/Drum Machine)")
		return AiTool.fail("Cannot add that asset to channel %d (%s)" % [channel.id, channel.name])
	var host: Array[DeviceInstance] = parent.children if parent else channel.devices
	var before: Dictionary = {}
	for d in host:
		if d is DeviceInstance:
			before[d.id] = true
	var position := int(args.get("position", -1))
	if parent and asset.type == Asset.TYPE.Audio and parent.device and parent.device.device_id == "sonara.builtin.drum_machine":
		var identity := resolve_pad_identity(spec, asset.get_display_name(), _used_notes(parent))
		var note := int(identity.note)
		if note < 0:
			note = parent.next_free_drum_note()
		DeviceDropUtil.drop_on_drum_pad(channel, parent, note, asset)
		var pad := _find_added(host, before)
		if pad == null:
			return AiTool.fail("Sample pad was not added")
		if not str(identity.name).is_empty():
			pad.set_name(str(identity.name))
		return pad
	elif parent:
		DeviceDropUtil.drop_on_container(channel, parent, asset)
	else:
		DeviceDropUtil.drop_asset(channel, asset, position, parent)
	var added := _find_added(host, before)
	if added == null or added.device == null:
		return AiTool.fail("Device was not added")
	var extra_name := str(spec.get("name", "")).strip_edges()
	if not extra_name.is_empty():
		added.set_name(extra_name)
	return added


## MIDI notes already used by drum-machine children.
static func _used_notes(parent: DeviceInstance) -> Dictionary:
	var used := {}
	if parent == null:
		return used
	for child in parent.children:
		if child and child.slot_note >= 0:
			used[child.slot_note] = true
	return used


## First host child whose id was not in `before`.
static func _find_added(host: Array, before: Dictionary) -> DeviceInstance:
	for d in host:
		if d is DeviceInstance and not before.has(d.id):
			return d
	return null
