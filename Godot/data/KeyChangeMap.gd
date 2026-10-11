class_name KeyChangeMap extends RefCounted

## Key changes: (tick, root, type_id) with ticks held until the next change. The base key (before
## the first change) stays `Project.scale_root` / `scale_type` and is passed to the lookups. Tick
## anchoring (not bars, unlike `TimeSignatureMap`) means the engine looks the mask up by tick; the
## UI snaps new/dragged changes to bar lines. Tick 0 is the base key, so changes start at tick 1.
## The engine gets the whole map on every change (`Project` sends `/project/scale_map`, 12-bit
## masks) and walks it the same way as `scale_map.rs`.

signal changed()

## Each change is {id: int, tick: int, root: int, type_id: String}, sorted by tick, all ticks >= 1.
var changes: Array[Dictionary] = []

var _next_id: int = 1


func is_empty() -> bool:
	return changes.is_empty()


## Insert a change at `tick` and return its id. A change already on `tick` is edited instead
## (last write wins on that tick); tick 0 clamps to 1 because tick 0 is the base key.
func add_change(tick: int, root: int, type_id: String) -> int:
	tick = maxi(1, tick)
	root = posmod(root, 12)
	var existing := index_at_tick(tick)
	if existing >= 0:
		changes[existing]["root"] = root
		changes[existing]["type_id"] = type_id
		_changed()
		return changes[existing]["id"]
	var change := {
		"id": _next_id,
		"tick": tick,
		"root": root,
		"type_id": type_id,
	}
	_next_id += 1
	changes.append(change)
	_sort()
	_changed()
	return change["id"]


## Change a change's tick and key. The tick stays between its neighbours, so the order never changes.
func update_change(change_id: int, tick: int, root: int, type_id: String) -> void:
	var index := index_of(change_id)
	if index < 0:
		return
	changes[index]["tick"] = clamp_tick(index, tick)
	changes[index]["root"] = posmod(root, 12)
	changes[index]["type_id"] = type_id
	_changed()


## `tick` limited to the open range between the neighbours of change `index` (and tick 1 and up).
func clamp_tick(index: int, tick: int) -> int:
	var lo := 1 if index == 0 else int(changes[index - 1]["tick"]) + 1
	var hi := 2147483647 if index == changes.size() - 1 else int(changes[index + 1]["tick"]) - 1
	return clampi(tick, lo, maxi(lo, hi))


func remove_change(change_id: int) -> void:
	var index := index_of(change_id)
	if index < 0:
		return
	changes.remove_at(index)
	_changed()


func index_of(change_id: int) -> int:
	for i in changes.size():
		if changes[i]["id"] == change_id:
			return i
	return -1


func index_at_tick(tick: int) -> int:
	for i in changes.size():
		if changes[i]["tick"] == tick:
			return i
	return -1


## The key in effect at `tick`: the base key before the first change, then the change at or before
## it (a change takes effect exactly on its own tick).
func scale_at_tick(tick: int, base_root: int, base_type: String) -> MusicalScale:
	var root := base_root
	var type_id := base_type
	for change in changes:
		if int(change["tick"]) > tick:
			break
		root = int(change["root"])
		type_id = change["type_id"]
	return MusicalScale.make(root, type_id)


## Copy of the changes, for undo snapshots.
func snapshot() -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for c in changes:
		copy.append(c.duplicate())
	return copy


func restore(snap: Array[Dictionary]) -> void:
	changes.clear()
	for c in snap:
		changes.append(c.duplicate())
	_changed()


func to_json() -> Array:
	return changes.map(func(c): return {"tick": c["tick"], "root": c["root"], "type_id": c["type_id"]})


## Entries failing `MusicalScale.is_valid_type` are dropped (not coerced to "none") so a future
## type id does not become a silent "no scale" change; "none" itself is valid and survives.
static func from_json(data: Variant) -> KeyChangeMap:
	var map := KeyChangeMap.new()
	if not data is Array:
		return map
	for entry in data:
		if not entry is Dictionary:
			continue
		var tick := int(entry.get("tick", 0))
		var root := posmod(int(entry.get("root", 0)), 12)
		var type_id: String = str(entry.get("type_id", ""))
		if tick < 1 or not MusicalScale.is_valid_type(type_id):
			continue
		if map.index_at_tick(tick) >= 0:
			continue
		map.changes.append({"id": map._next_id, "tick": tick, "root": root, "type_id": type_id})
		map._next_id += 1
	map._sort()
	return map


## Flat `[tick, mask, …]` args for `/project/scale_map`.
func to_osc_args() -> Array:
	var args: Array = []
	for c in changes:
		args.append(int(c["tick"]))
		args.append(MusicalScale.make(int(c["root"]), c["type_id"]).mask())
	return args


func _changed() -> void:
	changed.emit()


func _sort() -> void:
	changes.sort_custom(func(a, b): return a["tick"] < b["tick"])
