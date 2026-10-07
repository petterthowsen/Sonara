# EditSamplerTool.gd
# Multisample setup for a Sampler (spec 023): switch mode, add samples as zones, set zone key and
# velocity ranges and per-zone settings, lay zones out with the editor's batch operations, and
# manage groups. A call is a list of ops applied in order as one undo step; if any op fails, the
# Sampler is put back as it was and nothing changes.
class_name EditSamplerTool extends AiTool

const OP_KEYS := {
	"mode": ["mode"],
	"add_samples": ["asset_paths", "folder", "as", "at_key", "to_group"],
	"set": ["zones", "in_group", "key", "vel", "root", "tune", "fine", "gain_db", "start", "end",
		"reverse", "loop_mode", "loop_start", "loop_end", "crossfade", "key_fade", "vel_fade", "to_group"],
	"layout": ["zones", "in_group", "how", "range", "stretch", "slice", "reverse"],
	"remove": ["zones", "in_group"],
	"add_group": ["name", "gain_db", "mute", "solo", "play_mode"],
	"set_group": ["group", "name", "gain_db", "mute", "solo", "play_mode"],
	"remove_group": ["group"],
}

## `layout` operations: the editor's batch operations (REQ-047) that compute ranges.
const LAYOUT_HOWS := [
	"distribute_notes", "distribute_velocity", "assign_note", "assign_velocity",
	"mirror_notes", "flip_velocity", "set_root_from_name", "sort_by_name",
]
const _RANGE_HOWS := ["distribute_notes", "distribute_velocity", "assign_note", "assign_velocity"]

## Per-zone fractions of the file (0-1).
const _FRACTION_FIELDS := ["start", "end", "loop_start", "loop_end", "crossfade"]


func get_name() -> String:
	return "edit_sampler"


func get_description() -> String:
	return "Set up a Sampler multisample: zones (one sample each, with key and velocity ranges and their own root/tune/gain/loop settings) and groups (gain, mute, solo, round robin). ops run in order as one undo step; a failing op changes nothing. Zones and groups are named; zone names are the file names. Notes are names (C3 = 60, so C-2 = 0 and G8 = 127), MIDI numbers, or \"all\" for every key. set and layout act on every zone unless zones or in_group narrows them. Device parameters (Key Track, Velocity, Volume) are set with set_device_params, not here. get_device lists the zones."


