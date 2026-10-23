# StageCanvas.gd
# Top-down drawing of the virtual stage (spec 051, REQ-021..022; spec 052): the room, the listener
# and one rectangle per stage source (a dot at size 0), in its channel's colour and labelled with
# its name. A Block fills the rectangle; a Section outlines it and draws a person icon per player.
# Hit-testing and drags live here; the numbers come from StageEdit and are applied to the
# channels through set_stage_state, so the models send OSC. A finished drag is recorded as one
# undo step.
#
# Room coordinates are meters from the front-left floor corner, X to the right and Y toward the
# back wall. The front wall is drawn at the top, so the listener faces up.
class_name StageCanvas extends Control

## The user changed the selection (click, ctrl-click, click on empty space).
signal selection_changed(channels: Array[Channel])
## The set of source items changed (a channel entered or left Stage, or was added or removed).
signal items_changed
## refresh() ran: a source changed (name, colour, placement) or the set of sources did.
signal refreshed

const MARGIN := 28.0
const HIT_PX := 9.0
const BAR_WIDTH := 6.0
const DOT_RADIUS := 7.0
## A selected dot shows its resize handle this far from the centre, along its rotation.
const DOT_HANDLE_PX := 22.0
const HANDLE_RADIUS := 5.0
const GRID_MIN_PX := 36.0
## UI state (not a user setting): drags snap to the grid.
const SNAP_CONFIG_KEY := "stage_view/snap"
## Lower bound on the person icon, and the share of its grid cell it fills.
const ICON_MIN_PX := 3.0
const ICON_FILL := 0.7

enum Drag { NONE, MOVE, END, EDGE, LISTENER }

var project: Project = null
## Snap placement drags (1 m, 15 degrees; Shift = 0.1 m, 1 degree). On by default, remembered in the UI config.
var snap_enabled := true
var selection: Array[Channel] = []

var _items: Array[Channel] = []
## Show sources of hidden channels too. Not persisted: it resets with the view.
var show_hidden := false
var _watched: Dictionary = {}
var _hover: Channel = null
var _scale := 1.0
var _origin := Vector2.ZERO
## Playhead tick for automated positions, or -1 while stopped.
var _tick := -1

var _drag := Drag.NONE
var _drag_start := Vector2.ZERO
var _drag_channels: Array[Channel] = []
var _drag_old: Array[Dictionary] = []
var _drag_which := 0
## Index in `_drag_channels` of the source under the pointer: it is the one that snaps.
var _drag_anchor := -1
var _listener_old: Dictionary = {}


func _init() -> void:
	custom_minimum_size = Vector2(320, 240)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	focus_mode = Control.FOCUS_NONE
	snap_enabled = bool(Sonara.get_config(SNAP_CONFIG_KEY, true))


## Show or hide the sources of hidden channels.
func set_show_hidden(on: bool) -> void:
	show_hidden = on
	refresh()


## Turn snapping on or off and remember it in the UI config.
func set_snap_enabled(on: bool) -> void:
	snap_enabled = on
	Sonara.set_config(SNAP_CONFIG_KEY, on)
	Sonara.save_config()


func set_project(p: Project) -> void:
	if project:
		_disconnect_project()
	project = p
	if project:
		project.channel_added.connect(_on_project_channel)
		project.channel_removed.connect(_on_project_channel)
		project.stage.changed.connect(_on_stage_changed)
	refresh()


func _disconnect_project() -> void:
	if project.channel_added.is_connected(_on_project_channel):
		project.channel_added.disconnect(_on_project_channel)
	if project.channel_removed.is_connected(_on_project_channel):
		project.channel_removed.disconnect(_on_project_channel)
	if project.stage.changed.is_connected(_on_stage_changed):
		project.stage.changed.disconnect(_on_stage_changed)


## Rebuild the source items from the project and redraw.
func refresh() -> void:
	var before := _items
	_items = [] as Array[Channel]
	if project:
		for ch in project.stage_sources():
			if show_hidden or not ch.hidden:
				_items.append(ch)
	# Every channel is watched, not only the sources: a channel entering Stage must appear.
	if project:
		for ch in project.channels:
			_watch(ch)
	selection = _only_items(selection)
	if _hover and not _items.has(_hover):
		_hover = null
	queue_redraw()
	if before != _items:
		items_changed.emit()
	refreshed.emit()


