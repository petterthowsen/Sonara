# AutomationPointSelectionManager.gd
# Owns automation point selection, the box-select gesture and the segment clipboard, mirroring
# ClipSelectionManager's modifiers (REQ-020, REQ-021).
#
# Selection is scoped to ONE lane at a time: REQ-020 asks for box-select "within a lane row", and
# a point's value only means anything against its own lane's target, so selecting across lanes
# would make a group drag ambiguous. Clicking in another lane moves the scope there.
#
# Geometry stays in AutomationLaneRow; this class only ever deals in ticks, values and point ids.
class_name AutomationPointSelectionManager extends RefCounted

static var logger := Log.make("AutomationPointSelectionManager")

signal selection_changed(lane: AutomationLane, point_ids: Array)
signal clipboard_changed()

var grid_helper: GridHelper = null

## The lane the current selection lives in, or null when nothing is selected.
var lane: AutomationLane = null

## Selected point ids within `lane`, as an ordered set (id -> true).
var _selected: Dictionary = {}

## Last clicked tick in a lane row. Paste targets it, matching ClipSelectionManager.anchor_tick.
var anchor_tick: int = -1

## Grid-snapped time range from the last box select, used by the range-aware operations.
var range_visible: bool = false
var range_start_tick: int = 0
var range_end_tick: int = 0

## Segment clipboard: {"points": [{tick_offset, value, curve, tension}], "length_ticks": int}.
## Held as plain data, not point objects, so a paste after the source lane was deleted still works.
var clipboard: Dictionary = {}


# ============================================================================
# SELECTION
# ============================================================================

func has_selection() -> bool:
	return lane != null and not _selected.is_empty()


## Selected point ids, in the lane's tick order.
func get_selected_ids() -> Array:
	var ids: Array = []
	if lane == null:
		return ids
	for point in lane.points:
		if _selected.has(point.id):
			ids.append(point.id)
	return ids


## The selected AutomationPoint objects, freshly fetched from the lane. Always re-fetch rather
## than caching: `AutomationLane.update_point()` replaces the object behind a given id.
func get_selected_points() -> Array:
	var points: Array = []
	if lane == null:
		return points
	for point in lane.points:
		if _selected.has(point.id):
			points.append(point)
	return points


func is_selected(p_lane: AutomationLane, point_id: int) -> bool:
	return p_lane == lane and _selected.has(point_id)


func clear_selection() -> void:
	if lane == null and _selected.is_empty():
		return
	lane = null
	_selected.clear()
	hide_range()
	_emit()


func select_only(p_lane: AutomationLane, point_id: int) -> void:
	lane = p_lane
	_selected.clear()
	_selected[point_id] = true
	_emit()


## Ctrl-click: add or drop one point, switching lanes if the click landed in a different row.
func toggle(p_lane: AutomationLane, point_id: int) -> void:
	if p_lane != lane:
		select_only(p_lane, point_id)
		return
	if _selected.has(point_id):
		_selected.erase(point_id)
	else:
		_selected[point_id] = true
	_emit()


func select_ids(p_lane: AutomationLane, ids: Array) -> void:
	lane = p_lane
	_selected.clear()
	for id in ids:
		_selected[id] = true
	_emit()


## Drop a point that no longer exists (deleted, or undone) from the selection.
func forget_point(p_lane: AutomationLane, point_id: int) -> void:
	if p_lane != lane or not _selected.has(point_id):
		return
	_selected.erase(point_id)
	_emit()


## Drop the whole selection when its lane goes away.
func forget_lane(p_lane: AutomationLane) -> void:
	if p_lane == lane:
		clear_selection()


func _emit() -> void:
	selection_changed.emit(lane, get_selected_ids())


# ============================================================================
# TIME RANGE
# ============================================================================

func set_anchor(tick: int) -> void:
	if tick >= 0:
		anchor_tick = tick


func hide_range() -> void:
	range_visible = false
	range_start_tick = 0
	range_end_tick = 0


