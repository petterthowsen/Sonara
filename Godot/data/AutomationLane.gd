class_name AutomationLane extends RefCounted

## A lane of automation points driving one target on the track's linked channel. Follows the
## self-syncing pattern from `docs/subsystems/godot-osc.md`: mutators update state, send OSC, then
## emit. Mirrors `Engine/src/audio/automation.rs::AutomationLane`.

signal point_added(point: AutomationPoint)
signal point_removed(point_id: int)
signal point_changed(point: AutomationPoint)
signal bypass_changed(bypassed: bool)
signal visibility_changed(visible: bool)
signal height_changed(height: int)
signal resolved_changed(resolved: bool)

var id: String = ""
var target: AutomationTarget = null
var points: Array[AutomationPoint] = []  # Always sorted by tick.
var bypassed: bool = false

# Visual state (never sent to the engine).
var visible: bool = true
var height: int = 40
var color: Color = Color.from_string("#FFA500", Color.ORANGE)

## False when `target` no longer resolves against the linked channel (REQ-024). A lane in this
## state keeps its points but is not synced to the engine.
var resolved: bool = true

## Set by `Track` once this lane is attached, so mutators know where to send OSC. Null (or a
## track that is not connected) means "don't sync" - used for detached / test lanes.
var track: Object = null

var _next_point_id: int = 1


func _init(p_id: String = "", p_target: AutomationTarget = null) -> void:
	id = p_id
	target = p_target


## True when this lane has nothing to drive its target with.
func is_inert() -> bool:
	return bypassed or points.is_empty()


func set_bypassed(value: bool) -> void:
	if bypassed == value:
		return
	bypassed = value
	_send("/track/%d/automation/%s/bypass" % [_track_id(), id], [1 if bypassed else 0])
	bypass_changed.emit(bypassed)


func set_visible(value: bool) -> void:
	if visible == value:
		return
	visible = value
	visibility_changed.emit(visible)


func set_height(value: int) -> void:
	value = clampi(value, 20, 200)
	if height == value:
		return
	height = value
	height_changed.emit(height)


func set_resolved(value: bool) -> void:
	if resolved == value:
		return
	resolved = value
	resolved_changed.emit(resolved)


## Insert a new point, keeping the sorted-by-tick invariant, and send `add_point` (REQ-012).
func add_point(tick: int, value: float, curve: AutomationPoint.CurveType = AutomationPoint.CurveType.LINEAR,
		tension: float = 0.0) -> AutomationPoint:
	var point := AutomationPoint.new(_next_point_id, tick, value, curve, tension)
	_next_point_id += 1
	_insert_sorted(point)
	_send_point("add_point", point)
	point_added.emit(point)
	return point


## Move or reshape an existing point in place, keeping the sorted invariant, and send
## `update_point` (REQ-012).
##
## `curve` of -1 and a NAN `tension` mean "keep what the point already has", so a drag that only
## moves a point in time and value cannot silently flatten a STEP point back to LINEAR.
func update_point(point_id: int, tick: int, value: float,
		curve: int = -1, tension: float = NAN) -> bool:
	var index := _index_of(point_id)
	if index < 0:
		return false
	var existing: AutomationPoint = points[index]
	var new_curve: AutomationPoint.CurveType = existing.curve if curve < 0 else curve as AutomationPoint.CurveType
	var new_tension := existing.tension if is_nan(tension) else tension
	points.remove_at(index)
	var point := AutomationPoint.new(point_id, tick, value, new_curve, new_tension)
	_insert_sorted(point)
	_send_point("update_point", point)
	point_changed.emit(point)
	return true


## Remove one point and send `remove_point` (REQ-012).
func remove_point(point_id: int) -> bool:
	var index := _index_of(point_id)
	if index < 0:
		return false
	points.remove_at(index)
	_send("/track/%d/automation/%s/remove_point" % [_track_id(), id], [point_id])
	point_removed.emit(point_id)
	return true


