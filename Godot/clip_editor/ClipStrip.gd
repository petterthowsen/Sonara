# ClipStrip.gd
# The clip editor's clip strip (docs/specs/054-clip-editor-clip-strip): one row between the ruler
# and the note area that draws clips as bars and lets the user edit them.
#
# Two modes, set by ClipEditor:
#  - bind_clip(instance): clip mode. Ticks are clip-content ticks (the ruler's). It shows the bound
#    instance's played window, or its loop region, and only the right end is draggable.
#  - bind_track(track): track mode. Ticks are song ticks. It shows every clip of the track and
#    edits them (move, trim either end, create, context menu), with its own multi-selection.
#
# The strip draws all bars itself and hit-tests them, the way BaseRuler does. Edits go through the
# ClipInstance / Clip setters and ClipEdgeEdits (the arranger's edge rules), and every finished
# gesture is one undo step named like the arranger's. Menu actions are the arranger's: the strip
# only asks for the menu (context_menu_requested) and ClipEditor opens it.
class_name ClipStrip extends Control

## Right-click on a bar. `instances` are the clips the menu acts on, `split_tick` is where Split
## cuts (song ticks), `anchor_rect` is the bar in global coordinates and `from_x` the global x of
## the click.
signal context_menu_requested(instances: Array[ClipInstance], split_tick: int, anchor_rect: Rect2, from_x: float)
## The strip's own clip selection changed (track mode).
signal selection_changed
## Ctrl+C with clips selected (track mode): the selection to put on the clip clipboard.
signal copy_requested(instances: Array[ClipInstance])
## Ctrl+V while the strip has focus: paste the clip clipboard on the focus track.
signal paste_requested

enum Mode { NONE, CLIP, TRACK }
## Which part of a bar a point is on.
enum Zone { BODY, LEFT, RIGHT }

const THEME_TYPE := &"ClipStrip"
## Pixel width of the left/right resize zones of a bar.
const EDGE_PX := 8.0
## Pixels the pointer must travel before a press on a bar's body becomes a move.
const DRAG_THRESHOLD_PX := 4.0
## Bars narrower than this get no name.
const MIN_TEXT_PX := 16.0
const ICON_SIZE := 12.0
const BAR_INSET_Y := 2.0
const LINK_ICON: Texture2D = preload("res://assets/icons/link.svg")

## Fill multipliers (value, saturation) of a bar that is not selected; a selected bar is drawn
## with the clip's full display colour.
const UNSELECTED_BRIGHTNESS := 0.6
const UNSELECTED_SATURATION := 0.8
const LEAD_IN_ALPHA := 0.3

var grid_helper: GridHelper = null:
	set(gh):
		if grid_helper == gh:
			return
		if grid_helper and grid_helper.changed.is_connected(queue_redraw):
			grid_helper.changed.disconnect(queue_redraw)
		grid_helper = gh
		if grid_helper:
			grid_helper.changed.connect(queue_redraw)
		queue_redraw()

## Distance from the strip's left edge to the note area's, as the ruler's `offset_x`.
var offset_x: float = 0.0:
	set(value):
		if offset_x != value:
			offset_x = value
			queue_redraw()

var mode: Mode = Mode.NONE
## Clips selected in the strip (track mode). Separate from the arranger's selection.
var selection: Array[ClipInstance] = []

var _instance: ClipInstance = null
var _track: Track = null
## [Signal, Callable] pairs connected to the bound data, so they can be undone.
var _watched: Array = []
## The gesture in progress: {kind, anchor, press_x, started, instances, snaps, exclusive, delta}.
var _press: Dictionary = {}
## The clip a Shift+click selects a range from: the last one clicked without Shift.
var _anchor: ClipInstance = null
var _style: StyleBoxFlat = null


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	_apply_theme_metrics()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_style = null
		_apply_theme_metrics()
		queue_redraw()


func _apply_theme_metrics() -> void:
	custom_minimum_size.y = float(get_theme_constant(&"height", THEME_TYPE))


# ============================================================================
# BINDING
# ============================================================================

