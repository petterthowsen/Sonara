class_name TimeSignatureMap extends RefCounted

## Time signature changes: (bar, numerator, denominator) with 1-based bars, held until the next
## change. The base signature (before the first change) stays `Project.time_numerator` /
## `time_denominator` and is passed to the lookups, as `TempoMap` takes the static tempo. Storing
## bars rather than ticks means editing the base signature moves later changes in time but never
## off a bar line. The engine gets the whole map on every change (`Project` sends
## `/transport/time_signature_map`) and walks it the same way as `time_signature_map.rs`.

signal changed()

const MAX_NUMERATOR := 32
const DENOMINATORS: Array[int] = [1, 2, 4, 8, 16, 32]

## Each change is {id: int, bar: int, numerator: int, denominator: int}, sorted by bar, all bars >= 2.
var changes: Array[Dictionary] = []

var _next_id: int = 1
var _cache: Array[Dictionary] = []
var _cache_key: Array = []


func is_empty() -> bool:
	return changes.is_empty()


## Insert a change and return its id. Bar 1 becomes bar 2 (bar 1 is the base signature), and a
## change already on `bar` is edited instead.
func add_change(bar: int, numerator: int, denominator: int) -> int:
	bar = maxi(2, bar)
	var existing := index_at_bar(bar)
	if existing >= 0:
		changes[existing]["numerator"] = clampi(numerator, 1, MAX_NUMERATOR)
		changes[existing]["denominator"] = _clamp_denominator(denominator)
		_changed()
		return changes[existing]["id"]
	var change := {
		"id": _next_id,
		"bar": bar,
		"numerator": clampi(numerator, 1, MAX_NUMERATOR),
		"denominator": _clamp_denominator(denominator),
	}
	_next_id += 1
	changes.append(change)
	_sort()
	_changed()
	return change["id"]


## Change a change's bar and signature. The bar stays between its neighbours, so the order never changes.
func update_change(change_id: int, bar: int, numerator: int, denominator: int) -> void:
	var index := index_of(change_id)
	if index < 0:
		return
	changes[index]["bar"] = clamp_bar(index, bar)
	changes[index]["numerator"] = clampi(numerator, 1, MAX_NUMERATOR)
	changes[index]["denominator"] = _clamp_denominator(denominator)
	_changed()


## `bar` limited to the open range between the neighbours of change `index` (and bar 2 and up).
func clamp_bar(index: int, bar: int) -> int:
	var lo := 2 if index == 0 else int(changes[index - 1]["bar"]) + 1
	var hi := 999999 if index == changes.size() - 1 else int(changes[index + 1]["bar"]) - 1
	return clampi(bar, lo, maxi(lo, hi))


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


func index_at_bar(bar: int) -> int:
	for i in changes.size():
		if changes[i]["bar"] == bar:
			return i
	return -1


## Bar-aligned stretches of constant signature, starting with the base one at tick 0. Each is
## {bar, tick, numerator, denominator, bar_ticks, beat_ticks, end_tick} where `bar` is the 1-based bar
## the stretch starts on and `end_tick` is the next stretch's tick (-1 for the last). Cached until
## the map, the base signature or PPQ changes. Treat the result as read-only.
func segments(base_num: int, base_den: int, ppq: int) -> Array[Dictionary]:
	var key := [base_num, base_den, ppq]
	if key == _cache_key:
		return _cache
	_cache = []
	var bar := 1
	var tick := 0
	var num := maxi(1, base_num)
	var den := maxi(1, base_den)
	for change in changes:
		var seg_bar_ticks := GridHelper.bar_ticks(ppq, num, den)
		var change_tick: int = tick + (int(change["bar"]) - bar) * seg_bar_ticks
		_cache.append(_make_segment(bar, tick, num, den, ppq, change_tick))
		bar = change["bar"]
		tick = change_tick
		num = change["numerator"]
		den = change["denominator"]
	_cache.append(_make_segment(bar, tick, num, den, ppq, -1))
	_cache_key = key
	return _cache


static func _make_segment(bar: int, tick: int, num: int, den: int, ppq: int, end_tick: int) -> Dictionary:
	return {
		"bar": bar,
		"tick": tick,
		"numerator": num,
		"denominator": den,
		"bar_ticks": GridHelper.bar_ticks(ppq, num, den),
		"beat_ticks": GridHelper.beat_ticks(ppq, den),
		"end_tick": end_tick,
	}