## The channels drawn as sources, in project order.
func get_items() -> Array[Channel]:
	return _items.duplicate()


func get_selection() -> Array[Channel]:
	return selection.duplicate()


## Replace the selection without emitting (it came from the mixer or the arranger).
func set_selection_silent(channels: Array[Channel]) -> void:
	selection = _only_items(channels)
	queue_redraw()


func _only_items(channels: Array[Channel]) -> Array[Channel]:
	var out: Array[Channel] = []
	for ch in channels:
		if _items.has(ch) and not out.has(ch):
			out.append(ch)
	return out


func _watch(ch: Channel) -> void:
	if _watched.has(ch):
		return
	_watched[ch] = true
	ch.stage_changed.connect(_on_channel_changed)
	ch.pan_mode_changed.connect(_on_channel_changed)
	ch.name_changed.connect(_on_channel_changed)
	ch.color_changed.connect(_on_channel_changed)
	ch.hidden_changed.connect(_on_channel_changed)


func _on_channel_changed(_value = null) -> void:
	refresh()


func _on_project_channel(_ch: Channel) -> void:
	refresh()


func _on_stage_changed() -> void:
	queue_redraw()


## The playhead moved while playing (`tick` < 0 when stopped): redraw if a position is automated.
func set_playhead(tick: int) -> void:
	var was := _tick
	_tick = tick
	if (tick >= 0 or was >= 0) and _any_automation():
		queue_redraw()


func _any_automation() -> bool:
	for ch in _items:
		if not _stage_lanes(ch).is_empty():
			return true
	return false


# ============================================================================
# Automated positions (REQ-025)
# ============================================================================

## The active stage-parameter lanes (x, y, z, size, rotation) on `ch`'s track.
static func _stage_lanes_of(proj: Project, ch: Channel) -> Array[AutomationLane]:
	var out: Array[AutomationLane] = []
	var track := proj.get_channel_paired_track(ch) if proj else null
	if track == null:
		return out
	for lane in track.automation_lanes:
		if lane.target != null and lane.target.kind == AutomationTarget.Kind.STAGE_PARAM \
				and lane.resolved and not lane.is_inert():
			out.append(lane)
	return out


func _stage_lanes(ch: Channel) -> Array[AutomationLane]:
	return _stage_lanes_of(project, ch)


## `ch`'s stage state with every automated parameter replaced by its lane's value at `tick`.
## Without lanes (or for a negative tick) it is the channel's own state.
static func automated_state(proj: Project, ch: Channel, tick: int) -> Dictionary:
	var state := ch.get_stage_state()
	if tick < 0 or proj == null:
		return state
	for lane in _stage_lanes_of(proj, ch):
		var value := lane.get_value_at_tick(tick)
		if is_nan(value):
			continue
		var param := lane.target.stage_param
		state[param] = AutomationTarget.stage_denormalize(param, value, proj.stage)
	return state


## The state to draw and hit-test: automated while playing, the channel's own while dragging.
func displayed_state(ch: Channel) -> Dictionary:
	if _drag != Drag.NONE or _tick < 0:
		return ch.get_stage_state()
	return automated_state(project, ch, _tick)


# ============================================================================
# Layout
# ============================================================================

func _update_layout() -> void:
	if project == null:
		return
	var room := project.stage
	var avail := size - Vector2.ONE * MARGIN * 2.0
	_scale = maxf(minf(avail.x / room.width, avail.y / room.depth), 0.01)
	_origin = (size - Vector2(room.width, room.depth) * _scale) * 0.5


func to_screen(p: Vector2) -> Vector2:
	return _origin + p * _scale


func to_room(s: Vector2) -> Vector2:
	return (s - _origin) / _scale


## Screen positions of a source's two end handles (end A, end B). A dot has none, so its handle
## sits a fixed distance from the centre.
func _handles(state: Dictionary) -> Array[Vector2]:
	var center := to_screen(Vector2(float(state.x), float(state.y)))
	if float(state.size) < StageEdit.MIN_SIZE:
		var d := StageEdit.direction(float(state.rotation)) * DOT_HANDLE_PX
		return [center - d, center + d]
	var e := StageEdit.ends(state)
	return [to_screen(e[0]), to_screen(e[1])]


