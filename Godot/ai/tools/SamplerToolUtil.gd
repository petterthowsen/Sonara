# SamplerToolUtil.gd
# What the assistant sees of a Sampler's multisample (spec 023), and the lookups and parsing that
# `edit_sampler` uses: zones and groups by name, note names, key and velocity ranges. Zones and
# groups are addressed by name, never by their numeric ids.
class_name SamplerToolUtil extends RefCounted

## Group play modes, by SamplerZoneGroup.PlayMode index.
const PLAY_MODES := ["all", "round_robin", "random"]
## Zone loop modes, by SamplerZone.loop_mode.
const LOOP_MODES := ["off", "on", "ping_pong"]
## Zones listed per page by `describe`.
const PAGE_SIZE := 100
## The most a zone or group can be boosted (SamplerZone and SamplerZoneGroup clamp gain to 4.0).
const MAX_GAIN_DB := 12.0
## How new zones are laid out (`add_samples` / `add_device` `as`): `keys` from the note names
## or numbers in the file names; `velocity_layers` and `round_robin` give every zone every key
## (one sound, e.g. a drum hit), split by velocity in name order or taking turns.
const SPREADS := ["keys", "velocity_layers", "round_robin"]
## The group `round_robin` puts its zones in.
const ROUND_ROBIN_GROUP := "Round Robin"
## Words that mean a whole key or velocity range.
const _FULL_WORDS := ["all", "full"]

static var _note_re: RegEx = null
static var _note_in_name_re: RegEx = null


## The Sampler at `inst`, or the first one inside it (a drum pad that holds a chain). Null if none.
static func find_sampler(inst: DeviceInstance) -> DeviceInstance:
	if inst == null:
		return null
	if inst.is_sampler():
		return inst
	for child in inst.children:
		var found := find_sampler(child)
		if found:
			return found
	return null


static func is_multisample(inst: DeviceInstance) -> bool:
	return inst != null and inst.is_sampler() and inst.multisample != null and inst.multisample.active


## Multisample fields for a compact device row. Empty for anything but a multisample Sampler.
static func row_fields(inst: DeviceInstance) -> Dictionary:
	if not is_multisample(inst):
		return {}
	var ms := inst.multisample
	var out := {"mode": "multisample", "zone_count": ms.zones.size()}
	if not ms.groups.is_empty():
		out["groups"] = ms.groups.map(func(g: SamplerZoneGroup): return g.name)
	return out


# --- description -----------------------------------------------------------

## The multisample as text: a summary line, the groups, then one line per zone (a page of
## PAGE_SIZE from `offset`).
static func describe(inst: DeviceInstance, offset: int = 0) -> String:
	var ms := inst.multisample
	var lines: PackedStringArray = []
	lines.append("Multisample: %d zones. The device's Root, Tune, Fine, Start, End, Reverse, Loop and Crossfade parameters are ignored; each zone has its own. Edit zones and groups with edit_sampler." % ms.zones.size())
	var warning := key_track_warning(inst)
	if not warning.is_empty():
		lines.append(warning)
	lines.append("Groups: %s" % ", ".join(_group_texts(ms)))
	if ms.zones.is_empty():
		lines.append("No zones yet: add some with edit_sampler add_samples.")
		return "\n".join(lines)
	var start := clampi(offset, 0, ms.zones.size())
	var stop := mini(start + PAGE_SIZE, ms.zones.size())
	lines.append("Zones (name: keys, velocity, root, group, settings):")
	for i in range(start, stop):
		lines.append("- %s" % zone_text(ms, ms.zones[i]))
	if start > 0 or stop < ms.zones.size():
		var more := " Next page: zone_offset %d." % stop if stop < ms.zones.size() else ""
		lines.append("Zones %d-%d of %d shown.%s" % [start + 1, stop, ms.zones.size(), more])
	return "\n".join(lines)


## A warning when Key Track is off but some zone spans several keys (REQ-018: those keys then all
## play the sample at its recorded pitch). Empty otherwise.
static func key_track_warning(inst: DeviceInstance) -> String:
	if inst.get_parameter_by_name("Key Track") == null or inst.get_parameter_real_by_name("Key Track") >= 0.5:
		return ""
	for zone in inst.multisample.zones:
		if zone.key_hi > zone.key_lo:
			return "Key Track is off, so a zone plays at its recorded pitch on every key of its range. For a pitched instrument, turn it on: set_device_params {\"Key Track\": true}."
	return ""