## Remove every point, keeping the lane, and send `clear`.
func clear_points() -> void:
	if points.is_empty():
		return
	var removed_ids: Array[int] = []
	for point in points:
		removed_ids.append(point.id)
	points.clear()
	_send("/track/%d/automation/%s/clear" % [_track_id(), id], [])
	# One `point_removed` per point, so a view watching the lane redraws instead of going stale.
	for point_id in removed_ids:
		point_removed.emit(point_id)


func _index_of(point_id: int) -> int:
	for i in range(points.size()):
		if points[i].id == point_id:
			return i
	return -1


func _insert_sorted(point: AutomationPoint) -> void:
	var index := 0
	while index < points.size() and points[index].tick <= point.tick:
		index += 1
	points.insert(index, point)
	if point.id >= _next_point_id:
		_next_point_id = point.id + 1


func _send_point(action: String, point: AutomationPoint) -> void:
	_send("/track/%d/automation/%s/%s" % [_track_id(), id, action],
		[point.id, point.tick, point.value, point.curve_str(), point.tension])


func _track_id() -> int:
	return track.id if track != null else -1


func _send(address: String, args: Array) -> void:
	if track == null or not track.is_engine_connected():
		return
	if not resolved:
		# Unresolved lane (REQ-024): keep every point, drive nothing.
		return
	AudioEngineOSC.send(address, args)


## Send the lane's create message. Called by `Track` once the lane is attached to a connected
## track (REQ-012).
func sync_to_engine() -> void:
	if track == null or not resolved:
		return
	AudioEngineOSC.send("/track/%d/automation/create" % track.id, [id, str(target)])
	if bypassed:
		AudioEngineOSC.send("/track/%d/automation/%s/bypass" % [track.id, id], [1])
	for point in points:
		AudioEngineOSC.send("/track/%d/automation/%s/add_point" % [track.id, id],
			[point.id, point.tick, point.value, point.curve_str(), point.tension])


## Resolve the lane's normalized value at `tick` via binary search, or `NAN` when it has no
## points. Real-time UI drawing only - the audio-thread evaluator lives in the engine.
func get_value_at_tick(tick: int) -> float:
	if points.is_empty():
		return NAN

	if tick <= points[0].tick:
		return points[0].value
	if tick >= points[points.size() - 1].tick:
		return points[points.size() - 1].value

	# Binary search for the last point with tick <= target tick.
	var lo := 0
	var hi := points.size() - 1
	while lo < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi + 1) / 2
		if points[mid].tick <= tick:
			lo = mid
		else:
			hi = mid - 1

	var left: AutomationPoint = points[lo]
	var right: AutomationPoint = points[lo + 1] if lo + 1 < points.size() else null
	return AutomationCurve.evaluate(left, right, tick)


func to_json() -> Dictionary:
	return {
		"id": id,
		"target": str(target) if target else "",
		"points": points.map(func(p): return p.to_json()),
		"bypassed": bypassed,
		"visible": visible,
		"height": height,
		"color": color.to_html(),
	}


static func from_json(data: Dictionary, default_id: String = "") -> AutomationLane:
	var lane := AutomationLane.new()
	lane.id = data.get("id", default_id)
	lane.target = AutomationTarget.parse(data.get("target", ""))
	lane.bypassed = data.get("bypassed", false)
	lane.visible = data.get("visible", true)
	lane.height = data.get("height", 40)
	lane.color = Color.from_string(data.get("color", "#FFA500"), Color.ORANGE)

	var index := 0
	var max_id := 0
	for point_data in data.get("points", []):
		var point := AutomationPoint.from_json(point_data, index)
		lane.points.append(point)
		max_id = max(max_id, point.id)
		index += 1
	lane.points.sort_custom(func(a, b): return a.tick < b.tick)
	lane._next_point_id = max_id + 1

	return lane
