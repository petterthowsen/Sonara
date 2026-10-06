## The multisample editor's zone map (spec 023, REQ-043–REQ-046, REQ-015, REQ-048): keys left to
## right, velocity bottom to top, each visible zone a rectangle spanning its ranges, and a
## horizontal piano along the bottom that auditions notes (higher up on a key = louder).
##
## - Click selects and focuses the zone under the pointer (Ctrl toggles, Shift selects a range in
##   list order). Clicking the same spot again cycles through the zones stacked there.
## - Dragging a zone body moves the selection by whole keys and velocity steps; dragging an edge
##   resizes that zone. Ranges stay within 0–127 / 1–127 and never empty. One undo step per drag.
## - With snapping on (the header toggle; Shift bypasses it) a moved zone's edges snap to the edges of
##   the zones around it, and a resized edge that touches a neighbour's edge carries that edge along.
## - Right-click lists the zones under the pointer, then the batch operations.
## - Audio files dropped on the map are added starting at the key under the pointer.
## - The mouse wheel zooms the key axis around the pointer; Shift+wheel, the horizontal wheel or a
##   middle-button drag pans it. A press on empty space starts a marquee box: it selects the zones it
##   touches (Ctrl adds them to the selection, Shift removes them).
##
## Zones are drawn in list order, so later zones sit on top; `zones_at` returns the top one first.
## `zones_at`, `edge_at`, `drag_result` and the geometry helpers are public for the tests.
class_name ZoneMap extends Control

enum Edge { NONE, LEFT, RIGHT, TOP, BOTTOM }
## How a marquee combines with the selection at its press: replace it, add to it (Ctrl), remove
## from it (Shift).
enum MarqueeMode { REPLACE, ADD, SUBTRACT }
enum DragMode { NONE, MOVE, RESIZE, AUDITION, MARQUEE }

const KEY_COUNT := 128
const VEL_STEPS := 127
const KEY_STRIP_HEIGHT := 30.0
## How far from an edge (px) it can be grabbed; less on small zones so their body stays movable.
const EDGE_GRAB := 4.0
## How close (px) an edge has to come to a neighbour's edge to snap to it.
const SNAP_PX := 6.0
## A press that moves less than this (px) is a click.
const CLICK_SLOP := 3.0
const LABEL_FONT_SIZE := 10
const HATCH_SPACING := 6.0
## The fewest keys the zoomed view shows.
const MIN_VIEW_KEYS := 12.0
## Zoom step per wheel notch, and pan per notch as a fraction of the visible keys.
const ZOOM_STEP := 1.2
const PAN_STEP := 0.1
const OVERVIEW_HEIGHT := 4.0

const BACKGROUND := Color(0.08, 0.08, 0.1)
const BLACK_KEY_SHADE := Color(0, 0, 0, 0.18)
const GRID_COLOR := Color(1, 1, 1, 0.04)
const OCTAVE_COLOR := Color(1, 1, 1, 0.12)
const SELECTED_COLOR := Color(0.35, 0.62, 1.0)
const FOCUS_COLOR := Color(1, 1, 1, 0.95)
const MISSING_COLOR := Color(0.9, 0.3, 0.3)
const LABEL_COLOR := Color(1, 1, 1, 0.9)
const UNGROUPED_COLOR := Color(0.55, 0.6, 0.7)
const GROUP_COLORS: Array[Color] = [
	Color(0.95, 0.66, 0.3), Color(0.5, 0.8, 0.45), Color(0.75, 0.5, 0.95),
	Color(0.35, 0.8, 0.85), Color(0.95, 0.5, 0.6), Color(0.85, 0.85, 0.4),
]
const WHITE_KEY := Color(0.86, 0.86, 0.88)
const BLACK_KEY := Color(0.16, 0.16, 0.18)
const KEY_PRESSED := Color(0.35, 0.62, 1.0)
const DROP_COLOR := Color(0.35, 0.62, 1.0, 0.8)
const MARQUEE_FILL := Color(0.35, 0.62, 1.0, 0.15)
const MARQUEE_SUBTRACT := Color(0.95, 0.4, 0.4)

var editor: MultisampleEditor = null

