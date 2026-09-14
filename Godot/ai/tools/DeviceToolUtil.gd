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