## Clip mode: show `instance` (null shows nothing).
func bind_clip(instance: ClipInstance) -> void:
	_cancel_gesture()
	_unwatch()
	_track = null
	_instance = instance
	mode = Mode.CLIP if instance != null else Mode.NONE
	_set_selection([])
	_watch()
	queue_redraw()


## Track mode: show `track`'s clips (null shows nothing). The selection is cleared when the
## track is a different one.
func bind_track(track: Track) -> void:
	_cancel_gesture()
	_unwatch()
	var changed := track != _track
	_instance = null
	_track = track
	mode = Mode.TRACK if track != null else Mode.NONE
	if changed:
		_set_selection([])
		_anchor = null
	_watch()
	queue_redraw()


func unbind() -> void:
	bind_clip(null)


## The bars the strip shows, in strip ticks: [{instance, start, end, lead_start}]. `lead_start`
## is where the faint lead-in of a looped instance's first run begins, or -1 for none.
func bars() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if mode == Mode.CLIP and _instance != null:
		var ci := _instance
		if ci.loop_enabled and ci.loop_length_ticks > 0:
			var run := ci.first_run_range()
			out.append({
				"instance": ci,
				"start": ci.loop_start_ticks,
				"end": ci.loop_start_ticks + ci.loop_length_ticks,
				"lead_start": run.x if run.x < ci.loop_start_ticks else -1,
			})
		else:
			out.append({
				"instance": ci,
				"start": ci.clip_offset,
				"end": ci.clip_offset + ci.duration_ticks,
				"lead_start": -1,
			})
	elif mode == Mode.TRACK and _track != null:
		for ci in _track.clip_instances:
			if ci:
				out.append({"instance": ci, "start": ci.start_ticks, "end": ci.get_end_ticks(), "lead_start": -1})
	return out


## True when `instance`'s clip has more than one instance in the project.
func is_shared(instance: ClipInstance) -> bool:
	var project := _project()
	return project != null and instance != null and project.is_clip_shared(instance.clip_id)


func _project() -> Project:
	var track := _track if _track != null else (_instance.track if _instance != null else null)
	return track.get_project_ref() if track != null else null


func _watch_signal(sig: Signal, cb: Callable) -> void:
	sig.connect(cb)
	_watched.append([sig, cb])


func _unwatch() -> void:
	for pair in _watched:
		var sig: Signal = pair[0]
		if is_instance_valid(sig.get_object()) and sig.is_connected(pair[1]):
			sig.disconnect(pair[1])
	_watched.clear()


func _watch() -> void:
	var redraw := queue_redraw
	var project := _project()
	if project != null:
		_watch_signal(project.instance_counts_changed, redraw)
	if mode == Mode.CLIP and _instance != null:
		_watch_instance(_instance)
		if _instance.track != null:
			_watch_signal(_instance.track.color_changed, redraw.unbind(1))
	elif mode == Mode.TRACK and _track != null:
		_watch_signal(_track.color_changed, redraw.unbind(1))
		_watch_signal(_track.clip_instance_added, _on_track_instances_changed.unbind(1))
		_watch_signal(_track.clip_instance_removed, _on_track_instances_changed.unbind(1))
		for ci in _track.clip_instances:
			if ci:
				_watch_instance(ci)


func _watch_instance(ci: ClipInstance) -> void:
	_watch_signal(ci.instance_modified, queue_redraw)
	_watch_signal(ci.clip_changed, _on_instance_clip_changed.unbind(1))
	if ci.clip != null:
		_watch_signal(ci.clip.clip_modified, queue_redraw)


## A retargeted instance (Make Unique) has a new clip whose renames must be followed.
func _on_instance_clip_changed() -> void:
	_unwatch()
	_watch()
	queue_redraw()


func _on_track_instances_changed() -> void:
	# Drop selected clips that left the track, and follow the new ones.
	var kept: Array[ClipInstance] = []
	for ci in selection:
		if _track != null and _track.clip_instances.has(ci):
			kept.append(ci)
	if kept.size() != selection.size():
		_set_selection(kept)
	_unwatch()
	_watch()
	queue_redraw()


# ============================================================================
# SELECTION
# ============================================================================