var _drag_mode := DragMode.NONE
var _press_pos := Vector2.ZERO
## Ranges of the dragged zones at the press: {zone_id: {key_lo, key_hi, vel_lo, vel_hi}}.
var _drag_origin := {}
var _drag_edge := Edge.NONE
var _drag_state := {}
## The visible zones outside the drag, at the press: {zone_id: ranges}. Snapping works against these.
var _drag_others := {}
## Shift was down at the press (a drag that started on an edge with Shift never snaps).
var _press_shift := false
var _moved := false
## A plain click on a zone of a multi-selection keeps the selection for a move; without a move,
## the release selects only that zone.
var _collapse_to := 0
var _last_click_pos := Vector2(-INF, -INF)
var _audition_note := -1
var _drop_key := -1
## The key at the left edge of the map (fractional) and how many keys it spans; view-local state.
var view_lo := 0.0
var view_keys := float(KEY_COUNT)
var _panning := false
var _pan_origin_lo := 0.0
var _pan_press_x := 0.0
## Marquee in progress: the selection at the press, the modifier and the box (map coordinates).
var _marquee_base: Array[int] = []
var _marquee_mode := MarqueeMode.REPLACE
var _marquee_rect := Rect2()
var _links: Array = []


func _init() -> void:
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true


func bind(p_editor: MultisampleEditor) -> void:
	unbind()
	editor = p_editor
	var m := editor.model
	for sig in [m.zones_changed, m.groups_changed, editor.selection_changed, editor.visible_groups_changed]:
		_link(sig, queue_redraw)
	_link(m.zone_changed, _redraw_for_zone)
	_link(m.focus_changed, _redraw_for_zone)
	queue_redraw()