## Screen positions of the depth handles at the middle of the front and back edges.
func _edge_handles(state: Dictionary) -> Array[Vector2]:
	var m := StageEdit.edge_midpoints(state)
	return [to_screen(m[0]), to_screen(m[1])]


# ============================================================================
# Hit-testing
# ============================================================================

## What is under `pos` (control coordinates): `{kind: "end"|"edge"|"body"|"listener"|"none",
## channel, which}`. Handles (ends, edges) are only grabbed on a selected or hovered source. The
## body is the whole rectangle.
func hit_test(pos: Vector2) -> Dictionary:
	if project == null:
		return {"kind": "none"}
	_update_layout()
	# Topmost (last drawn) first.
	for i in range(_items.size() - 1, -1, -1):
		var ch := _items[i]
		var state := displayed_state(ch)
		if selection.has(ch) or ch == _hover:
			var handles := _handles(state)
			for which in 2:
				if pos.distance_to(handles[which]) <= HIT_PX:
					if which == 0 and float(state.size) < StageEdit.MIN_SIZE:
						continue  # a dot has one handle
					return {"kind": "end", "channel": ch, "which": which}
			if float(state.size) >= StageEdit.MIN_SIZE:
				var edges := _edge_handles(state)
				for which in 2:
					if pos.distance_to(edges[which]) <= HIT_PX:
						return {"kind": "edge", "channel": ch, "which": which}
		var center := to_screen(Vector2(float(state.x), float(state.y)))
		var dist := pos.distance_to(center)
		if float(state.size) < StageEdit.MIN_SIZE:
			dist = maxf(dist - DOT_RADIUS, 0.0)
		elif StageEdit.contains(state, to_room(pos), HIT_PX / _scale):
			dist = 0.0
		else:
			dist = INF
		if dist <= HIT_PX:
			return {"kind": "body", "channel": ch}
	var listener := to_screen(Vector2(project.stage.listener.x, project.stage.listener.y))
	if pos.distance_to(listener) <= HIT_PX + 4.0:
		return {"kind": "listener"}
	return {"kind": "none"}


# ============================================================================
# Input
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if project == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press(event.position, event.ctrl_pressed or event.meta_pressed)
		else:
			_release()
		accept_event()
	elif event is InputEventMouseMotion:
		if _drag != Drag.NONE:
			_drag_to(event.position, event.shift_pressed)
			accept_event()
		else:
			var hit := hit_test(event.position)
			var over: Channel = hit.get("channel")
			if over != _hover:
				_hover = over
				queue_redraw()


func _press(pos: Vector2, additive: bool) -> void:
	var hit := hit_test(pos)
	match hit.kind:
		"end":
			var ch: Channel = hit.channel
			_select(ch, false)
			_begin(Drag.END, pos, [ch] as Array[Channel])
			_drag_which = hit.which
		"edge":
			var ch: Channel = hit.channel
			_select(ch, false)
			_begin(Drag.EDGE, pos, [ch] as Array[Channel])
			_drag_which = hit.which
		"body":
			var ch: Channel = hit.channel
			if additive:
				_select(ch, true)
				return
			if not selection.has(ch):
				_select(ch, false)
			_begin(Drag.MOVE, pos, selection.duplicate())
			_drag_anchor = _drag_channels.find(ch)
		"listener":
			_begin(Drag.LISTENER, pos, [] as Array[Channel])
			_listener_old = project.stage.get_state()
		_:
			if not additive and not selection.is_empty():
				selection = [] as Array[Channel]
				queue_redraw()
				selection_changed.emit(selection.duplicate())


func _select(ch: Channel, additive: bool) -> void:
	var before := selection.duplicate()
	if additive:
		if selection.has(ch):
			selection.erase(ch)
		else:
			selection.append(ch)
	else:
		selection = [ch] as Array[Channel]
	queue_redraw()
	if before != selection:
		selection_changed.emit(selection.duplicate())


func _begin(kind: Drag, pos: Vector2, channels: Array[Channel]) -> void:
	_drag = kind
	_drag_anchor = -1
	_drag_start = to_room(pos)
	_drag_channels = channels
	_drag_old = []
	for ch in channels:
		_drag_old.append(ch.get_stage_state())