func _set_selection(instances: Array[ClipInstance]) -> void:
	var same := instances.size() == selection.size()
	if same:
		for ci in instances:
			if not selection.has(ci):
				same = false
				break
	if same:
		return
	selection = instances
	selection_changed.emit()
	queue_redraw()


## Replace the selection (used after a paste or duplicate selects what it made).
func select_instances(instances: Array[ClipInstance]) -> void:
	_set_selection(instances)
	_anchor = instances[0] if not instances.is_empty() else null


func is_selected(instance: ClipInstance) -> bool:
	return selection.has(instance)


# ============================================================================
# GEOMETRY
# ============================================================================

func _tick_to_x(ticks: int) -> float:
	return grid_helper.ticks_to_pixels(ticks) - grid_helper.scroll_position + offset_x


func _x_to_tick(x: float) -> int:
	return grid_helper.pixels_to_ticks(x - offset_x + grid_helper.scroll_position)


## The bar's rectangle in strip-local pixels (not clipped to the visible area).
func bar_rect(bar: Dictionary) -> Rect2:
	var x0 := _tick_to_x(int(bar["start"]))
	var x1 := _tick_to_x(int(bar["end"]))
	return Rect2(x0, BAR_INSET_Y, x1 - x0, maxf(0.0, size.y - 2.0 * BAR_INSET_Y))


## The bar under local `x` and the part of it: {bar, instance, zone}, or {} for empty space. In
## clip mode only the right end is a handle.
func hit_test(x: float) -> Dictionary:
	if grid_helper == null or x < offset_x:
		return {}
	var all := bars()
	for i in range(all.size() - 1, -1, -1):
		var bar := all[i]
		var r := bar_rect(bar)
		if x < r.position.x or x > r.end.x:
			continue
		var edge := minf(EDGE_PX, r.size.x / 3.0)
		var zone := Zone.BODY
		if mode == Mode.TRACK and x - r.position.x <= edge:
			zone = Zone.LEFT
		elif x >= r.end.x - edge:
			zone = Zone.RIGHT
		return {"bar": bar, "instance": bar["instance"], "zone": zone}
	return {}


func _get_cursor_shape(at_position: Vector2 = Vector2.ZERO) -> CursorShape:
	var hit := hit_test(at_position.x)
	if not hit.is_empty() and hit["zone"] != Zone.BODY:
		return Control.CURSOR_HSIZE
	return Control.CURSOR_ARROW


# ============================================================================
# DRAWING
# ============================================================================

func _bar_color(ci: ClipInstance) -> Color:
	var base: Color = ci.color_override if ci.color_override.a > 0.0 else (ci.track.get_color() if ci.track else ci.get_effective_color())
	return Utils.display_color(base)


func _bar_style() -> StyleBoxFlat:
	if _style == null:
		var themed := get_theme_stylebox(&"bar", THEME_TYPE)
		_style = themed.duplicate() as StyleBoxFlat if themed is StyleBoxFlat else StyleBoxFlat.new()
	return _style


