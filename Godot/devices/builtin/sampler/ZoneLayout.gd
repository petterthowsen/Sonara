## ZoneLayout.gd
## Pure range math for Sampler multisamples (spec 023, REQ-020 and REQ-047): root keys from file
## names, the default key layout of a set of zones, and the batch operations. Nothing here touches
## the model or the engine. Batch functions return `{zone_id: fields}` dictionaries that
## `SamplerMultisample.set_zone_fields` accepts.
class_name ZoneLayout extends RefCounted

const KEY_MIN := SamplerZone.KEY_MIN
const KEY_MAX := SamplerZone.KEY_MAX
const VEL_MIN := SamplerZone.VEL_MIN
const VEL_MAX := SamplerZone.VEL_MAX
## Where consecutive layouts start when nothing says otherwise (C3).
const DEFAULT_START_KEY := 60

const _NOTE_OFFSETS := {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}

static var _note_re: RegEx = null
static var _number_re: RegEx = null


## MIDI note named in `file_name` (C3 = 60), or -1. Recognizes `C3`, `C#3`, `Db3`, `c-1`, and a
## standalone 0-127 number such as `pad-060`. A note name wins over a number.
static func parse_root(file_name: String) -> int:
	if _note_re == null:
		_note_re = RegEx.create_from_string("(?<![A-Za-z])([A-Ga-g])([#b]?)(-?\\d)(?!\\d)")
		_number_re = RegEx.create_from_string("(?<!\\d)(\\d{1,3})(?!\\d)")
	var base := file_name.get_file().get_basename()
	var note_matches := _note_re.search_all(base)
	for m in note_matches:
		var semitone: int = _NOTE_OFFSETS[m.get_string(1).to_lower()]
		match m.get_string(2):
			"#":
				semitone += 1
			"b":
				semitone -= 1
		var note := (int(m.get_string(3)) + 2) * 12 + semitone
		if note >= KEY_MIN and note <= KEY_MAX:
			return note
	if not note_matches.is_empty():
		return -1  # a note name out of range: its octave digit is not a MIDI number
	for m in _number_re.search_all(base):
		var number := int(m.get_string(1))
		if number >= KEY_MIN and number <= KEY_MAX:
			return number
	return -1


## Key layout for a set of zones given their detected roots (-1 = none), index-aligned with
## `roots`. Returns `[{root, key_lo, key_hi}]` in the same order.
## - Zones with a root reach halfway to their neighbours' roots; the lowest starts at `at_key`
##   (0 when negative) and the highest ends at 127.
## - Zones with no root get consecutive single keys. With no detected root they start at `at_key`
##   (C3 when negative); otherwise they follow the highest detected root, whose range then stops
##   at that root so the two sets don't overlap.
## Zones with the same root share a range. Keys past 127 clamp to 127.
static func layout(roots: Array, at_key: int = -1) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var distinct: Array[int] = []
	var has_undetected := false
	for r in roots:
		var root := int(r)
		if root < 0:
			has_undetected = true
		elif not distinct.has(root):
			distinct.append(root)
	distinct.sort()
	var first_key := at_key if at_key >= 0 else KEY_MIN
	var lo_by_root := {}
	var hi_by_root := {}
	for i in distinct.size():
		var lo := first_key if i == 0 else int(hi_by_root[distinct[i - 1]]) + 1
		var hi := KEY_MAX
		if i + 1 < distinct.size():
			hi = (distinct[i] + distinct[i + 1]) / 2
		elif has_undetected:
			hi = distinct[i]
		lo_by_root[distinct[i]] = mini(lo, hi)
		hi_by_root[distinct[i]] = hi
	var next_key := DEFAULT_START_KEY
	if at_key >= 0:
		next_key = at_key
	if not distinct.is_empty():
		next_key = distinct[-1] + 1
	for r in roots:
		var root := int(r)
		if root >= 0:
			out.append({"root": root, "key_lo": lo_by_root[root], "key_hi": hi_by_root[root]})
		else:
			var key := mini(next_key, KEY_MAX)
			out.append({"root": key, "key_lo": key, "key_hi": key})
			next_key += 1
	return out