## Connect `fn` to `sig` until `unbind()`.
func _link(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_links.append([sig, fn])


func unbind() -> void:
	for link in _links:
		if (link[0] as Signal).is_connected(link[1]):
			(link[0] as Signal).disconnect(link[1])
	_links.clear()
	if _audition_note >= 0:
		_drag_mode = DragMode.NONE
		_stop_audition()
	editor = null


func _redraw_for_zone(_zone_id: int) -> void:
	queue_redraw()


func model() -> SamplerMultisample:
	return editor.model if editor else null


func device() -> DeviceInstance:
	return editor.device if editor else null


# ============================================================================
# GEOMETRY
# ============================================================================

func map_height() -> float:
	return maxf(size.y - KEY_STRIP_HEIGHT, 1.0)


func key_width() -> float:
	return maxf(size.x, 1.0) / view_keys


## X of the left edge of `key` in the current view.
func key_x(key: float) -> float:
	return (key - view_lo) * key_width()


## The first and last keys the view touches.
func visible_keys() -> Vector2i:
	return Vector2i(maxi(floori(view_lo), 0), mini(ceili(view_lo + view_keys), KEY_COUNT - 1))


func vel_height() -> float:
	return map_height() / VEL_STEPS


func key_at(x: float) -> int:
	return clampi(floori(x / key_width() + view_lo), 0, KEY_COUNT - 1)


## Velocity at `y` in the map: 127 at the top, 1 at the bottom.
func vel_at(y: float) -> int:
	return clampi(VEL_STEPS - floori(y / vel_height()), 1, VEL_STEPS)


func key_rect(key: int) -> Rect2:
	return Rect2(key_x(key), map_height(), key_width(), KEY_STRIP_HEIGHT)


func zone_rect(zone: SamplerZone) -> Rect2:
	var kw := key_width()
	var vh := vel_height()
	return Rect2(
		key_x(zone.key_lo), (VEL_STEPS - zone.vel_hi) * vh,
		(zone.key_hi - zone.key_lo + 1) * kw, (zone.vel_hi - zone.vel_lo + 1) * vh)


func in_key_strip(pos: Vector2) -> bool:
	return pos.y >= map_height() and pos.y <= size.y


## Audition velocity for a click at `y` on the key strip: higher up = louder (REQ-043).
func strip_velocity(y: float) -> int:
	var t := clampf((y - map_height()) / KEY_STRIP_HEIGHT, 0.0, 1.0)
	return clampi(roundi(VEL_STEPS * (1.0 - t)), 1, VEL_STEPS)


# --- zoom and pan ----------------------------------------------------------

## Show `keys` keys starting at `lo`, kept within the keyboard.
func set_view(lo: float, keys: float) -> void:
	view_keys = clampf(keys, MIN_VIEW_KEYS, float(KEY_COUNT))
	view_lo = clampf(lo, 0.0, KEY_COUNT - view_keys)
	queue_redraw()


## Zoom by `factor` (> 1 zooms in), keeping the key under map x `at_x` where it is.
func zoom_at(at_x: float, factor: float) -> void:
	var anchor := view_lo + at_x / key_width()
	var keys := clampf(view_keys / factor, MIN_VIEW_KEYS, float(KEY_COUNT))
	set_view(anchor - at_x / maxf(size.x, 1.0) * keys, keys)


## Move the view by `keys` keys (positive = toward higher keys).
func pan_by(keys: float) -> void:
	set_view(view_lo + keys, view_keys)


## Show every key again.
func reset_view() -> void:
	set_view(0.0, float(KEY_COUNT))


## Wheel and middle-button handling. Returns true when `button` was one of them.
func _handle_view_input(button: InputEventMouseButton) -> bool:
	var notches := maxf(button.factor, 1.0)
	match button.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if not button.pressed:
				return true
			var dir := 1.0 if button.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			if button.shift_pressed:
				pan_by(-dir * view_keys * PAN_STEP * notches)
			else:
				zoom_at(button.position.x, pow(ZOOM_STEP, dir * notches))
			return true
		MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
			if button.pressed:
				var dir := 1.0 if button.button_index == MOUSE_BUTTON_WHEEL_RIGHT else -1.0
				pan_by(dir * view_keys * PAN_STEP * notches)
			return true
		MOUSE_BUTTON_MIDDLE:
			_panning = button.pressed
			_pan_press_x = button.position.x
			_pan_origin_lo = view_lo
			return true
	return false


## Labels turn −90° when the rectangle is taller than wide (REQ-044).
static func label_rotated(rect: Rect2) -> bool:
	return rect.size.y > rect.size.x


static func group_color(group_id: int) -> Color:
	if group_id == SamplerZoneGroup.UNGROUPED_ID:
		return UNGROUPED_COLOR
	return GROUP_COLORS[(group_id - 1) % GROUP_COLORS.size()]


# ============================================================================
# HIT TESTING
# ============================================================================

## Visible zones under `pos`, the top one (drawn last) first.
func zones_at(pos: Vector2) -> Array[SamplerZone]:
	var out: Array[SamplerZone] = []
	if editor == null or pos.y >= map_height():
		return out
	var shown := editor.visible_zones()
	for i in range(shown.size() - 1, -1, -1):
		if zone_rect(shown[i]).has_point(pos):
			out.append(shown[i])
	return out


## The zone edge under `pos` as {zone, edge}, or {} when there is none. Selected zones win, then
## the top one.
func edge_at(pos: Vector2) -> Dictionary:
	if editor == null or pos.y >= map_height() + EDGE_GRAB:
		return {}
	var shown := editor.visible_zones()
	var selected: Array[SamplerZone] = []
	var others: Array[SamplerZone] = []
	for i in range(shown.size() - 1, -1, -1):
		(selected if editor.is_selected(shown[i].id) else others).append(shown[i])
	for zone in selected + others:
		var edge := _edge_of(zone_rect(zone), pos)
		if edge != Edge.NONE:
			return {"zone": zone, "edge": edge}
	return {}


## Which edge of `rect` `pos` is on, or NONE. The grab band shrinks to a quarter of a small
## rectangle so it can still be moved by its middle.
static func _edge_of(rect: Rect2, pos: Vector2) -> Edge:
	var gx := minf(EDGE_GRAB, rect.size.x * 0.25)
	var gy := minf(EDGE_GRAB, rect.size.y * 0.25)
	var inside_y := pos.y >= rect.position.y - gy and pos.y <= rect.end.y + gy
	var inside_x := pos.x >= rect.position.x - gx and pos.x <= rect.end.x + gx
	if not inside_x or not inside_y:
		return Edge.NONE
	var candidates := {
		Edge.LEFT: absf(pos.x - rect.position.x) if absf(pos.x - rect.position.x) <= gx else INF,
		Edge.RIGHT: absf(pos.x - rect.end.x) if absf(pos.x - rect.end.x) <= gx else INF,
		Edge.TOP: absf(pos.y - rect.position.y) if absf(pos.y - rect.position.y) <= gy else INF,
		Edge.BOTTOM: absf(pos.y - rect.end.y) if absf(pos.y - rect.end.y) <= gy else INF,
	}
	var best := Edge.NONE
	var best_distance := INF
	for edge in candidates:
		if candidates[edge] < best_distance:
			best = edge
			best_distance = candidates[edge]
	return best


# ============================================================================
# DRAG MATH
# ============================================================================

## The zone ranges a drag produces, as `SamplerMultisample.set_zones_fields` changes.
## `origin` = {zone_id: {key_lo, key_hi, vel_lo, vel_hi}} at the press; `dk` / `dv` = whole keys
## and velocity steps moved. MOVE shifts every zone by the same amount, clamped so all stay in
## range. RESIZE moves `edge` of the one zone, never past its opposite edge.
##
## `snap` ({} = no snapping) is {others: {zone_id: ranges}, key_thr, vel_thr}: the zones to snap to
## and how close, in keys and velocity steps, an edge must come. MOVE then pulls the selection's
## edges onto the nearest neighbouring edge on each axis. RESIZE pulls the dragged edge onto one,
## and a neighbour that touched the dragged edge keeps touching it: its facing edge moves too (so
## `out` can hold neighbours as well).
static func drag_result(origin: Dictionary, mode: DragMode, edge: Edge, dk: int, dv: int, snap: Dictionary = {}) -> Dictionary:
	var out := {}
	if origin.is_empty():
		return out
	if mode == DragMode.MOVE:
		var dk_min := -SamplerZone.KEY_MAX
		var dk_max := SamplerZone.KEY_MAX
		var dv_min := -SamplerZone.VEL_MAX
		var dv_max := SamplerZone.VEL_MAX
		for zone_id in origin:
			var r: Dictionary = origin[zone_id]
			dk_min = maxi(dk_min, SamplerZone.KEY_MIN - int(r["key_lo"]))
			dk_max = mini(dk_max, SamplerZone.KEY_MAX - int(r["key_hi"]))
			dv_min = maxi(dv_min, SamplerZone.VEL_MIN - int(r["vel_lo"]))
			dv_max = mini(dv_max, SamplerZone.VEL_MAX - int(r["vel_hi"]))
		var k := clampi(dk, dk_min, dk_max)
		var v := clampi(dv, dv_min, dv_max)
		if not snap.is_empty():
			var box := _bounds(origin)
			var others: Dictionary = snap["others"]
			var vel_span := Vector2i(box["vel_lo"] + v, box["vel_hi"] + v)
			k = clampi(k + _snap_shift(Vector2i(box["key_lo"] + k, box["key_hi"] + k),
					_neighbour_spans(others, "key", "vel", vel_span), float(snap["key_thr"])), dk_min, dk_max)
			var key_span := Vector2i(box["key_lo"] + k, box["key_hi"] + k)
			v = clampi(v + _snap_shift(Vector2i(box["vel_lo"] + v, box["vel_hi"] + v),
					_neighbour_spans(others, "vel", "key", key_span), float(snap["vel_thr"])), dv_min, dv_max)
		for zone_id in origin:
			var r: Dictionary = origin[zone_id]
			out[zone_id] = {
				"key": [int(r["key_lo"]) + k, int(r["key_hi"]) + k],
				"vel": [int(r["vel_lo"]) + v, int(r["vel_hi"]) + v],
			}
		return out
	if mode == DragMode.RESIZE and not snap.is_empty():
		return _resize_snapped(origin, edge, dk, dv, snap)
	if mode == DragMode.RESIZE:
		for zone_id in origin:
			var r: Dictionary = origin[zone_id]
			var key_lo := int(r["key_lo"])
			var key_hi := int(r["key_hi"])
			var vel_lo := int(r["vel_lo"])
			var vel_hi := int(r["vel_hi"])
			match edge:
				Edge.LEFT:
					key_lo = clampi(key_lo + dk, SamplerZone.KEY_MIN, key_hi)
				Edge.RIGHT:
					key_hi = clampi(key_hi + dk, key_lo, SamplerZone.KEY_MAX)
				Edge.TOP:
					vel_hi = clampi(vel_hi + dv, vel_lo, SamplerZone.VEL_MAX)
				Edge.BOTTOM:
					vel_lo = clampi(vel_lo + dv, SamplerZone.VEL_MIN, vel_hi)
			out[zone_id] = {"key": [key_lo, key_hi], "vel": [vel_lo, vel_hi]}
	return out


## The box around every zone of `origin`: {key_lo, key_hi, vel_lo, vel_hi}.
static func _bounds(origin: Dictionary) -> Dictionary:
	var box := {"key_lo": KEY_COUNT, "key_hi": -1, "vel_lo": VEL_STEPS + 1, "vel_hi": 0}
	for zone_id in origin:
		var r: Dictionary = origin[zone_id]
		box["key_lo"] = mini(box["key_lo"], int(r["key_lo"]))
		box["key_hi"] = maxi(box["key_hi"], int(r["key_hi"]))
		box["vel_lo"] = mini(box["vel_lo"], int(r["vel_lo"]))
		box["vel_hi"] = maxi(box["vel_hi"], int(r["vel_hi"]))
	return box


static func _span(ranges: Dictionary, axis: String) -> Vector2i:
	return Vector2i(int(ranges[axis + "_lo"]), int(ranges[axis + "_hi"]))


## Spans along `axis` of the `others` that overlap `cross_span` along the other axis `cross`: the
## zones an edge could be lined up with.
static func _neighbour_spans(others: Dictionary, axis: String, cross: String, cross_span: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for zone_id in others:
		var cs := _span(others[zone_id], cross)
		if cs.x <= cross_span.y and cs.y >= cross_span.x:
			out.append(_span(others[zone_id], axis))
	return out


## How far (whole steps) to shift `span` so one of its edges lands on an edge of `neighbours`,
## when one is within `thr` steps; 0 otherwise. Edges are at `lo` and `hi + 1`.
static func _snap_shift(span: Vector2i, neighbours: Array[Vector2i], thr: float) -> int:
	var shift := 0
	var best := INF
	for n in neighbours:
		for target in [n.x, n.y + 1]:
			for edge in [span.x, span.y + 1]:
				var gap := absf(float(target - edge))
				if gap <= thr and gap < best:
					best = gap
					shift = target - edge
	return shift


## RESIZE with snapping (see `drag_result`).
static func _resize_snapped(origin: Dictionary, edge: Edge, dk: int, dv: int, snap: Dictionary) -> Dictionary:
	var out := {}
	var zone_id: Variant = origin.keys()[0]
	var r: Dictionary = origin[zone_id]
	var on_key := edge == Edge.LEFT or edge == Edge.RIGHT
	var axis := "key" if on_key else "vel"
	var cross := "vel" if on_key else "key"
	var is_hi := edge == Edge.RIGHT or edge == Edge.TOP
	var own := _span(r, axis)
	var min_v := SamplerZone.KEY_MIN if on_key else SamplerZone.VEL_MIN
	var max_v := SamplerZone.KEY_MAX if on_key else SamplerZone.VEL_MAX
	var thr := float(snap["key_thr"] if on_key else snap["vel_thr"])
	var others: Dictionary = snap["others"]
	var cross_span := _span(r, cross)
	var pushed: Array = []
	var free: Array[Vector2i] = []
	for other_id in others:
		var o: Dictionary = others[other_id]
		var cs := _span(o, cross)
		if cs.x > cross_span.y or cs.y < cross_span.x:
			continue
		var os := _span(o, axis)
		if (is_hi and os.x == own.y + 1) or (not is_hi and os.y == own.x - 1):
			pushed.append(other_id)
		else:
			free.append(os)
	var moved := (dk if on_key else dv) + (own.y if is_hi else own.x)
	# The edge coordinate is `hi + 1` for a high edge, `lo` for a low one.
	var coord := moved + (1 if is_hi else 0)
	coord += _snap_shift(Vector2i(coord, coord - 1), free, thr)
	moved = coord - (1 if is_hi else 0)
	if is_hi:
		moved = clampi(moved, own.x, max_v)
		for other_id in pushed:
			moved = mini(moved, maxi(own.x, _span(others[other_id], axis).y - 1))
	else:
		moved = clampi(moved, min_v, own.y)
		for other_id in pushed:
			moved = maxi(moved, mini(own.y, _span(others[other_id], axis).x + 1))
	var own_new := Vector2i(own.x, moved) if is_hi else Vector2i(moved, own.y)
	out[zone_id] = _with_span(r, axis, own_new)
	for other_id in pushed:
		var os := _span(others[other_id], axis)
		out[other_id] = _with_span(others[other_id], axis, Vector2i(moved + 1, os.y) if is_hi else Vector2i(os.x, moved - 1))
	return out


## `{key, vel}` ranges from `ranges` with `axis` replaced by `span`.
static func _with_span(ranges: Dictionary, axis: String, span: Vector2i) -> Dictionary:
	var out := {"key": [int(ranges["key_lo"]), int(ranges["key_hi"])], "vel": [int(ranges["vel_lo"]), int(ranges["vel_hi"])]}
	out[axis] = [span.x, span.y]
	return out


static func _ranges(zone: SamplerZone) -> Dictionary:
	return {"key_lo": zone.key_lo, "key_hi": zone.key_hi, "vel_lo": zone.vel_lo, "vel_hi": zone.vel_hi}


# ============================================================================
# INPUT
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if editor == null:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if _handle_view_input(button):
			accept_event()
		elif button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				press(button.position, button.is_command_or_control_pressed(), button.shift_pressed)
			else:
				release()
			accept_event()
		elif button.button_index == MOUSE_BUTTON_RIGHT and button.pressed:
			open_context_menu(button.position)
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _panning:
			set_view(_pan_origin_lo - (motion.position.x - _pan_press_x) / key_width(), view_keys)
			accept_event()
		elif _drag_mode != DragMode.NONE:
			drag_to(motion.position, motion.shift_pressed)
			accept_event()
		else:
			_update_cursor(motion.position)
	elif editor.handle_shortcut(event):
		accept_event()


## Left press at `pos` (also what the tests call).
func press(pos: Vector2, ctrl := false, shift := false) -> void:
	if editor == null or model() == null:
		return
	grab_focus()
	if in_key_strip(pos):
		_start_audition(key_at(pos.x), strip_velocity(pos.y))
		return
	var edge := edge_at(pos) if not ctrl else {}
	_press_shift = shift
	if not edge.is_empty():
		var zone: SamplerZone = edge["zone"]
		if editor.is_selected(zone.id):
			model().set_focus(zone.id)
		else:
			editor.click_zone(zone.id)
		_begin_drag(DragMode.RESIZE, pos, [zone.id], edge["edge"])
		return
	var zone := _select_at(pos, ctrl, shift)
	if zone != null and not ctrl and not shift:
		_begin_drag(DragMode.MOVE, pos, editor.selected_ids, Edge.NONE)
	elif zone == null:
		_begin_marquee(pos, ctrl, shift)


## Selection for a body click (REQ-045, REQ-046). Returns the clicked zone, or null.
func _select_at(pos: Vector2, ctrl: bool, shift: bool) -> SamplerZone:
	var under := zones_at(pos)
	var same_spot := pos.distance_to(_last_click_pos) <= CLICK_SLOP
	_last_click_pos = pos
	_collapse_to = 0
	if under.is_empty():
		if not ctrl and not shift:
			editor.clear_selection()
		return null
	var zone := under[0]
	var cycling := not ctrl and not shift and same_spot and under.size() > 1
	if cycling:
		var i := under.find(model().focused_zone())
		zone = under[(i + 1) % under.size()]
	if ctrl:
		editor.click_zone(zone.id, MultisampleEditor.SelectMode.TOGGLE)
	elif shift:
		editor.click_zone(zone.id, MultisampleEditor.SelectMode.RANGE)
	elif not cycling and editor.is_selected(zone.id) and editor.selected_ids.size() > 1:
		model().set_focus(zone.id)
		_collapse_to = zone.id
	else:
		editor.click_zone(zone.id)
	return zone


func _begin_drag(mode: DragMode, pos: Vector2, ids: Array, edge: Edge) -> void:
	_drag_mode = mode
	_press_pos = pos
	_drag_edge = edge
	_moved = false
	_drag_origin = {}
	for zone_id in ids:
		var zone := model().get_zone(int(zone_id))
		if zone:
			_drag_origin[zone.id] = _ranges(zone)
	_drag_others = {}
	for zone in editor.visible_zones():
		if not _drag_origin.has(zone.id):
			_drag_others[zone.id] = _ranges(zone)
	_drag_state = SamplerActions.begin_edit(device())


## The `drag_result` snap arguments: {} when snapping is off or bypassed with Shift.
func snap_args(bypass: bool) -> Dictionary:
	if editor == null or not editor.snap_enabled or bypass or _press_shift:
		return {}
	return {
		"others": _drag_others,
		"key_thr": SNAP_PX / key_width(),
		"vel_thr": SNAP_PX / vel_height(),
	}


## Pointer moved to `pos` during a press (also what the tests call). `bypass_snap`: Shift is down.
func drag_to(pos: Vector2, bypass_snap := false) -> void:
	if _drag_mode == DragMode.MARQUEE:
		_update_marquee(pos)
		return
	if _drag_mode != DragMode.MOVE and _drag_mode != DragMode.RESIZE:
		return
	if not _moved and pos.distance_to(_press_pos) < CLICK_SLOP:
		return
	_moved = true
	var dk := roundi((pos.x - _press_pos.x) / key_width())
	var dv := roundi((_press_pos.y - pos.y) / vel_height())
	model().set_zones_fields(drag_result(_drag_origin, _drag_mode, _drag_edge, dk, dv, snap_args(bypass_snap)))


## Left release (also what the tests call).
func release() -> void:
	var mode := _drag_mode
	_drag_mode = DragMode.NONE
	if mode == DragMode.AUDITION:
		_stop_audition()
		return
	if mode == DragMode.NONE:
		return
	if mode == DragMode.MARQUEE:
		_marquee_rect = Rect2()
		_marquee_base = []
		queue_redraw()
		return
	if _moved:
		var label := "Move Samples" if mode == DragMode.MOVE else "Resize Sample"
		SamplerActions.end_edit(device(), label, _drag_state)
		_last_click_pos = Vector2(-INF, -INF)
	elif _collapse_to != 0:
		editor.click_zone(_collapse_to)
	_collapse_to = 0
	_drag_origin = {}
	_drag_others = {}
	_drag_state = {}


# ============================================================================
# MARQUEE
# ============================================================================

## The selection a marquee gives: the ids of `zones` whose rectangles touch `box`, combined with
## `base` per `mode`. Static for the tests; `rects` maps zone id to its rectangle.
static func marquee_result(base: Array, rects: Dictionary, box: Rect2, mode: MarqueeMode) -> Array:
	var hit: Array = []
	for zone_id in rects:
		if (rects[zone_id] as Rect2).intersects(box, true):
			hit.append(zone_id)
	var out: Array = [] if mode == MarqueeMode.REPLACE else base.duplicate()
	for zone_id in hit:
		if mode == MarqueeMode.SUBTRACT:
			out.erase(zone_id)
		elif not out.has(zone_id):
			out.append(zone_id)
	return out


func _begin_marquee(pos: Vector2, ctrl: bool, shift: bool) -> void:
	_drag_mode = DragMode.MARQUEE
	_press_pos = pos
	_moved = false
	_marquee_mode = MarqueeMode.ADD if ctrl else (MarqueeMode.SUBTRACT if shift else MarqueeMode.REPLACE)
	_marquee_base = editor.selected_ids.duplicate()
	_marquee_rect = Rect2(pos, Vector2.ZERO)


func _update_marquee(pos: Vector2) -> void:
	if not _moved and pos.distance_to(_press_pos) < CLICK_SLOP:
		return
	_moved = true
	var clamped := Vector2(clampf(pos.x, 0.0, size.x), clampf(pos.y, 0.0, map_height()))
	_marquee_rect = Rect2(_press_pos, Vector2.ZERO).expand(clamped)
	var rects := {}
	for zone in editor.visible_zones():
		rects[zone.id] = zone_rect(zone)
	editor.set_selection(marquee_result(_marquee_base, rects, _marquee_rect, _marquee_mode))
	queue_redraw()


func _update_cursor(pos: Vector2) -> void:
	var shape := Control.CURSOR_ARROW
	if in_key_strip(pos):
		shape = Control.CURSOR_POINTING_HAND
	else:
		var edge := edge_at(pos)
		if not edge.is_empty():
			shape = Control.CURSOR_HSIZE if edge["edge"] in [Edge.LEFT, Edge.RIGHT] else Control.CURSOR_VSIZE
	mouse_default_cursor_shape = shape


## Right-click (REQ-046): the zones under the pointer, then the batch operations. A click on an
## unselected zone with nothing selected selects it first.
func open_context_menu(pos: Vector2) -> void:
	var under := zones_at(pos)
	if editor.selected_ids.is_empty() and not under.is_empty():
		editor.click_zone(under[0].id)
	editor.open_batch_menu(get_screen_position() + pos, under)


# ============================================================================
# AUDITION (key strip)
# ============================================================================

func _start_audition(note: int, velocity: int) -> void:
	_stop_audition()
	if device() == null:
		return
	_audition_note = note
	_drag_mode = DragMode.AUDITION
	device().audition(note, velocity, true)
	queue_redraw()


func _stop_audition() -> void:
	if _audition_note >= 0 and device() != null:
		device().audition(_audition_note, 0, false)
	_audition_note = -1
	queue_redraw()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_EXIT_TREE, NOTIFICATION_VISIBILITY_CHANGED:
			if _audition_note >= 0:
				_drag_mode = DragMode.NONE
				_stop_audition()
		NOTIFICATION_DRAG_END:
			if _drop_key >= 0:
				_drop_key = -1
				queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			if _drop_key >= 0 and get_viewport().gui_is_dragging():
				_drop_key = -1
				queue_redraw()


# ============================================================================
# DROPS (REQ-015)
# ============================================================================

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if editor == null or SampleDisplay.audio_assets_in(data).is_empty():
		return false
	var key := key_at(at_position.x)
	if key != _drop_key:
		_drop_key = key
		queue_redraw()
	return true


func _drop_data(at_position: Vector2, data: Variant) -> void:
	drop_assets(SampleDisplay.audio_assets_in(data), key_at(at_position.x))


## Add the files of `assets` as zones starting at `key`.
func drop_assets(assets: Array, key: int) -> void:
	_drop_key = -1
	queue_redraw()
	if device() != null and not assets.is_empty():
		SamplerActions.drop_files(device(), assets.map(func(a: Asset): return a.path), key)


# ============================================================================
# DRAWING
# ============================================================================

func _draw() -> void:
	var w := size.x
	var mh := map_height()
	draw_rect(Rect2(0, 0, w, mh), BACKGROUND)
	_draw_grid(w, mh)
	if editor != null and model() != null:
		var focused := model().focused_zone_id
		for zone in editor.visible_zones():
			_draw_zone(zone, zone.id == focused)
	if _drop_key >= 0:
		var x := key_x(_drop_key)
		draw_rect(Rect2(x, 0, key_width(), mh), Color(DROP_COLOR, 0.25))
		draw_line(Vector2(x, 0), Vector2(x, mh), DROP_COLOR, 2.0)
	_draw_marquee()
	_draw_overview(w)
	_draw_key_strip(w, mh)


func _draw_marquee() -> void:
	if _drag_mode != DragMode.MARQUEE or not _moved:
		return
	var color := MARQUEE_SUBTRACT if _marquee_mode == MarqueeMode.SUBTRACT else SELECTED_COLOR
	draw_rect(_marquee_rect, Color(color, 0.15))
	draw_rect(_marquee_rect, color, false, 1.0)


## A thin bar along the top of the map showing which part of the keyboard is in view.
func _draw_overview(w: float) -> void:
	if view_keys >= KEY_COUNT:
		return
	draw_rect(Rect2(0, 0, w, OVERVIEW_HEIGHT), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(view_lo / KEY_COUNT * w, 0, view_keys / KEY_COUNT * w, OVERVIEW_HEIGHT), Color(1, 1, 1, 0.35))


func _draw_grid(w: float, mh: float) -> void:
	var kw := key_width()
	var span := visible_keys()
	for key in range(span.x, span.y + 1):
		if Midi.is_black_key(key):
			draw_rect(Rect2(key_x(key), 0, kw, mh), BLACK_KEY_SHADE)
		elif key % 12 == 0:
			draw_line(Vector2(key_x(key), 0), Vector2(key_x(key), mh), OCTAVE_COLOR)
	for vel in [32, 64, 96]:
		var y: float = (VEL_STEPS - vel + 0.5) * vel_height()
		draw_line(Vector2(0, y), Vector2(w, y), GRID_COLOR)


func _draw_zone(zone: SamplerZone, focused: bool) -> void:
	var rect := zone_rect(zone)
	var base := group_color(zone.group_id)
	var selected := editor.is_selected(zone.id)
	var fill := Color(SELECTED_COLOR, 0.5) if selected else Color(base, 0.3)
	if zone.is_missing():
		fill = Color(MISSING_COLOR, 0.25)
	draw_rect(rect, fill)
	if zone.is_missing():
		_draw_hatch(rect, Color(MISSING_COLOR, 0.6))
	var border := SELECTED_COLOR if selected else base
	if zone.is_missing():
		border = MISSING_COLOR
	draw_rect(rect, border, false, 1.0)
	if focused:
		draw_rect(rect.grow(-1.0), FOCUS_COLOR, false, 2.0)
	_draw_label(zone.name if not zone.is_missing() else "%s (missing)" % zone.name, rect)


## Diagonal lines across `rect`, clipped to it.
func _draw_hatch(rect: Rect2, color: Color) -> void:
	var c := rect.position.y - rect.end.x
	while c < rect.end.y - rect.position.x:
		# Points on y = x + c inside the rect.
		var x0 := maxf(rect.position.x, rect.position.y - c)
		var x1 := minf(rect.end.x, rect.end.y - c)
		if x1 > x0:
			draw_line(Vector2(x0, x0 + c), Vector2(x1, x1 + c), color, 1.0)
		c += HATCH_SPACING


## The zone's name, clipped to its rectangle, rotated −90° when it is taller than wide.
func _draw_label(text: String, rect: Rect2) -> void:
	var font := get_theme_default_font()
	var rotated := label_rotated(rect)
	var along := rect.size.y if rotated else rect.size.x
	var across := rect.size.x if rotated else rect.size.y
	if across < LABEL_FONT_SIZE * 0.9 or along < 10.0:
		return
	var fitted := SampleDisplay.fit_text(text, font, LABEL_FONT_SIZE, along - 6.0)
	if fitted.is_empty():
		return
	var ascent := font.get_ascent(LABEL_FONT_SIZE)
	if rotated:
		# Reads bottom to top, centered across the rectangle.
		var origin := Vector2(rect.position.x + (rect.size.x + ascent * 0.8) * 0.5, rect.end.y - 3.0)
		draw_set_transform(origin, -PI * 0.5)
		draw_string(font, Vector2.ZERO, fitted, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, LABEL_COLOR)
		draw_set_transform(Vector2.ZERO, 0.0)
	else:
		draw_string(font, rect.position + Vector2(3.0, ascent + 2.0), fitted, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, LABEL_COLOR)


func _draw_key_strip(w: float, mh: float) -> void:
	var kw := key_width()
	draw_rect(Rect2(0, mh, w, KEY_STRIP_HEIGHT), WHITE_KEY)
	var font := get_theme_default_font()
	var span := visible_keys()
	for key in range(span.x, span.y + 1):
		var rect := key_rect(key)
		if key == _audition_note:
			draw_rect(rect, KEY_PRESSED)
		elif Midi.is_black_key(key):
			draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.62)), BLACK_KEY)
		if key % 12 == 0:
			draw_line(Vector2(rect.position.x, mh), Vector2(rect.position.x, mh + KEY_STRIP_HEIGHT), Color(0, 0, 0, 0.35))
			if kw * 12.0 >= 28.0:
				draw_string(font, Vector2(rect.position.x + 2.0, size.y - 3.0), Midi.midi_to_note_name(key),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0, 0, 0, 0.6))
	draw_line(Vector2(0, mh), Vector2(w, mh), Color(0, 0, 0, 0.5))