## Continue the drag at `pos`. `fine` (Shift) uses the fine snap steps; with snapping off the drag is free.
func _drag_to(pos: Vector2, fine: bool) -> void:
	var room := project.stage
	var point := to_room(pos)
	var step := StageEdit.step_m(snap_enabled, fine)
	match _drag:
		Drag.MOVE:
			var moved := StageEdit.move_by(room, _drag_old, point - _drag_start, _drag_anchor, step)
			for i in _drag_channels.size():
				_drag_channels[i].set_stage_state(moved[i])
		Drag.END:
			var changed := StageEdit.drag_end(room, _drag_old[0], _drag_which, point, StageEdit.step_deg(snap_enabled, fine), step)
			_drag_channels[0].set_stage_state(changed)
		Drag.EDGE:
			_drag_channels[0].set_stage_state(StageEdit.drag_edge(room, _drag_old[0], point, step))
		Drag.LISTENER:
			var p := room.clamp_point(Vector3(point.x, point.y, room.listener.z))
			room.set_listener(p)
	queue_redraw()


func _release() -> void:
	var kind := _drag
	_drag = Drag.NONE
	if kind == Drag.LISTENER:
		HistoryUtil.record_property("Move Listener", project.stage, "set_state", _listener_old, project.stage.get_state())
		_listener_old = {}
	elif kind != Drag.NONE:
		var cmds: Array[Command] = []
		for i in _drag_channels.size():
			var now := _drag_channels[i].get_stage_state()
			if now == _drag_old[i]:
				continue
			var cmd := PropertyCommand.new("Edit Stage Source", _drag_channels[i], "set_stage_state", _drag_old[i], now)
			cmd.set_mergeable(true)
			cmds.append(cmd)
		HistoryUtil.record_many("Edit Stage Sources", cmds)
	_drag_channels = []
	_drag_old = []
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover != null and _drag == Drag.NONE:
		_hover = null
		queue_redraw()


# ============================================================================
# Drawing
# ============================================================================

func _draw() -> void:
	var ink := get_theme_color("font_color", "Label")
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	if project == null:
		return
	_update_layout()
	var room := project.stage
	var rect := Rect2(_origin, Vector2(room.width, room.depth) * _scale)
	draw_rect(rect, Color(ink, 0.05))
	_draw_grid(rect, ink)
	draw_rect(rect, Color(ink, 0.55), false, 2.0)
	# Front wall at the top, and the room's size along the top and left edges.
	draw_string(font, rect.position + Vector2(4, -6), "Front", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(ink, 0.7))
	draw_string(font, rect.position + Vector2(0, -6), "%.0f m" % room.width, HORIZONTAL_ALIGNMENT_RIGHT, rect.size.x, font_size, Color(ink, 0.5))
	draw_string(font, rect.position + Vector2(rect.size.x + 4, 14), "%.0f m" % room.depth, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(ink, 0.5))
	_draw_listener(ink)
	if _items.is_empty():
		draw_string(font, rect.position + Vector2(0, rect.size.y * 0.5), "No stage sources. Set a channel's pan mode to Stage.",
				HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, font_size, Color(ink, 0.6))
		return
	for ch in _items:
		_draw_source(ch, ink, font, font_size)


## A fixed 1 m grid whose lines start at the room centre and go outward, so the centre lines are
## always drawn. The centre axes and every 5 m are stronger. Cells that get too small fade out
## rather than changing the step.
func _draw_grid(rect: Rect2, ink: Color) -> void:
	var room := project.stage
	var center := Vector2(room.width, room.depth) * 0.5
	var fade := clampf(_scale / GRID_MIN_PX, 0.15, 1.0)
	for axis in 2:
		var half := center[axis]
		var n := 0
		while n <= int(half):
			for sign_ in ([1.0] if n == 0 else [-1.0, 1.0]):
				var pos: float = center[axis] + sign_ * n
				if pos < 0.0 or pos > (room.width if axis == 0 else room.depth):
					continue
				var alpha := 0.08 * fade
				var width := 1.0
				if n == 0:
					alpha = 0.3
					width = 1.5
				elif n % 5 == 0:
					alpha = maxf(0.16 * fade, 0.06)
				var p := to_screen(Vector2(pos, pos))
				if axis == 0:
					draw_line(Vector2(p.x, rect.position.y), Vector2(p.x, rect.end.y), Color(ink, alpha), width)
				else:
					draw_line(Vector2(rect.position.x, p.y), Vector2(rect.end.x, p.y), Color(ink, alpha), width)
			n += 1