## `Piano C3: keys C2 to D#3, vel 1-127, root C3, group Soft; tune +2 st, gain -3.0 dB, loop on`
static func zone_text(ms: SamplerMultisample, zone: SamplerZone) -> String:
	var keys := note_name(zone.key_lo) if zone.key_lo == zone.key_hi else "%s to %s" % [note_name(zone.key_lo), note_name(zone.key_hi)]
	var vel := str(zone.vel_lo) if zone.vel_lo == zone.vel_hi else "%d-%d" % [zone.vel_lo, zone.vel_hi]
	var text := "%s: keys %s, vel %s, root %s" % [zone.name, keys, vel, note_name(zone.root)]
	if zone.group_id != SamplerZoneGroup.UNGROUPED_ID:
		text += ", group %s" % ms.get_group(zone.group_id).name
	var extras := _zone_extras(zone)
	if not extras.is_empty():
		text += "; " + ", ".join(extras)
	return text


## Non-default per-zone settings, in the order the zone editor shows them.
static func _zone_extras(zone: SamplerZone) -> PackedStringArray:
	var out: PackedStringArray = []
	if zone.tune != 0.0:
		out.append("tune %+g st" % zone.tune)
	if zone.fine != 0.0:
		out.append("fine %+g ct" % zone.fine)
	if not is_equal_approx(zone.gain, 1.0):
		out.append("gain %s" % gain_text(zone.gain))
	if zone.start > 0.0 or zone.end < 1.0:
		out.append("start %.3f end %.3f" % [zone.start, zone.end])
	if zone.reverse:
		out.append("reverse")
	if zone.loop_mode != 0:
		out.append("loop %s %.3f-%.3f" % [LOOP_MODES[zone.loop_mode], zone.loop_start, zone.loop_end])
		if zone.crossfade > 0.0:
			out.append("crossfade %.2f" % zone.crossfade)
	if zone.key_fade_lo > 0 or zone.key_fade_hi > 0:
		out.append("key fade %d/%d" % [zone.key_fade_lo, zone.key_fade_hi])
	if zone.vel_fade_lo > 0 or zone.vel_fade_hi > 0:
		out.append("vel fade %d/%d" % [zone.vel_fade_lo, zone.vel_fade_hi])
	if zone.is_missing():
		out.append("MISSING FILE (%s)" % zone.missing_reason())
	return out


## `Soft (3 zones, gain -3.0 dB, round_robin, mute)`. Ungrouped is listed only when it holds zones
## or has non-default settings.
static func _group_texts(ms: SamplerMultisample) -> PackedStringArray:
	var out: PackedStringArray = []
	var all: Array[SamplerZoneGroup] = [ms.ungrouped]
	all.append_array(ms.groups)
	for group in all:
		var count := ms.zones_in_group(group.id).size()
		var bits: PackedStringArray = ["%d zones" % count]
		if not is_equal_approx(group.gain, 1.0):
			bits.append("gain %s" % gain_text(group.gain))
		if group.play_mode != SamplerZoneGroup.PlayMode.ALL:
			bits.append(PLAY_MODES[group.play_mode])
		if group.mute:
			bits.append("mute")
		if group.solo:
			bits.append("solo")
		if group.id == SamplerZoneGroup.UNGROUPED_ID and count == 0 and bits.size() == 1:
			continue
		out.append("%s (%s)" % [group.display_name(), ", ".join(bits)])
	if out.is_empty():
		out.append("none")
	return out


static func gain_text(linear: float) -> String:
	return "-inf dB" if linear <= 0.0 else "%+.1f dB" % linear_to_db(linear)


# --- spreads ---------------------------------------------------------------

## Lay out the zones `ids` per `spread` (one of SPREADS; `keys` leaves them as placed), without
## recording. Zones are taken in natural name order, softest first (`1-Kick` before `10-Kick`).
## Returns "" or an error.
static func apply_spread(ms: SamplerMultisample, ids: Array, spread: String) -> String:
	if spread == "keys" or ids.is_empty():
		return ""
	if not spread in SPREADS:
		return "as must be one of %s" % ", ".join(SPREADS)
	var zones: Array = ZoneLayout.sorted_by_name(ids.map(func(id): return ms.get_zone(id)))
	var changes := ZoneLayout.assign_note(zones, ZoneLayout.KEY_MIN, ZoneLayout.KEY_MAX)
	var vel: Dictionary
	if spread == "velocity_layers":
		vel = ZoneLayout.distribute_velocity(zones, ZoneLayout.VEL_MIN, ZoneLayout.VEL_MAX)
	else:
		vel = ZoneLayout.assign_velocity(zones, ZoneLayout.VEL_MIN, ZoneLayout.VEL_MAX)
	for id in changes:
		changes[id].merge(vel[id])
	ms.set_zones_fields(changes)
	if spread == "round_robin":
		var found = find_group(ms, ROUND_ROBIN_GROUP)
		var group_id: int = found.id if found is SamplerZoneGroup else ms.add_group(ROUND_ROBIN_GROUP)
		ms.set_group_fields(group_id, {"play_mode": PLAY_MODES.find("round_robin")})
		ms.move_to_group(ids, group_id)
	return ""