func get_parameters() -> Dictionary:
	var zones := {
		"type": "array",
		"items": {"type": "string"},
		"description": "Zone names, or [\"all\"] (the default for set and layout)",
	}
	var note_range := {
		"type": "array",
		"items": {"type": "string"},
		"description": "set: [low, high] notes, e.g. [\"C2\", \"B2\"], or [\"all\"] for every key",
	}
	return {
		"type": "object",
		"properties": {
			"path": {"type": "string", "description": "Sampler device path (a drum pad path works too)"},
			"ops": {
				"type": "array",
				"description": "Edits, applied in order",
				"items": {
					"type": "object",
					"properties": {
						"op": {
							"type": "string",
							"enum": OP_KEYS.keys(),
							"description": "mode: switch multisample/single. add_samples: one zone per file (switches to multisample), laid out per as. set: change the selected zones. layout: batch operation on the selected zones. remove: delete zones. add_group / set_group / remove_group.",
						},
						"mode": {"type": "string", "enum": ["multisample", "single"], "description": "mode: single keeps only the focused zone"},
						"asset_paths": {"type": "array", "items": {"type": "string"}, "description": "add_samples: audio paths from search_assets/list_assets"},
						"folder": {"type": "string", "description": "add_samples: library folder; every audio file directly in it"},
						"as": {"type": "string", "enum": SamplerToolUtil.SPREADS, "description": "add_samples: keys lays zones out from the note names in the file names, for pitched instruments (the default, except on a drum pad with no note names in the files, where velocity_layers is). For several takes of one sound (a drum hit): velocity_layers gives every zone every key and splits velocity 1-127 in natural name order, softest first; round_robin gives every zone every key and velocity in a round-robin group"},
						"at_key": {"type": "string", "description": "add_samples: lowest key of the new zones (default from file names, else C3)"},
						"to_group": {"type": "string", "description": "add_samples/set: put the zones in this group (created if missing; \"Ungrouped\" removes them from groups)"},
						"zones": zones,
						"in_group": {"type": "string", "description": "Select the zones of this group (with zones: only those of it)"},
						"key": note_range,
						"vel": {"type": "array", "items": {"type": "integer"}, "description": "set: [low, high] velocity 1-127"},
						"root": {"type": "string", "description": "set: root key, the note the sample was recorded at"},
						"tune": {"type": "number", "description": "set: semitones, -48 to 48"},
						"fine": {"type": "number", "description": "set: cents, -100 to 100"},
						"gain_db": {"type": "number", "description": "set/add_group/set_group: gain in dB, at most +12"},
						"start": {"type": "number", "description": "set: sample start, 0-1 of the file"},
						"end": {"type": "number", "description": "set: sample end, 0-1 of the file"},
						"reverse": {"type": "boolean", "description": "set: play the zone backwards. layout: reverse the distribution order"},
						"loop_mode": {"type": "string", "enum": SamplerToolUtil.LOOP_MODES, "description": "set"},
						"loop_start": {"type": "number", "description": "set: 0-1 of the file"},
						"loop_end": {"type": "number", "description": "set: 0-1 of the file"},
						"crossfade": {"type": "number", "description": "set: loop crossfade, 0-1 of the loop"},
						"key_fade": {"type": "array", "items": {"type": "integer"}, "description": "set: [low, high] crossfade widths in semitones at the key range edges"},
						"vel_fade": {"type": "array", "items": {"type": "integer"}, "description": "set: [low, high] crossfade widths in velocity steps at the velocity range edges"},
						"how": {
							"type": "string",
							"enum": LAYOUT_HOWS,
							"description": "layout: distribute_notes splits range over the zones by root (velocity kept); distribute_velocity splits range over the zones in the order named (keys kept); assign_note / assign_velocity give every zone range; mirror_notes / flip_velocity mirror their ranges; set_root_from_name reads roots from names; sort_by_name reorders the list",
						},
						"range": {"type": "array", "items": {"type": "string"}, "description": "layout: [low, high], notes for *_note(s), velocities for *_velocity; [\"all\"] is the whole range"},
						"stretch": {"type": "boolean", "description": "layout distribute: true (default) fills range with contiguous slices; false gives each zone slice steps"},
						"slice": {"type": "integer", "description": "layout distribute with stretch false: steps per zone"},
						"name": {"type": "string", "description": "add_group: group name. set_group: new name"},
						"group": {"type": "string", "description": "set_group/remove_group: group name (\"Ungrouped\" for zones in no group)"},
						"mute": {"type": "boolean"},
						"solo": {"type": "boolean"},
						"play_mode": {"type": "string", "enum": SamplerToolUtil.PLAY_MODES, "description": "Group: all plays every zone that matches; round_robin / random play one per note (for alternate takes of the same note)"},
					},
					"required": ["op"],
				},
			},
		},
		"required": ["path", "ops"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var inst_v = resolve_device(project, args)
	if inst_v is Dictionary:
		return inst_v
	var sampler := SamplerToolUtil.find_sampler(inst_v)
	if sampler == null:
		return fail("%s is not a Sampler" % inst_v.get_display_name())
	var ops = args.get("ops", [])
	if ops is Dictionary:
		ops = [ops]
	if not ops is Array or ops.is_empty():
		return fail("ops must be a non-empty array")
	# Checking stores resolved files on the ops; keep that off the caller's (logged) arguments.
	ops = ops.duplicate(true)
	# Check every op's keys and resolve every file before changing anything.
	var notes: Array[String] = []
	for i in ops.size():
		var checked := _check_op(ops[i], notes)
		if not checked.is_empty():
			return fail("ops[%d]: %s. Nothing was changed." % [i, str(checked.error).trim_suffix(".")])
	var old_state := SamplerActions.begin_edit(sampler)
	for i in ops.size():
		var error := _apply(sampler, ops[i], notes)
		if not error.is_empty():
			SamplerActions.apply_state(sampler, old_state)
			return fail("ops[%d] (%s): %s. Nothing was changed." % [i, str(ops[i].get("op", "")), error.trim_suffix(".")])
	SamplerActions.end_edit(sampler, "Edit Sampler", old_state)
	var path := sampler.address_path(project)
	var lines: Array[String] = notes.duplicate()
	if SamplerToolUtil.is_multisample(sampler):
		lines.append(SamplerToolUtil.describe(sampler))
	else:
		lines.append("%s is in single-sample mode%s." % [path, ": %s" % AiTool.relative_asset_path(sampler.loaded_file_path) if not sampler.loaded_file_path.is_empty() else ""])
	return ok_text("Edited %s.\n%s" % [path, "\n".join(lines)], compact_device(project, sampler))


# --- checking --------------------------------------------------------------

## Validate `op`'s name and keys, and resolve add_samples files into `op._paths`. `{}` when fine,
## `{error}` otherwise. Fuzzy file matches add a line to `notes`.
func _check_op(op: Variant, notes: Array[String]) -> Dictionary:
	if not op is Dictionary:
		return {"error": "each op must be an object"}
	var kind := str(op.get("op", ""))
	if not OP_KEYS.has(kind):
		return {"error": "unknown op '%s'. Ops: %s" % [kind, ", ".join(OP_KEYS.keys())]}
	var unknown: PackedStringArray = []
	for key in op.keys():
		if key != "op" and not str(key).begins_with("_") and not OP_KEYS[kind].has(str(key)):
			unknown.append(str(key))
	if not unknown.is_empty():
		return {"error": "%s does not take %s. It takes: %s" % [kind, ", ".join(unknown), ", ".join(OP_KEYS[kind])]}
	if kind == "add_samples":
		var paths_v = _resolve_samples(op, notes)
		if paths_v is Dictionary:
			return {"error": paths_v.error}
		op["_paths"] = paths_v
	return {}


## Absolute paths of an add_samples op's `folder` and `asset_paths`, or AiTool.fail(...).
func _resolve_samples(op: Dictionary, notes: Array[String]) -> Variant:
	var out: Array = []
	if op.has("folder"):
		var found = SamplerToolUtil.folder_audio(str(op.folder))
		if found is Dictionary:
			return found
		out.append_array(found.map(func(asset: Asset): return asset.path))
	var raw = op.get("asset_paths", [])
	for item in (raw if raw is Array else [raw]):
		var resolved := DeviceToolUtil.resolve_asset_fuzzy({"asset_path": str(item)}, "audio")
		if resolved.get("ok") == false:
			return resolved
		var asset: Asset = resolved.asset
		if asset.type != Asset.TYPE.Audio:
			return fail("%s is not an audio file" % str(item))
		if not str(resolved.get("note", "")).is_empty():
			notes.append(str(resolved.note))
		out.append(asset.path)
	if out.is_empty():
		return fail("add_samples needs asset_paths or folder")
	var unique: Array = []
	for p in out:
		if not unique.has(p):
			unique.append(p)
	return unique


# --- applying --------------------------------------------------------------

## Apply one checked op. Returns "" on success or the error.
func _apply(inst: DeviceInstance, op: Dictionary, notes: Array[String]) -> String:
	var kind := str(op.op)
	if kind == "mode":
		return _apply_mode(inst, op, notes)
	if kind == "add_samples":
		return _apply_add_samples(inst, op, notes)
	var ms := inst.multisample
	if ms == null or not ms.active:
		return "the Sampler is in single-sample mode; add_samples or mode multisample first"
	match kind:
		"set":
			return _apply_set(ms, op, notes)
		"layout":
			return _apply_layout(ms, op)
		"remove":
			var zones_v = SamplerToolUtil.select_zones(ms, op, true)
			if zones_v is Dictionary:
				return zones_v.error
			ms.remove_zones(zones_v.map(func(z: SamplerZone): return z.id))
			notes.append("Removed %d zones." % zones_v.size())
		"add_group":
			return _apply_add_group(ms, op, notes)
		"set_group":
			return _apply_set_group(ms, op)
		"remove_group":
			var group_v = SamplerToolUtil.find_group(ms, str(op.get("group", "")))
			if group_v is Dictionary:
				return group_v.error
			if group_v.id == SamplerZoneGroup.UNGROUPED_ID:
				return "Ungrouped can't be removed"
			ms.remove_group(group_v.id)
			notes.append("Removed group %s; its zones are Ungrouped." % group_v.name)
	return ""


func _apply_mode(inst: DeviceInstance, op: Dictionary, notes: Array[String]) -> String:
	match str(op.get("mode", "")):
		"multisample":
			SamplerActions.make_multisample(inst)
		"single":
			var count := inst.multisample.zones.size() if SamplerToolUtil.is_multisample(inst) else 0
			var kept := SamplerActions.make_single(inst)
			if count > 1:
				notes.append("Kept only zone %s; %d other zones were removed." % [kept, count - 1])
		_:
			return "mode must be multisample or single"
	return ""


func _apply_add_samples(inst: DeviceInstance, op: Dictionary, notes: Array[String]) -> String:
	var at_key := -1
	if op.has("at_key"):
		at_key = SamplerToolUtil.parse_note(op.at_key)
		if at_key < 0:
			return "at_key '%s' is not a note" % str(op.at_key)
	var ms := inst.ensure_multisample()
	var file_names: Array = op._paths.map(func(p): return str(p).get_file().get_basename())
	var spread := str(op.get("as", SamplerToolUtil.default_spread(inst, file_names))).strip_edges().to_lower()
	if not spread in SamplerToolUtil.SPREADS:
		return "as must be one of %s" % ", ".join(SamplerToolUtil.SPREADS)
	var kept_single := "" if ms.active else inst.loaded_file_path.get_file().get_basename()
	var ids := SamplerActions.add_zone_files(inst, op._paths, at_key)
	var spread_error := SamplerToolUtil.apply_spread(ms, ids, spread)
	if not spread_error.is_empty():
		return spread_error
	if op.has("to_group"):
		var group_v = _group_or_create(ms, str(op.to_group), notes)
		if group_v is String:
			return group_v
		ms.move_to_group(ids, group_v)
	var names: PackedStringArray = []
	for zone_id in ids:
		names.append(ms.get_zone(zone_id).name)
	var shown := ", ".join(names.slice(0, 8)) + (", …" if names.size() > 8 else "")
	notes.append("Added %d zones: %s." % [ids.size(), shown])
	var layout_note := SamplerToolUtil.spread_text(spread)
	if spread == "keys" and not op.has("at_key"):
		layout_note = SamplerToolUtil.spread_hint(file_names)
	if not layout_note.is_empty():
		notes.append(layout_note)
	if not kept_single.is_empty():
		notes.append("The Sampler's single sample %s is a zone now too." % kept_single)
	return ""


## The id of group `group_name`, created when missing; or an error string.
func _group_or_create(ms: SamplerMultisample, group_name: String, notes: Array[String]) -> Variant:
	if group_name.strip_edges().is_empty():
		return "to_group is empty"
	var found = SamplerToolUtil.find_group(ms, group_name)
	if found is SamplerZoneGroup:
		return found.id
	var formatted := NameStyle.format(group_name)
	notes.append("Created group %s." % formatted)
	return ms.add_group(formatted)


func _apply_set(ms: SamplerMultisample, op: Dictionary, notes: Array[String]) -> String:
	var zones_v = SamplerToolUtil.select_zones(ms, op)
	if zones_v is Dictionary:
		return zones_v.error
	var fields := {}
	for which in ["key", "vel"]:
		if op.has(which):
			var r := SamplerToolUtil.parse_range(op[which], which == "key", which)
			if r.has("error"):
				return r.error
			fields[which] = [r.lo, r.hi]
	if op.has("root"):
		var root := SamplerToolUtil.parse_note(op.root)
		if root < 0:
			return "root '%s' is not a note" % str(op.root)
		fields["root"] = root
	var bounded := {"tune": [-48.0, 48.0], "fine": [-100.0, 100.0]}
	for field in bounded:
		if op.has(field):
			var err := _check_number(op[field], field, bounded[field][0], bounded[field][1])
			if not err.is_empty():
				return err
			fields[field] = float(op[field])
	for field in _FRACTION_FIELDS:
		if op.has(field):
			var err := _check_number(op[field], field, 0.0, 1.0)
			if not err.is_empty():
				return err
			fields[field] = float(op[field])
	if op.has("gain_db"):
		var g := SamplerToolUtil.parse_gain_db(op.gain_db)
		if g.has("error"):
			return g.error
		fields["gain"] = g.gain
	if op.has("reverse"):
		fields["reverse"] = bool(op.reverse)
	if op.has("loop_mode"):
		var mode := SamplerToolUtil.parse_choice(op.loop_mode, SamplerToolUtil.LOOP_MODES)
		if mode < 0:
			return "loop_mode must be one of %s" % ", ".join(SamplerToolUtil.LOOP_MODES)
		fields["loop_mode"] = mode
	for which in ["key_fade", "vel_fade"]:
		if op.has(which):
			var widths = op[which]
			if not widths is Array or widths.size() != 2:
				return "%s must be [low, high] widths" % which
			fields[which] = [maxi(0, int(widths[0])), maxi(0, int(widths[1]))]
	if op.has("to_group"):
		var group_v = _group_or_create(ms, str(op.to_group), notes)
		if group_v is String:
			return group_v
		fields["group"] = group_v
	if fields.is_empty():
		return "set needs a zone setting to change (key, vel, root, tune, fine, gain_db, start, end, reverse, loop_*, key_fade, vel_fade, to_group). Device parameters such as Key Track or Velocity are set with set_device_params"
	var changes := {}
	for zone in zones_v:
		changes[zone.id] = fields
	ms.set_zones_fields(changes)
	return ""


func _check_number(value: Variant, field: String, lo: float, hi: float) -> String:
	if not (value is int or value is float):
		return "%s must be a number" % field
	if float(value) < lo or float(value) > hi:
		return "%s must be between %s and %s" % [field, str(lo), str(hi)]
	return ""


func _apply_layout(ms: SamplerMultisample, op: Dictionary) -> String:
	var how := str(op.get("how", ""))
	if not how in LAYOUT_HOWS:
		return "how must be one of %s" % ", ".join(LAYOUT_HOWS)
	var zones_v = SamplerToolUtil.select_zones(ms, op)
	if zones_v is Dictionary:
		return zones_v.error
	var ids: Array = zones_v.map(func(z: SamplerZone): return z.id)
	if how == "sort_by_name":
		ms.sort_zones_by_name(ids)
		return ""
	var opts := {
		"stretch": bool(op.get("stretch", true)),
		"slice": maxi(1, int(op.get("slice", 1))),
		"reverse": bool(op.get("reverse", false)),
	}
	if how in _RANGE_HOWS:
		if not op.has("range"):
			return "%s needs range [low, high]" % how
		var r := SamplerToolUtil.parse_range(op.range, how.ends_with("note") or how.ends_with("notes"), "range")
		if r.has("error"):
			return r.error
		opts["lo"] = r.lo
		opts["hi"] = r.hi
	ms.set_zones_fields(SamplerActions.batch_changes(ms, how, ids, opts))
	return ""


func _apply_add_group(ms: SamplerMultisample, op: Dictionary, notes: Array[String]) -> String:
	var group_name := NameStyle.format(str(op.get("name", "")))
	if group_name.is_empty():
		return "add_group needs name"
	if SamplerToolUtil.find_group(ms, group_name) is SamplerZoneGroup:
		return "a group named %s already exists" % group_name
	var group_id := ms.add_group(group_name)
	return _apply_group_fields(ms, group_id, op)


func _apply_set_group(ms: SamplerMultisample, op: Dictionary) -> String:
	var group_v = SamplerToolUtil.find_group(ms, str(op.get("group", "")))
	if group_v is Dictionary:
		return group_v.error
	var group: SamplerZoneGroup = group_v
	if op.has("name"):
		var new_name := NameStyle.format(str(op.name))
		if group.id == SamplerZoneGroup.UNGROUPED_ID:
			return "Ungrouped can't be renamed"
		var clash = SamplerToolUtil.find_group(ms, new_name)
		if new_name.is_empty() or (clash is SamplerZoneGroup and clash != group):
			return "name '%s' is empty or taken" % new_name
		ms.rename_group(group.id, new_name)
	return _apply_group_fields(ms, group.id, op)


## gain_db, mute, solo and play_mode of an add_group / set_group op.
func _apply_group_fields(ms: SamplerMultisample, group_id: int, op: Dictionary) -> String:
	var fields := {}
	if op.has("gain_db"):
		var g := SamplerToolUtil.parse_gain_db(op.gain_db)
		if g.has("error"):
			return g.error
		fields["gain"] = g.gain
	for flag in ["mute", "solo"]:
		if op.has(flag):
			fields[flag] = bool(op[flag])
	if op.has("play_mode"):
		var mode := SamplerToolUtil.parse_choice(op.play_mode, SamplerToolUtil.PLAY_MODES)
		if mode < 0:
			return "play_mode must be one of %s" % ", ".join(SamplerToolUtil.PLAY_MODES)
		fields["play_mode"] = mode
	if not fields.is_empty():
		ms.set_group_fields(group_id, fields)
	return ""