## Index into `segments()` of the stretch containing `tick` (negative ticks belong to the first).
func segment_index_at_tick(tick: int, base_num: int, base_den: int, ppq: int) -> int:
	var segs := segments(base_num, base_den, ppq)
	var index := 0
	for i in range(1, segs.size()):
		if tick < segs[i]["tick"]:
			break
		index = i
	return index


func tick_of_bar(bar: int, base_num: int, base_den: int, ppq: int) -> int:
	var segs := segments(base_num, base_den, ppq)
	var seg := segs[0]
	for s in segs:
		if s["bar"] > bar:
			break
		seg = s
	return int(seg["tick"]) + (bar - int(seg["bar"])) * int(seg["bar_ticks"])


## 1-based bar containing `tick`.
func bar_at_tick(tick: int, base_num: int, base_den: int, ppq: int) -> int:
	var segs := segments(base_num, base_den, ppq)
	var seg: Dictionary = segs[segment_index_at_tick(tick, base_num, base_den, ppq)]
	@warning_ignore("integer_division")
	return int(seg["bar"]) + maxi(0, tick - int(seg["tick"])) / int(seg["bar_ticks"])


## Signature in effect at `tick` as (numerator, denominator).
func signature_at_tick(tick: int, base_num: int, base_den: int, ppq: int) -> Vector2i:
	var segs := segments(base_num, base_den, ppq)
	var seg: Dictionary = segs[segment_index_at_tick(tick, base_num, base_den, ppq)]
	return Vector2i(seg["numerator"], seg["denominator"])


## Same shape as `GridHelper.bbt_of`, with bars counted through the changes.
@warning_ignore("integer_division")
func bbt_at_tick(tick: int, base_num: int, base_den: int, ppq: int) -> Dictionary:
	var segs := segments(base_num, base_den, ppq)
	var seg: Dictionary = segs[segment_index_at_tick(tick, base_num, base_den, ppq)]
	var into := maxi(0, tick - int(seg["tick"]))
	var rem: int = into % int(seg["bar_ticks"])
	var beat_rem: int = rem % int(seg["beat_ticks"])
	var tpsix := maxi(1, maxi(1, ppq) / 4)
	return {
		"bar": int(seg["bar"]) + into / int(seg["bar_ticks"]),
		"beat": rem / int(seg["beat_ticks"]) + 1,
		"sixteenth": beat_rem / tpsix + 1,
		"tick": beat_rem % tpsix,
	}


## Parse "N/D" (whitespace allowed) into Vector2i(N, D), or Vector2i.ZERO when invalid.
static func parse(text: String) -> Vector2i:
	var parts := text.strip_edges().split("/")
	if parts.size() != 2:
		return Vector2i.ZERO
	var n := parts[0].strip_edges()
	var d := parts[1].strip_edges()
	if not n.is_valid_int() or not d.is_valid_int():
		return Vector2i.ZERO
	var num := n.to_int()
	var den := d.to_int()
	if num < 1 or num > MAX_NUMERATOR or not DENOMINATORS.has(den):
		return Vector2i.ZERO
	return Vector2i(num, den)


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
	return changes.map(func(c): return {"bar": c["bar"], "numerator": c["numerator"], "denominator": c["denominator"]})


static func from_json(data: Array) -> TimeSignatureMap:
	var map := TimeSignatureMap.new()
	for entry in data:
		if not entry is Dictionary:
			continue
		var bar := int(entry.get("bar", 0))
		var num := int(entry.get("numerator", 0))
		var den := int(entry.get("denominator", 0))
		if bar < 2 or num < 1 or num > MAX_NUMERATOR or not DENOMINATORS.has(den):
			continue
		if map.index_at_bar(bar) >= 0:
			continue
		map.changes.append({"id": map._next_id, "bar": bar, "numerator": num, "denominator": den})
		map._next_id += 1
	map._sort()
	return map


static func _clamp_denominator(den: int) -> int:
	return den if DENOMINATORS.has(den) else 4


func _changed() -> void:
	_cache_key = []
	changed.emit()


func _sort() -> void:
	changes.sort_custom(func(a, b): return a["bar"] < b["bar"])