func _draw() -> void:
	if grid_helper == null or mode == Mode.NONE:
		return
	var left := maxf(offset_x, 0.0)
	var font := get_theme_font(&"font", &"Label")
	var font_size := maxi(8, get_theme_font_size(&"font_size", &"Label") - 1)
	var name_color := get_theme_color(&"name", THEME_TYPE)
	var icon_color := get_theme_color(&"link_icon", THEME_TYPE)
	for bar in bars():
		var ci: ClipInstance = bar["instance"]
		var r := bar_rect(bar)
		var x0 := maxf(r.position.x, left)
		var x1 := minf(r.end.x, size.x)
		if x1 <= x0:
			continue
		var selected := mode == Mode.CLIP or is_selected(ci)
		var color := _bar_color(ci)
		if not selected:
			color.v = clampf(color.v * UNSELECTED_BRIGHTNESS, 0.0, 1.0)
			color.s = clampf(color.s * UNSELECTED_SATURATION, 0.0, 1.0)
		var visible_rect := Rect2(x0, r.position.y, x1 - x0, r.size.y)
		if int(bar["lead_start"]) >= 0:
			var lead_x0 := maxf(_tick_to_x(int(bar["lead_start"])), left)
			if r.position.x > lead_x0:
				var lead := Color(color.r, color.g, color.b, LEAD_IN_ALPHA)
				_draw_bar(Rect2(lead_x0, r.position.y, minf(r.position.x, size.x) - lead_x0, r.size.y), lead, false, true)
		_draw_bar(visible_rect, color, r.position.x < x0, r.end.x > x1)
		var text_x := x0 + 5.0
		if is_shared(ci) and visible_rect.size.x >= 2.0 * ICON_SIZE:
			var icon_rect := Rect2(text_x, r.position.y + (r.size.y - ICON_SIZE) * 0.5, ICON_SIZE, ICON_SIZE)
			draw_texture_rect(LINK_ICON, icon_rect, false, icon_color)
			text_x += ICON_SIZE + 4.0
		if mode == Mode.TRACK and ci.clip != null:
			var avail := x1 - 4.0 - text_x
			if avail >= MIN_TEXT_PX:
				var line := TextLine.new()
				line.add_string(ci.clip.name, font, font_size)
				line.width = avail
				line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				line.draw(get_canvas_item(), Vector2(text_x, r.position.y + (r.size.y - line.get_size().y) * 0.5), name_color)
	_draw_copy_ghosts()


## Fill `rect` with the themed bar style tinted `color`. A side cut off by the visible area is
## drawn square, so it doesn't look like the clip ends there.
func _draw_bar(rect: Rect2, color: Color, cut_left: bool, cut_right: bool) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var style := _bar_style()
	var themed := get_theme_stylebox(&"bar", THEME_TYPE)
	var radius_tl := 0
	var radius_tr := 0
	var radius_bl := 0
	var radius_br := 0
	if themed is StyleBoxFlat:
		radius_tl = themed.corner_radius_top_left
		radius_tr = themed.corner_radius_top_right
		radius_bl = themed.corner_radius_bottom_left
		radius_br = themed.corner_radius_bottom_right
	style.bg_color = color
	style.corner_radius_top_left = 0 if cut_left else radius_tl
	style.corner_radius_bottom_left = 0 if cut_left else radius_bl
	style.corner_radius_top_right = 0 if cut_right else radius_tr
	style.corner_radius_bottom_right = 0 if cut_right else radius_br
	style.draw(get_canvas_item(), rect)


## Faint bars where Ctrl+drag copies would land (drawn after the real bars).
func _draw_copy_ghosts() -> void:
	if _press.is_empty() or _press["kind"] != &"copy" or not _press["started"]:
		return
	var delta: int = _press["delta"]
	var instances: Array[ClipInstance] = _press["instances"]
	var valid := ClipStripActions.copy_delta_valid(instances, delta)
	var left := maxf(offset_x, 0.0)
	for ci in instances:
		var color := _bar_color(ci)
		color.a = 0.5 if valid else 0.15
		var r := bar_rect({"start": ci.start_ticks + delta, "end": ci.get_end_ticks() + delta})
		var x0 := maxf(r.position.x, left)
		var x1 := minf(r.end.x, size.x)
		if x1 > x0:
			_draw_bar(Rect2(x0, r.position.y, x1 - x0, r.size.y), color, r.position.x < x0, r.end.x > x1)


# ============================================================================
# GESTURES
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if grid_helper == null or mode == Mode.NONE:
		return
	if event is InputEventKey:
		if event.pressed:
			_on_key(event)
	elif event is InputEventMouseMotion:
		_on_motion(event)
	elif event is InputEventMouseButton:
		var button: InputEventMouseButton = event
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_on_left_press(button)
			else:
				_on_left_release(button)
		elif button.button_index == MOUSE_BUTTON_RIGHT and not button.pressed:
			_on_right_release(button)