## Store a grid-snapped range. An empty span (start == end) only sets the anchor.
func set_range(start_tick: int, end_tick: int) -> void:
	var lo := mini(start_tick, end_tick)
	var hi := maxi(start_tick, end_tick)
	anchor_tick = lo
	if hi <= lo:
		hide_range()
		return
	range_visible = true
	range_start_tick = lo
	range_end_tick = hi


## (start, end) of the current range, or ZERO when there is none.
func get_full_range() -> Vector2i:
	if range_visible and range_end_tick > range_start_tick:
		return Vector2i(range_start_tick, range_end_tick)
	return Vector2i.ZERO


## Paste target: the range start, else the last clicked tick, else `fallback`.
func get_paste_tick(fallback: int) -> int:
	if range_visible:
		return range_start_tick
	if anchor_tick >= 0:
		return anchor_tick
	return fallback


## Duplicate target: the end of the range when there is one, otherwise the end of the selection.
func get_duplicate_tick(fallback: int) -> int:
	var full := get_full_range()
	if full != Vector2i.ZERO:
		return full.y
	var bounds := get_selection_bounds()
	if bounds != Vector2i.ZERO:
		return bounds.y
	return fallback


## (first tick, last tick) covered by the current selection, or ZERO when empty.
func get_selection_bounds() -> Vector2i:
	var points := get_selected_points()
	if points.is_empty():
		return Vector2i.ZERO
	var lo: int = points[0].tick
	var hi: int = points[0].tick
	for point in points:
		lo = mini(lo, point.tick)
		hi = maxi(hi, point.tick)
	return Vector2i(lo, hi)


# ============================================================================
# CLIPBOARD (REQ-021)
# ============================================================================

## The points a range/selection operation applies to, and the tick they are measured from.
## Prefers the active time range, matching the clip conventions; falls back to the selection.
func get_operand(p_lane: AutomationLane = null) -> Dictionary:
	var source_lane: AutomationLane = p_lane if p_lane else lane
	if source_lane == null:
		return {}

	var full := get_full_range()
	if full != Vector2i.ZERO:
		var in_range: Array = []
		for point in source_lane.points:
			if point.tick >= full.x and point.tick < full.y:
				in_range.append(point)
		return {"lane": source_lane, "points": in_range, "origin": full.x, "length": full.y - full.x}

	var selected := get_selected_points()
	if selected.is_empty():
		return {}
	var bounds := get_selection_bounds()
	return {
		"lane": source_lane,
		"points": selected,
		"origin": bounds.x,
		"length": maxi(bounds.y - bounds.x, 0),
	}


## Copy the current operand into the clipboard. Returns false when there is nothing to copy.
func copy() -> bool:
	var operand := get_operand()
	if operand.is_empty() or operand["points"].is_empty():
		return false
	var origin: int = operand["origin"]
	var entries: Array = []
	for point in operand["points"]:
		entries.append({
			"tick_offset": point.tick - origin,
			"value": point.value,
			"curve": point.curve,
			"tension": point.tension,
		})
	clipboard = {"points": entries, "length_ticks": operand["length"]}
	clipboard_changed.emit()
	logger.info("Copied %d automation point(s)" % entries.size())
	return true


func has_clipboard() -> bool:
	return not clipboard.is_empty() and not clipboard.get("points", []).is_empty()


## Point specs for `AutomationActions.add_points`, shifted so the clipboard origin lands on
## `target_tick`. Empty when the clipboard is empty.
func clipboard_specs_at(target_tick: int) -> Array:
	var specs: Array = []
	for entry in clipboard.get("points", []):
		specs.append({
			"tick": maxi(0, target_tick + int(entry["tick_offset"])),
			"value": float(entry["value"]),
			"curve": int(entry["curve"]),
			"tension": float(entry["tension"]),
		})
	return specs


## How long the copied segment is, used to place a duplicate directly after it.
func clipboard_length() -> int:
	return int(clipboard.get("length_ticks", 0))