## The drum pad note `inst` plays on (its own or an enclosing pad's slot note), or -1.
static func pad_note(inst: DeviceInstance) -> int:
	var at := inst
	while at != null:
		if at.slot_note >= 0:
			return at.slot_note
		at = at.get_parent_device()
	return -1


## The spread new zones get when the caller names none: on a drum pad, which only ever receives
## its own note, files without note names are takes of the pad's sound (velocity_layers);
## otherwise keys.
static func default_spread(inst: DeviceInstance, names: Array) -> String:
	return "velocity_layers" if pad_note(inst) >= 0 and names.size() > 1 and not any_note_name(names) else "keys"


## What `spread` did, for the tool result.
static func spread_text(spread: String) -> String:
	match spread:
		"velocity_layers":
			return "Laid out as velocity layers: every zone spans every key, velocity 1-127 split in name order, softest first."
		"round_robin":
			return "Laid out as round robins: every zone spans every key and velocity, in group %s (round_robin)." % ROUND_ROBIN_GROUP
	return ""


## True when some file name in `names` holds a note name such as `C3` or `F#-1`.
static func any_note_name(names: Array) -> bool:
	if _note_in_name_re == null:
		_note_in_name_re = RegEx.create_from_string("(?<![A-Za-z])[A-Ga-g][#b]?-?\\d(?!\\d)")
	return names.any(func(n) -> bool: return _note_in_name_re.search(str(n)) != null)


## A hint after laying out several files that carry no note names: their keys came from numbers
## (`1-Kick.wav` is key 1), which is wrong for takes of one sound. Empty when not needed.
static func spread_hint(names: Array) -> String:
	if names.size() < 2 or any_note_name(names):
		return ""
	return "These file names have no note names, so their keys came from numbers in the names or follow one another. For takes of one sound (drum hits), add them with as: velocity_layers (every key, velocity split softest first) or as: round_robin."


# --- lookups ---------------------------------------------------------------

## The audio assets directly in library folder `folder` (library-relative, case ignored), in
## natural name order, or AiTool.fail(...).
static func folder_audio(folder: String) -> Variant:
	var wanted := folder.strip_edges().trim_suffix("/").to_lower()
	var found: Array = []
	for asset in AssetService.get_all_assets():
		if asset.type == Asset.TYPE.Audio and AssetService.relative_path(asset).get_base_dir().to_lower() == wanted:
			found.append(asset)
	if found.is_empty():
		return AiTool.fail("No audio files directly in folder \"%s\" (list_assets shows folders)" % folder)
	return ZoneLayout.sorted_by_name(found.map(func(a: Asset): return {"name": a.path.get_file().get_basename(), "asset": a})).map(func(e): return e.asset)


## The group named `group_name` ("Ungrouped" is group 0), or AiTool.fail(...) listing the groups.
static func find_group(ms: SamplerMultisample, group_name: String) -> Variant:
	var wanted := group_name.strip_edges()
	if NameStyle.same(wanted, SamplerZoneGroup.UNGROUPED_NAME):
		return ms.ungrouped
	for group in ms.groups:
		if NameStyle.same(group.name, wanted):
			return group
	var names: PackedStringArray = [SamplerZoneGroup.UNGROUPED_NAME]
	for group in ms.groups:
		names.append(group.name)
	return AiTool.fail("No group named '%s'. Groups: %s" % [wanted, ", ".join(names)])


## The zones an op selects: `zones` (names, or "all" / ["all"]) and/or `in_group` (a group name); both
## together select the named zones of that group. Explicit names keep the order given (the
## velocity and note distributions follow it); "all" and groups use list order. A name shared by
## several zones selects them all. Without either, every zone unless `required`.
## Returns Array[SamplerZone], or AiTool.fail(...).
static func select_zones(ms: SamplerMultisample, op: Dictionary, required := false) -> Variant:
	if required and not op.has("zones") and not op.has("in_group"):
		return AiTool.fail("zones (names or \"all\") or in_group is required")
	var pool: Array[SamplerZone] = ms.zones
	if op.has("in_group"):
		var group_v = find_group(ms, str(op.in_group))
		if group_v is Dictionary:
			return group_v
		pool = ms.zones_in_group(group_v.id)
	var raw = op.get("zones", "all")
	var names: Array = raw if raw is Array else [raw]
	if names.size() == 1 and NameStyle.same(str(names[0]), "all"):
		return pool.duplicate()
	var out: Array[SamplerZone] = []
	var unknown: PackedStringArray = []
	for item in names:
		var hits := pool.filter(func(z: SamplerZone) -> bool: return NameStyle.same(z.name, str(item)))
		if hits.is_empty():
			unknown.append("'%s'" % str(item))
		for zone in hits:
			if not out.has(zone):
				out.append(zone)
	if not unknown.is_empty():
		var where := " in group %s" % str(op.in_group) if op.has("in_group") else ""
		return AiTool.fail("No zone named %s%s. %s" % [", ".join(unknown), where, _near_zone_names(pool, str(unknown[0]).trim_prefix("'").trim_suffix("'"))])
	if out.is_empty():
		return AiTool.fail("zones is empty")
	return out