## Every zone gets the velocity range `lo`..`hi` (a single value when equal).
static func assign_velocity(zones: Array, lo: int, hi: int) -> Dictionary:
	var rng := _ordered(lo, hi, VEL_MIN, VEL_MAX)
	var out := {}
	for zone in zones:
		out[zone.id] = {"vel_lo": rng[0], "vel_hi": rng[1]}
	return out


## Every zone gets the key range `lo`..`hi` (a single key when equal).
static func assign_note(zones: Array, lo: int, hi: int) -> Dictionary:
	var rng := _ordered(lo, hi, KEY_MIN, KEY_MAX)
	var out := {}
	for zone in zones:
		out[zone.id] = {"key_lo": rng[0], "key_hi": rng[1]}
	return out


## Split `lo`..`hi` across the zones in the given order without changing key ranges.
## `stretch`: contiguous slices that fill the range. Otherwise equal slices of `slice` steps
## from `lo`, the rest of the range left empty.
static func distribute_velocity(zones: Array, lo: int, hi: int, stretch := true, slice := 1) -> Dictionary:
	var rng := _ordered(lo, hi, VEL_MIN, VEL_MAX)
	var slices := slice_range(zones.size(), rng[0], rng[1], stretch, slice)
	var out := {}
	for i in zones.size():
		out[zones[i].id] = {"vel_lo": slices[i][0], "vel_hi": slices[i][1]}
	return out


## Split `lo`..`hi` across the zones ordered by root key (list order for equal roots) without
## changing velocity ranges. `stretch` and `slice` as in `distribute_velocity`.
static func distribute_notes(zones: Array, lo: int, hi: int, stretch := true, slice := 1) -> Dictionary:
	var rng := _ordered(lo, hi, KEY_MIN, KEY_MAX)
	var sorted := _sorted_by_root(zones)
	var slices := slice_range(sorted.size(), rng[0], rng[1], stretch, slice)
	var out := {}
	for i in sorted.size():
		out[sorted[i].id] = {"key_lo": slices[i][0], "key_hi": slices[i][1]}
	return out


## The roots detected in the zones' names. Zones without a detectable root are left out.
static func set_root_from_name(zones: Array) -> Dictionary:
	var out := {}
	for zone in zones:
		var root := parse_root(zone.name)
		if root >= 0:
			out[zone.id] = {"root": root}
	return out


## `count` inclusive `[lo, hi]` slices of `lo`..`hi`, never empty:
## - stretch, with at least one step per slice: boundaries at ceil(i * steps / count), so
##   1..127 over four gives 1-32, 33-64, 65-96, 97-127
## - stretch, more slices than steps: one step each, slices share steps in order
## - gaps: `slice` steps each from `lo`; slices that fall past `hi` stack on its last step
static func slice_range(count: int, lo: int, hi: int, stretch := true, slice := 1) -> Array:
	var out: Array = []
	if count <= 0:
		return out
	var steps := hi - lo + 1
	if not stretch:
		var size := maxi(1, slice)
		for i in count:
			var s := mini(lo + i * size, hi)
			out.append([s, mini(s + size - 1, hi)])
	elif count > steps:
		for i in count:
			var s := lo + i * steps / count
			out.append([s, s])
	else:
		for i in count:
			var from := lo + (i * steps + count - 1) / count
			var to := lo + ((i + 1) * steps + count - 1) / count - 1
			out.append([from, to])
	return out


static func _ordered(lo: int, hi: int, min_v: int, max_v: int) -> Array[int]:
	lo = clampi(lo, min_v, max_v)
	hi = clampi(hi, min_v, max_v)
	return [mini(lo, hi), maxi(lo, hi)]


## Stable sort by root key.
static func _sorted_by_root(zones: Array) -> Array:
	var indexed: Array = []
	for i in zones.size():
		indexed.append([zones[i].root, i])
	indexed.sort_custom(func(a, b) -> bool: return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	return indexed.map(func(e): return zones[e[1]])