func _on_left_press(event: InputEventMouseButton) -> void:
	if event.double_click:
		# A double-click on a bar does no more than a click; on empty space it creates a clip.
		if hit_test(event.position.x).is_empty():
			_create_clip_at(event.position.x)
		return
	var hit := hit_test(event.position.x)
	if mode == Mode.CLIP:
		if not hit.is_empty() and hit["zone"] == Zone.RIGHT:
			_begin_gesture(&"clip_right", hit["instance"], event.position.x, [hit["instance"]] as Array[ClipInstance])
		accept_event()
		return
	grab_focus()
	var additive := event.ctrl_pressed or event.meta_pressed
	if hit.is_empty():
		if not additive and not event.shift_pressed:
			_set_selection([])
			_anchor = null
		accept_event()
		return
	var ci: ClipInstance = hit["instance"]
	accept_event()
	if additive:
		# A click toggles the clip; a drag copies the selection (decided on release / drag start).
		var group: Array[ClipInstance] = []
		if selection.has(ci):
			group.assign(selection)
		else:
			group.append(ci)
		_begin_gesture(&"copy", ci, event.position.x, group)
		_press["toggle"] = true
		return
	var exclusive := false
	if event.shift_pressed:
		if _anchor != null and _track != null and _track.clip_instances.has(_anchor):
			_set_selection(ClipStripActions.range_between(_track, _anchor, ci))
		elif not selection.has(ci):
			var added := selection.duplicate()
			added.append(ci)
			_set_selection(added)
		if _anchor == null:
			_anchor = ci
	elif not selection.has(ci):
		_set_selection([ci] as Array[ClipInstance])
		_anchor = ci
	else:
		# Pressing a clip of a multi-selection keeps it for a drag; a plain click narrows it.
		exclusive = selection.size() > 1
		_anchor = ci
	if not selection.has(ci):
		return
	var kind: StringName = &"move"
	if hit["zone"] == Zone.LEFT:
		kind = &"left"
	elif hit["zone"] == Zone.RIGHT:
		kind = &"right"
	_begin_gesture(kind, ci, event.position.x, selection.duplicate(), exclusive)


func _begin_gesture(kind: StringName, anchor: ClipInstance, press_x: float, instances: Array[ClipInstance], exclusive: bool = false) -> void:
	var snaps := {}
	for ci in instances:
		snaps[ci] = ClipEdgeEdits.snapshot(ci)
	_press = {
		"kind": kind,
		"anchor": anchor,
		"press_x": press_x,
		"started": kind != &"move" and kind != &"copy",
		"instances": instances,
		"snaps": snaps,
		"exclusive": exclusive,
		"delta": 0,
	}


func _on_motion(event: InputEventMouseMotion) -> void:
	if _press.is_empty():
		return
	var dx: float = event.position.x - float(_press["press_x"])
	if not _press["started"]:
		if absf(dx) <= DRAG_THRESHOLD_PX:
			accept_event()
			return
		_press["started"] = true
	var tick_delta := grid_helper.pixels_to_ticks(dx)
	var free: bool = event.shift_pressed
	match _press["kind"]:
		&"move":
			_apply_move(tick_delta, free)
		&"left", &"right":
			_apply_edge(tick_delta, free)
		&"clip_right":
			_apply_clip_right(tick_delta, free)
		&"copy":
			_apply_copy(tick_delta, free)
	accept_event()


func _on_left_release(_event: InputEventMouseButton) -> void:
	if _press.is_empty():
		return
	var press := _press
	_press = {}
	if not press["started"]:
		if press.get("toggle", false):
			_toggle_selected(press["anchor"])
		elif press["exclusive"]:
			_set_selection([press["anchor"]] as Array[ClipInstance])
		return
	match press["kind"]:
		&"move":
			_finish_move(press)
		&"left", &"right":
			_finish_edge(press)
		&"clip_right":
			_finish_clip_right(press)
		&"copy":
			_finish_copy(press)
			queue_redraw()


## Abandon a gesture without recording it (the strip was rebound mid-drag).
func _cancel_gesture() -> void:
	_press = {}


func _min_duration(free: bool) -> int:
	var interval := 0 if free else grid_helper.get_snap_interval()
	return interval if interval > 0 else 1


## `edge` moved by `tick_delta`, snapped to the grid unless `free`; returns the change from `edge`.
func _snapped_edge_delta(edge: int, tick_delta: int, free: bool) -> int:
	var target := edge + tick_delta
	if not free:
		target = grid_helper.snap_ticks(target)
	return target - edge


