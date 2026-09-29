class_name TempoMap extends RefCounted

## Tempo automation: BPM points over time, linearly interpolated. Only the tempo lane edits it, and
## it is saved with the project. With no points the project's static tempo applies, so an empty map
## changes nothing. The engine gets the whole map on every change (`Project` sends
## `/transport/tempo_map`) and plays it. Seconds use the same closed-form ramp integral as the engine.

signal changed()

const MIN_BPM := 20.0
const MAX_BPM := 999.0

## Each point is {id: int, tick: int, bpm: float}, sorted by tick.
var points: Array[Dictionary] = []

var _next_id: int = 1


func is_empty() -> bool:
	return points.is_empty()


## Insert a point and return its id. A point already on `tick` is replaced.
func add_point(tick: int, bpm: float) -> int:
	tick = maxi(0, tick)
	var existing := index_at_tick(tick)
	if existing >= 0:
		points[existing]["bpm"] = clamp_bpm(bpm)
		changed.emit()
		return points[existing]["id"]
	var point := {"id": _next_id, "tick": tick, "bpm": clamp_bpm(bpm)}
	_next_id += 1
	points.append(point)
	_sort()
	changed.emit()
	return point["id"]


## Move a point in time and value. It stays between its neighbours, so the order never changes.
func update_point(point_id: int, tick: int, bpm: float) -> void:
	var index := index_of(point_id)
	if index < 0:
		return
	var lo := 0 if index == 0 else int(points[index - 1]["tick"]) + 1
	var hi := 999999999 if index == points.size() - 1 else int(points[index + 1]["tick"]) - 1
	points[index]["tick"] = clampi(tick, lo, maxi(lo, hi))
	points[index]["bpm"] = clamp_bpm(bpm)
	changed.emit()


func remove_point(point_id: int) -> void:
	var index := index_of(point_id)
	if index < 0:
		return
	points.remove_at(index)
	changed.emit()


func index_of(point_id: int) -> int:
	for i in points.size():
		if points[i]["id"] == point_id:
			return i
	return -1


func index_at_tick(tick: int) -> int:
	for i in points.size():
		if points[i]["tick"] == tick:
			return i
	return -1


## Tempo at `tick`: linear between points, held before the first and after the last, and
## `fallback_bpm` when the map is empty.
func get_bpm_at_tick(tick: float, fallback_bpm: float) -> float:
	if points.is_empty():
		return fallback_bpm
	if tick <= points[0]["tick"]:
		return points[0]["bpm"]
	var last: Dictionary = points[points.size() - 1]
	if tick >= last["tick"]:
		return last["bpm"]
	for i in range(1, points.size()):
		var right: Dictionary = points[i]
		if tick <= right["tick"]:
			var left: Dictionary = points[i - 1]
			var t := float(tick - left["tick"]) / float(right["tick"] - left["tick"])
			return lerpf(left["bpm"], right["bpm"], t)
	return last["bpm"]


## Seconds elapsed from tick 0 to `tick`, through the ramps.
func seconds_at_tick(tick: float, fallback_bpm: float, ppq: int) -> float:
	if points.is_empty():
		return 60.0 * tick / (fallback_bpm * ppq)
	var first: Dictionary = points[0]
	if tick <= first["tick"]:
		return 60.0 * tick / (first["bpm"] * ppq)
	var acc: float = 60.0 * float(first["tick"]) / first["bpm"]  # seconds * ppq
	for i in range(1, points.size()):
		var left: Dictionary = points[i - 1]
		var right: Dictionary = points[i]
		if tick <= right["tick"]:
			var bpm_here := get_bpm_at_tick(tick, fallback_bpm)
			return (acc + _segment_seconds_ppq(tick - float(left["tick"]), left["bpm"], bpm_here)) / ppq
		acc += _segment_seconds_ppq(float(right["tick"] - left["tick"]), left["bpm"], right["bpm"])
	var last: Dictionary = points[points.size() - 1]
	return (acc + 60.0 * (tick - float(last["tick"])) / last["bpm"]) / ppq


## Inverse of `seconds_at_tick`.
func tick_at_seconds(seconds: float, fallback_bpm: float, ppq: int) -> float:
	var target := seconds * ppq  # seconds * ppq
	if points.is_empty():
		return target * fallback_bpm / 60.0
	var first: Dictionary = points[0]
	var acc: float = 60.0 * float(first["tick"]) / first["bpm"]
	if target <= acc:
		return target * first["bpm"] / 60.0
	for i in range(1, points.size()):
		var left: Dictionary = points[i - 1]
		var right: Dictionary = points[i]
		var length := float(right["tick"] - left["tick"])
		var seg := _segment_seconds_ppq(length, left["bpm"], right["bpm"])
		if target <= acc + seg:
			var local := target - acc
			var b0: float = left["bpm"]
			var b1: float = right["bpm"]
			if absf(b1 - b0) < 1e-9:
				return float(left["tick"]) + local * b0 / 60.0
			var slope := (b1 - b0) / length
			return float(left["tick"]) + (b0 * exp(slope * local / 60.0) - b0) / slope
		acc += seg
	var last: Dictionary = points[points.size() - 1]
	return float(last["tick"]) + (target - acc) * last["bpm"] / 60.0


## Seconds * ppq for `length` ticks going linearly from `b0` to `b1` BPM.
static func _segment_seconds_ppq(length: float, b0: float, b1: float) -> float:
	if absf(b1 - b0) < 1e-9:
		return 60.0 * length / b0
	return 60.0 * length / (b1 - b0) * log(b1 / b0)


static func clamp_bpm(bpm: float) -> float:
	return clampf(bpm, MIN_BPM, MAX_BPM)


## Copy of the points, for undo snapshots.
func snapshot() -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for p in points:
		copy.append(p.duplicate())
	return copy


func restore(snap: Array[Dictionary]) -> void:
	points.clear()
	for p in snap:
		points.append(p.duplicate())
	changed.emit()


func to_json() -> Array:
	return points.map(func(p): return {"tick": p["tick"], "bpm": p["bpm"]})


static func from_json(data: Array) -> TempoMap:
	var map := TempoMap.new()
	for entry in data:
		if entry is Dictionary:
			map.points.append({
				"id": map._next_id,
				"tick": maxi(0, int(entry.get("tick", 0))),
				"bpm": clamp_bpm(float(entry.get("bpm", 120.0))),
			})
			map._next_id += 1
	map._sort()
	return map


func _sort() -> void:
	points.sort_custom(func(a, b): return a["tick"] < b["tick"])