## "Did you mean: …?" from zone names containing `query`, else the first few zone names.
static func _near_zone_names(pool: Array[SamplerZone], query: String) -> String:
	var q := NameStyle.key(query)
	var near: PackedStringArray = []
	for zone in pool:
		if near.size() >= 5:
			break
		if not q.is_empty() and NameStyle.key(zone.name).contains(q):
			near.append(zone.name)
	if not near.is_empty():
		return "Did you mean: %s?" % ", ".join(near)
	if pool.is_empty():
		return "There are no zones."
	var first: PackedStringArray = []
	for i in mini(pool.size(), 5):
		first.append(pool[i].name)
	return "Zones include: %s (get_device lists them all)." % ", ".join(first)


# --- parsing ---------------------------------------------------------------

## MIDI note from a number (0-127) or a note name (`C3` = 60, `F#2`, `Bb-1`). -1 if invalid.
static func parse_note(value: Variant) -> int:
	if value is int or value is float:
		var n := int(value)
		return n if float(n) == float(value) and n >= 0 and n <= 127 else -1
	var s := str(value).strip_edges()
	if s.is_valid_int():
		return parse_note(s.to_int())
	if _note_re == null:
		_note_re = RegEx.create_from_string("^([A-Ga-g])([#b]?)(-?\\d)$")
	var m := _note_re.search(s)
	if m == null:
		return -1
	var semitone: int = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}[m.get_string(1).to_lower()]
	match m.get_string(2):
		"#":
			semitone += 1
		"b":
			semitone -= 1
	var note := (int(m.get_string(3)) + 2) * 12 + semitone
	return note if note >= 0 and note <= 127 else -1


static func note_name(note: int) -> String:
	return Midi.midi_to_note_name(note)


## `[lo, hi]` (or one value for both) as notes when `notes`, else velocities 1-127.
## `{lo, hi}`, or `{error}` naming `field`.
## "all" / "full" (or `["all"]`) is the whole range: every key, or velocity 1-127.
static func parse_range(value: Variant, notes: bool, field: String) -> Dictionary:
	var items: Array = value if value is Array else [value]
	if items.size() == 1 and str(items[0]).strip_edges().to_lower() in _FULL_WORDS:
		return {"lo": ZoneLayout.KEY_MIN if notes else ZoneLayout.VEL_MIN, "hi": ZoneLayout.KEY_MAX if notes else ZoneLayout.VEL_MAX}
	if items.is_empty() or items.size() > 2:
		return {"error": "%s must be [low, high] or one value" % field}
	var parsed: Array[int] = []
	for item in items:
		var n := parse_note(item) if notes else _parse_velocity(item)
		if n < 0:
			var what := "a note: C-2 (0) to G8 (127), C3 = 60, or \"all\" for every key" if notes else "a velocity 1-127, or \"all\""
			return {"error": "%s: '%s' is not %s" % [field, str(item), what]}
		parsed.append(n)
	var lo: int = parsed[0]
	var hi: int = parsed[-1]
	if lo > hi:
		return {"error": "%s: low %s is above high %s" % [field, str(items[0]), str(items[-1])]}
	return {"lo": lo, "hi": hi}


static func _parse_velocity(value: Variant) -> int:
	var s := str(value).strip_edges()
	if not (value is int or value is float or s.is_valid_int()):
		return -1
	var n := int(value) if not value is String else s.to_int()
	return n if n >= 1 and n <= 127 else -1


## Linear gain from `gain_db` (at most +12 dB). `{gain}` or `{error}`.
static func parse_gain_db(value: Variant) -> Dictionary:
	if not (value is int or value is float or str(value).is_valid_float()):
		return {"error": "gain_db must be a number"}
	var db := float(value)
	if db > MAX_GAIN_DB:
		return {"error": "gain_db is at most +%d dB" % int(MAX_GAIN_DB)}
	return {"gain": db_to_linear(db) if db > -120.0 else 0.0}


## The index of `value` in `options` (loose: case, `-` and spaces ignored), or -1.
static func parse_choice(value: Variant, options: Array) -> int:
	var key := str(value).strip_edges().to_lower().replace("-", "_").replace(" ", "_")
	return options.find(key)