# -- Move (track mode) --------------------------------------------------------

func _apply_move(tick_delta: int, free: bool) -> void:
	var instances: Array[ClipInstance] = _press["instances"]
	var snaps: Dictionary = _press["snaps"]
	var anchor_start: int = snaps[_press["anchor"]]["start"]
	var delta := _snapped_edge_delta(anchor_start, tick_delta, free)
	var clamped := delta
	for ci in instances:
		var snap: Dictionary = snaps[ci]
		var limit := ClipEdgeEdits.clamp_move_on_track(snap["start"], snap["duration"], _track, instances, delta, true)
		clamped = mini(clamped, limit) if delta > 0 else maxi(clamped, limit)
	for ci in instances:
		ci.set_position(int(snaps[ci]["start"]) + clamped)
	_press["delta"] = clamped


func _finish_move(press: Dictionary) -> void:
	var delta: int = press["delta"]
	if delta == 0:
		return
	var snaps: Dictionary = press["snaps"]
	var cmds: Array[Command] = []
	var moves: Array = []
	for ci in press["instances"]:
		var snap: Dictionary = snaps[ci]
		cmds.append(ClipInstanceTransformCommand.new(
			"Move Clip", ci,
			snap["start"], snap["duration"], snap["offset"],
			ci.start_ticks, ci.duration_ticks, ci.clip_offset))
		moves.append({"track": _track, "start": snap["start"], "end": int(snap["start"]) + int(snap["duration"])})
	var project := _project()
	if project != null and project.get_arranger_view("automation_follows_clips"):
		# Same rule as the arranger: lane points under the moved clips travel with them.
		cmds.append_array(AutomationActions.shift_track_automation(moves, delta, "Move Automation"))
	HistoryUtil.record_many("Move Clips", cmds)


# -- Trim / resize (track mode) -------------------------------------------------

func _apply_edge(tick_delta: int, free: bool) -> void:
	var snaps: Dictionary = _press["snaps"]
	var left: bool = _press["kind"] == &"left"
	var anchor_snap: Dictionary = snaps[_press["anchor"]]
	var edge: int = anchor_snap["start"] if left else int(anchor_snap["start"]) + int(anchor_snap["duration"])
	var delta := _snapped_edge_delta(edge, tick_delta, free)
	var min_duration := _min_duration(free)
	for ci in _press["instances"]:
		if left:
			ClipEdgeEdits.resize_left(ci, snaps[ci], delta, min_duration)
		else:
			ClipEdgeEdits.resize_right(ci, snaps[ci], delta, min_duration)


func _finish_edge(press: Dictionary) -> void:
	var cmds: Array[Command] = []
	for ci in press["instances"]:
		var cmd := ClipEdgeEdits.transform_command("Resize Clip", ci, press["snaps"][ci])
		if cmd:
			cmds.append(cmd)
	HistoryUtil.record_many("Resize Clips", cmds)


# -- Right end in clip mode ------------------------------------------------------

func _apply_clip_right(tick_delta: int, free: bool) -> void:
	var ci: ClipInstance = _press["anchor"]
	var snap: Dictionary = _press["snaps"][ci]
	if snap["loop"].size() == 3 and snap["loop"][0]:
		# A looped instance: the right end of the loop region is the loop length.
		var loop_start: int = snap["loop"][1]
		var loop_length: int = snap["loop"][2]
		var delta := _snapped_edge_delta(loop_start + loop_length, tick_delta, free)
		ClipEdgeEdits.set_loop_length(ci, loop_length + delta, snap["content"])
	else:
		var delta := _snapped_edge_delta(int(snap["offset"]) + int(snap["duration"]), tick_delta, free)
		ClipEdgeEdits.resize_right(ci, snap, delta, _min_duration(free))