func _draw_listener(ink: Color) -> void:
	var c := to_screen(Vector2(project.stage.listener.x, project.stage.listener.y))
	var col := Color(ink, 0.85)
	draw_circle(c, 7.0, col)
	# A nose toward the front wall (up).
	draw_colored_polygon(PackedVector2Array([c + Vector2(-5, -5), c + Vector2(5, -5), c + Vector2(0, -13)]), col)


func _draw_source(ch: Channel, ink: Color, font: Font, font_size: int) -> void:
	var state := displayed_state(ch)
	var color := Utils.display_color(ch.color)
	var selected := selection.has(ch)
	var center := to_screen(Vector2(float(state.x), float(state.y)))
	var dot: bool = float(state.size) < StageEdit.MIN_SIZE
	var top := center.y - (DOT_RADIUS if dot else 0.0)
	if dot:
		if selected:
			draw_circle(center, DOT_RADIUS + 2.5, Color.WHITE)
		draw_circle(center, DOT_RADIUS, color)
	else:
		var outline := PackedVector2Array()
		for corner in StageEdit.corners(state):
			var sp := to_screen(corner)
			outline.append(sp)
		top = outline[0].y
		for sp in outline:
			top = minf(top, sp.y)
		var section: bool = int(state.get("display", 0)) == StageEdit.DISPLAY_SECTION
		if section:
			draw_colored_polygon(outline, Color(color, 0.2))
			_draw_players(state, color)
		else:
			draw_colored_polygon(outline, Color(color, 0.85))
		var closed := outline.duplicate()
		closed.append(outline[0])
		if selected:
			draw_polyline(closed, Color.WHITE, 4.0, true)
		draw_polyline(closed, color, 2.0, true)
	if selected or ch == _hover:
		var handles := _handles(state)
		for which in 2:
			if dot and which == 0:
				continue  # a dot has one handle
			_draw_handle(handles[which], color, false)
		if not dot:
			var edges := _edge_handles(state)
			for which in 2:
				_draw_handle(edges[which], color, true)
	draw_string(font, Vector2(center.x - 60, top - 6), ch.name, HORIZONTAL_ALIGNMENT_CENTER, 120, font_size, Color(ink, 0.95 if selected else 0.75))


func _draw_handle(at: Vector2, color: Color, square: bool) -> void:
	if square:
		draw_rect(Rect2(at - Vector2.ONE * HANDLE_RADIUS, Vector2.ONE * HANDLE_RADIUS * 2.0), Color.WHITE)
		draw_rect(Rect2(at - Vector2.ONE * (HANDLE_RADIUS - 1.5), Vector2.ONE * (HANDLE_RADIUS - 1.5) * 2.0), color)
	else:
		draw_circle(at, HANDLE_RADIUS, Color.WHITE)
		draw_circle(at, HANDLE_RADIUS - 1.5, color)


## One person icon (a head and shoulders) per player of a Section, sized to its grid cell.
func _draw_players(state: Dictionary, color: Color) -> void:
	var players := StageEdit.player_positions(state)
	if players.is_empty():
		return
	var grid := StageEdit.section_grid(players.size(), float(state.size), float(state.get("depth", 0.0)))
	var cell := Vector2(float(state.size) / grid.x, float(state.get("depth", 0.0)) / grid.y) * _scale
	var r := minf(cell.x, cell.y) * ICON_FILL * 0.5
	for p in players:
		var at := to_screen(p)
		if r < ICON_MIN_PX:
			draw_circle(at, maxf(r, 1.0), color)
			continue
		draw_circle(at + Vector2(0, -r * 0.45), r * 0.38, color)
		draw_arc(at + Vector2(0, r * 0.85), r * 0.7, PI, TAU, 12, color, maxf(r * 0.35, 1.5), true)
