# DeviceNaming.gd
# Sibling-unique instance names and slash-separated device paths.
class_name DeviceNaming extends RefCounted


## Strip edges and `/` so names stay path-safe.
static func sanitize(raw: String, fallback: String = "Device") -> String:
	var s := raw.strip_edges().replace("/", " ").strip_edges()
	while s.contains("  "):
		s = s.replace("  ", " ")
	return s if not s.is_empty() else fallback


## True when `candidate` matches an existing name (case-insensitive).
static func is_taken(existing: PackedStringArray, candidate: String) -> bool:
	var key := candidate.strip_edges().to_lower()
	if key.is_empty():
		return false
	for n in existing:
		if str(n).strip_edges().to_lower() == key:
			return true
	return false


## Return `desired` or `desired 2`, `desired 3`, … so it is unique among `existing`.
static func unique_in(existing: PackedStringArray, desired: String, fallback: String = "Device") -> String:
	var base := sanitize(desired, fallback)
	if not is_taken(existing, base):
		return base
	var n := 2
	while is_taken(existing, "%s %d" % [base, n]):
		n += 1
	return "%s %d" % [base, n]


## Split `Kick/Chain/Delay 2` into segments; empty parts are dropped.
static func split_path(path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for part in path.split("/"):
		var s := str(part).strip_edges()
		if not s.is_empty():
			out.append(s)
	return out


## Case-insensitive name equality.
static func names_equal(a: String, b: String) -> bool:
	return a.strip_edges().to_lower() == b.strip_edges().to_lower()


## All segments after the first.
static func skip_first(segs: PackedStringArray) -> PackedStringArray:
	var rest: PackedStringArray = []
	for i in range(1, segs.size()):
		rest.append(segs[i])
	return rest


## Display name for a host item (DeviceInstance or a stub with `name`).
static func item_name(item: Variant) -> String:
	if item == null:
		return ""
	if item.has_method("get_display_name"):
		return str(item.get_display_name())
	return str(item.name)


## Child list for a host item.
static func item_children(item: Variant) -> Array:
	if item == null:
		return []
	return item.children


## Walk named segments through a host list. Returns the item or `{ok:false, error}`.
static func walk_named(host: Array, segments: PackedStringArray) -> Variant:
	if segments.is_empty():
		return {"ok": false, "error": "path must include a device name"}
	var current_host: Array = host
	var inst: Variant = null
	for i in range(segments.size()):
		var seg := segments[i]
		var hits: Array = []
		for d in current_host:
			if names_equal(item_name(d), seg):
				hits.append(d)
		if hits.is_empty():
			return {"ok": false, "error": "No device named '%s'" % seg}
		if hits.size() > 1:
			return {"ok": false, "error": "Multiple devices named '%s'; use instance_id" % seg}
		inst = hits[0]
		current_host = item_children(inst)
	return inst


## Slice `items` with offset/limit. Returns total, offset, limit, next_offset, items.
static func page_items(items: Array, offset: int, limit: int) -> Dictionary:
	var total := items.size()
	var off := maxi(0, offset)
	var lim := limit if limit > 0 else 32
	var slice: Array = []
	var end := mini(total, off + lim)
	if off < total:
		for i in range(off, end):
			slice.append(items[i])
	var next_off := end if end < total else -1
	return {
		"total": total,
		"offset": off,
		"limit": lim,
		"next_offset": next_off,
		"items": slice,
	}
