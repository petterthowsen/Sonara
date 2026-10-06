## The multisample editor's zone map (spec 023, REQ-043–REQ-046, REQ-015, REQ-048): keys left to
## right, velocity bottom to top, each visible zone a rectangle spanning its ranges, and a
## horizontal piano along the bottom that auditions notes (higher up on a key = louder).
##
## - Click selects and focuses the zone under the pointer (Ctrl toggles, Shift selects a range in
##   list order). Clicking the same spot again cycles through the zones stacked there.
## - Dragging a zone body moves the selection by whole keys and velocity steps; dragging an edge
##   resizes that zone. Ranges stay within 0–127 / 1–127 and never empty. One undo step per drag.
## - Right-click lists the zones under the pointer, then the batch operations.
## - Audio files dropped on the map are added starting at the key under the pointer.
##
## Zones are drawn in list order, so later zones sit on top; `zones_at` returns the top one first.
## `zones_at`, `edge_at`, `drag_result` and the geometry helpers are public for the tests.
class_name ZoneMap extends Control

enum Edge { NONE, LEFT, RIGHT, TOP, BOTTOM }
enum DragMode { NONE, MOVE, RESIZE, AUDITION }

const KEY_COUNT := 128
const VEL_STEPS := 127
const KEY_STRIP_HEIGHT := 30.0
## How far from an edge (px) it can be grabbed; less on small zones so their body stays movable.
const EDGE_GRAB := 4.0
## A press that moves less than this (px) is a click.
const CLICK_SLOP := 3.0
const LABEL_FONT_SIZE := 10
const HATCH_SPACING := 6.0

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

var editor: MultisampleEditor = null

var _drag_mode := DragMode.NONE
var _press_pos := Vector2.ZERO
## Ranges of the dragged zones at the press: {zone_id: {key_lo, key_hi, vel_lo, vel_hi}}.
var _drag_origin := {}
var _drag_edge := Edge.NONE
var _drag_state := {}
var _moved := false
## A plain click on a zone of a multi-selection keeps the selection for a move; without a move,
## the release selects only that zone.
var _collapse_to := 0
var _last_click_pos := Vector2(-INF, -INF)
var _audition_note := -1
var _drop_key := -1
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
	return maxf(size.x, 1.0) / KEY_COUNT


func vel_height() -> float:
	return map_height() / VEL_STEPS


func key_at(x: float) -> int:
	return clampi(floori(x / key_width()), 0, KEY_COUNT - 1)


## Velocity at `y` in the map: 127 at the top, 1 at the bottom.
func vel_at(y: float) -> int:
	return clampi(VEL_STEPS - floori(y / vel_height()), 1, VEL_STEPS)


func key_rect(key: int) -> Rect2:
	return Rect2(key * key_width(), map_height(), key_width(), KEY_STRIP_HEIGHT)


func zone_rect(zone: SamplerZone) -> Rect2:
	var kw := key_width()
	var vh := vel_height()
	return Rect2(
		zone.key_lo * kw, (VEL_STEPS - zone.vel_hi) * vh,
		(zone.key_hi - zone.key_lo + 1) * kw, (zone.vel_hi - zone.vel_lo + 1) * vh)


func in_key_strip(pos: Vector2) -> bool:
	return pos.y >= map_height() and pos.y <= size.y


## Audition velocity for a click at `y` on the key strip: higher up = louder (REQ-043).
func strip_velocity(y: float) -> int:
	var t := clampf((y - map_height()) / KEY_STRIP_HEIGHT, 0.0, 1.0)
	return clampi(roundi(VEL_STEPS * (1.0 - t)), 1, VEL_STEPS)


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
static func drag_result(origin: Dictionary, mode: DragMode, edge: Edge, dk: int, dv: int) -> Dictionary:
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
		for zone_id in origin:
			var r: Dictionary = origin[zone_id]
			out[zone_id] = {
				"key": [int(r["key_lo"]) + k, int(r["key_hi"]) + k],
				"vel": [int(r["vel_lo"]) + v, int(r["vel_hi"]) + v],
			}
		return out
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
		if button.button_index == MOUSE_BUTTON_LEFT:
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
		if _drag_mode != DragMode.NONE:
			drag_to(motion.position)
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
	var edge := edge_at(pos) if not ctrl and not shift else {}
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
	_drag_state = SamplerActions.begin_edit(device())


## Pointer moved to `pos` during a press (also what the tests call).
func drag_to(pos: Vector2) -> void:
	if _drag_mode != DragMode.MOVE and _drag_mode != DragMode.RESIZE:
		return
	if not _moved and pos.distance_to(_press_pos) < CLICK_SLOP:
		return
	_moved = true
	var dk := roundi((pos.x - _press_pos.x) / key_width())
	var dv := roundi((_press_pos.y - pos.y) / vel_height())
	model().set_zones_fields(drag_result(_drag_origin, _drag_mode, _drag_edge, dk, dv))


## Left release (also what the tests call).
func release() -> void:
	var mode := _drag_mode
	_drag_mode = DragMode.NONE
	if mode == DragMode.AUDITION:
		_stop_audition()
		return
	if mode == DragMode.NONE:
		return
	if _moved:
		var label := "Move Samples" if mode == DragMode.MOVE else "Resize Sample"
		SamplerActions.end_edit(device(), label, _drag_state)
		_last_click_pos = Vector2(-INF, -INF)
	elif _collapse_to != 0:
		editor.click_zone(_collapse_to)
	_collapse_to = 0
	_drag_origin = {}
	_drag_state = {}


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
		var x := _drop_key * key_width()
		draw_rect(Rect2(x, 0, key_width(), mh), Color(DROP_COLOR, 0.25))
		draw_line(Vector2(x, 0), Vector2(x, mh), DROP_COLOR, 2.0)
	_draw_key_strip(w, mh)


func _draw_grid(w: float, mh: float) -> void:
	var kw := key_width()
	for key in KEY_COUNT:
		if Midi.is_black_key(key):
			draw_rect(Rect2(key * kw, 0, kw, mh), BLACK_KEY_SHADE)
		elif key % 12 == 0:
			draw_line(Vector2(key * kw, 0), Vector2(key * kw, mh), OCTAVE_COLOR)
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
	for key in KEY_COUNT:
		var rect := key_rect(key)
		if key == _audition_note:
			draw_rect(rect, KEY_PRESSED)
		elif Midi.is_black_key(key):
			draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.62)), BLACK_KEY)
		if key % 12 == 0:
			draw_line(Vector2(key * kw, mh), Vector2(key * kw, mh + KEY_STRIP_HEIGHT), Color(0, 0, 0, 0.35))
			if kw * 12.0 >= 28.0:
				draw_string(font, Vector2(key * kw + 2.0, size.y - 3.0), Midi.midi_to_note_name(key),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0, 0, 0, 0.6))
	draw_line(Vector2(0, mh), Vector2(w, mh), Color(0, 0, 0, 0.5))