func _finish_clip_right(press: Dictionary) -> void:
	var ci: ClipInstance = press["anchor"]
	var snap: Dictionary = press["snaps"][ci]
	var looped: bool = snap["loop"].size() == 3 and snap["loop"][0]
	var cmd := ClipEdgeEdits.transform_command("Move Loop Point" if looped else "Resize Clip", ci, snap)
	if cmd == null:
		return
	if looped:
		HistoryUtil.record(cmd)
	else:
		HistoryUtil.record_many("Resize Clips", [cmd] as Array[Command])


# -- Create (track mode) -----------------------------------------------------------

## Double-click on empty space: a new empty clip at the snapped position, one bar long or less
## when the next clip leaves less room (as a double-click on an arranger lane does).
func _create_clip_at(x: float) -> void:
	var project := _project()
	if mode != Mode.TRACK or _track == null or project == null:
		return
	var tick := maxi(0, grid_helper.snap_ticks(_x_to_tick(x)))
	if _track.has_clip_overlap(tick, 1):
		return
	var length := grid_helper.get_ticks_per_bar_at(tick)
	for ci in _track.clip_instances:
		if ci == null or ci.start_ticks <= tick:
			continue
		length = mini(length, ci.start_ticks - tick)
	var created := ClipActions.create_clip(project, _track, tick, length, "", _track.default_clip_type())
	if created != null:
		_set_selection([created] as Array[ClipInstance])


# -- Context menu ------------------------------------------------------------------

func _on_right_release(event: InputEventMouseButton) -> void:
	var hit := hit_test(event.position.x)
	if hit.is_empty():
		return
	var ci: ClipInstance = hit["instance"]
	var instances: Array[ClipInstance] = []
	if mode == Mode.TRACK and selection.has(ci):
		instances.assign(selection)
	else:
		instances.append(ci)
	var tick := grid_helper.snap_ticks(_x_to_tick(event.position.x))
	var split_tick := ci.clip_to_song_ticks(tick) if mode == Mode.CLIP else tick
	var global_rect: Rect2 = get_global_transform() * bar_rect(hit["bar"])
	var from_x: float = (get_global_transform() * event.position).x
	accept_event()
	context_menu_requested.emit(instances, split_tick, global_rect, from_x)


# -- Copy by Ctrl+drag, Ctrl+click toggle ------------------------------------------

func _toggle_selected(ci: ClipInstance) -> void:
	var toggled := selection.duplicate()
	if toggled.has(ci):
		toggled.erase(ci)
	else:
		toggled.append(ci)
		_anchor = ci
	_set_selection(toggled)


func _apply_copy(tick_delta: int, free: bool) -> void:
	var instances: Array[ClipInstance] = _press["instances"]
	var anchor_start: int = _press["snaps"][_press["anchor"]]["start"]
	var delta := _snapped_edge_delta(anchor_start, tick_delta, free)
	var first := anchor_start
	for ci in instances:
		first = mini(first, int(_press["snaps"][ci]["start"]))
	_press["delta"] = maxi(delta, -first)
	queue_redraw()


func _finish_copy(press: Dictionary) -> void:
	var created := ClipStripActions.copy_clips(_project(), _track, press["instances"], press["delta"], "Copy Clips")
	if not created.is_empty():
		select_instances(created)


# -- Keys ----------------------------------------------------------------------------

func _on_key(event: InputEventKey) -> void:
	if mode != Mode.TRACK or _track == null:
		return
	if Hotkeys.pressed(event, "edit_copy") and not selection.is_empty():
		copy_requested.emit(selection.duplicate())
		accept_event()
	elif Hotkeys.pressed(event, "edit_paste"):
		paste_requested.emit()
		accept_event()
	elif Hotkeys.pressed(event, "edit_duplicate") and not selection.is_empty():
		duplicate_selection()
		accept_event()


## Ctrl+D: copy the selected clips directly after themselves, replacing whatever is there. Unlike
## the arranger's duplicate, which refuses an occupied target.
func duplicate_selection() -> void:
	if mode != Mode.TRACK or _track == null or selection.is_empty():
		return
	var chosen: Array[ClipInstance] = selection.duplicate()
	var created := ClipStripActions.copy_clips(_project(), _track, chosen, ClipStripActions.duplicate_delta(chosen), "Duplicate Clips")
	if not created.is_empty():
		select_instances(created)
