## Owns arranger clip selection, time-range boundaries, and the box-select gesture.
class_name ClipSelectionManager extends RefCounted

static var logger := Log.make("ClipSelectionManager")

signal selection_changed(instances: Array[ClipInstance])
signal box_selection_changed(rect: Rect2)
signal range_changed()

const ADDITIVE_DRAG_THRESHOLD := 6.0

var timeline: Timeline
var grid_helper: GridHelper

var selection: ClipSelection = ClipSelection.new()

var _clip_ui_by_instance: Dictionary = {}  # ClipInstance -> WeakRef(TimelineClip)
var _select_callable := Callable(self, "_on_clip_select_requested")
var _exclusive_click_callable := Callable(self, "_on_exclusive_click_requested")
var _pending_exclusive: ClipInstance = null

var is_box_selecting: bool = false
var is_additive_pending: bool = false
var box_start: Vector2 = Vector2.ZERO
var box_current: Vector2 = Vector2.ZERO
var box_rect: Rect2 = Rect2()
var box_start_tick: int = 0
var box_end_tick: int = 0

## Grid-snapped time range drawn as start/end boundary lines (independent of clip bounds).
var range_visible: bool = false
var range_start_tick: int = 0
var range_end_tick: int = 0
var range_has_end: bool = false

## Last clicked arranger location: lane/clip clicks and track header selection. Paste targets it.
var anchor_track: Track = null
var anchor_tick: int = -1

var _box_span_all_tracks: bool = false
var _preserve_range: bool = false
var _additive_start_pos: Vector2 = Vector2.ZERO
var _pending_additive_clip: ClipInstance = null


func _init():
	selection.changed.connect(_on_selection_changed)


func set_context(p_timeline: Timeline, p_grid_helper: GridHelper) -> void:
	timeline = p_timeline
	grid_helper = p_grid_helper


func register_clip_ui(clip_ui: TimelineClip) -> void:
	if not clip_ui or not clip_ui.clip_instance:
		return

	_clip_ui_by_instance[clip_ui.clip_instance] = weakref(clip_ui)
	clip_ui.set_selected(selection.contains(clip_ui.clip_instance))
	if not clip_ui.select_requested.is_connected(_select_callable):
		clip_ui.select_requested.connect(_select_callable)
	if not clip_ui.exclusive_click_requested.is_connected(_exclusive_click_callable):
		clip_ui.exclusive_click_requested.connect(_exclusive_click_callable)


func unregister_clip_ui(clip_ui: TimelineClip) -> void:
	if not clip_ui:
		return

	if clip_ui.clip_instance and _clip_ui_by_instance.has(clip_ui.clip_instance):
		_clip_ui_by_instance.erase(clip_ui.clip_instance)

	if clip_ui.select_requested.is_connected(_select_callable):
		clip_ui.select_requested.disconnect(_select_callable)
	if clip_ui.exclusive_click_requested.is_connected(_exclusive_click_callable):
		clip_ui.exclusive_click_requested.disconnect(_exclusive_click_callable)


func remove_instance(instance: ClipInstance) -> void:
	if not instance:
		return
	selection.remove(instance)


func clear_selection() -> void:
	hide_range()
	_pending_additive_clip = null
	if selection.is_empty():
		return
	selection.clear()


## Hide the start/end boundary lines without changing clip selection.
func hide_range() -> void:
	if not range_visible and range_start_tick == 0 and range_end_tick == 0:
		return
	range_visible = false
	range_start_tick = 0
	range_end_tick = 0
	range_has_end = false
	range_changed.emit()
	if timeline:
		timeline.queue_redraw()


## Show only the start boundary at a grid-snapped tick and drop any clip selection.
func set_range_start(tick: int) -> void:
	anchor_tick = tick
	_preserve_range = true
	_set_range(tick, tick, false)
	if selection.is_empty():
		_preserve_range = false
	else:
		selection.clear()
	if timeline:
		timeline.queue_redraw()
	logger.info("Selection start set to tick %d" % tick)


## True when a start boundary is visible (end may still be unset).
func has_range() -> bool:
	return range_visible


## (start, end) of the time range when both boundaries are set, otherwise (0, 0).
func get_full_range() -> Vector2i:
	if range_visible and range_has_end and range_end_tick > range_start_tick:
		return Vector2i(range_start_tick, range_end_tick)
	return Vector2i.ZERO


## Remember the last clicked location. A null `track` or negative `tick` leaves that part unchanged.
func set_anchor(track: Track, tick: int = -1) -> void:
	if track:
		anchor_track = track
	if tick >= 0:
		anchor_tick = tick


## Paste target: range start, else the last clicked tick, else `fallback`.
func get_paste_tick(fallback: int) -> int:
	if range_visible:
		return range_start_tick
	if anchor_tick >= 0:
		return anchor_tick
	return fallback


## Duplicate target: range end when both boundaries exist, otherwise `fallback`.
func get_duplicate_tick(fallback: int) -> int:
	if range_visible and range_has_end and range_end_tick > range_start_tick:
		return range_end_tick
	return fallback


func select_only(instance: ClipInstance) -> void:
	if not instance:
		selection.clear()
		return
	selection.set_from([instance])


func toggle_selection(instance: ClipInstance) -> void:
	if not instance:
		return
	if selection.contains(instance):
		selection.remove(instance)
	else:
		selection.add(instance)


func select_instances(instances: Array[ClipInstance]) -> void:
	selection.set_from(instances)


func get_selected_instances() -> Array[ClipInstance]:
	return selection.get_sorted_by_start()


func has_selection() -> bool:
	return not selection.is_empty()


func refresh_after_modification() -> void:
	selection.recompute_bounds()
	_on_selection_changed()


func get_selection_bounds() -> Vector2i:
	if selection.clip_instances.is_empty():
		return Vector2i.ZERO
	var min_tick := 2147483647
	var max_tick := -2147483647
	for inst in selection.clip_instances:
		if not inst:
			continue
		min_tick = min(min_tick, inst.start_ticks)
		max_tick = max(max_tick, inst.start_ticks + inst.duration_ticks)
	if max_tick < min_tick:
		return Vector2i.ZERO
	return Vector2i(min_tick, max_tick)


## Begin a Ctrl/Cmd press; a drag becomes box select. A click on empty space sets the start line.
func begin_additive_gesture(pos: Vector2, pending_clip: ClipInstance = null) -> void:
	is_additive_pending = true
	_additive_start_pos = pos
	_pending_additive_clip = pending_clip
	_box_span_all_tracks = false
	var lane := _track_at_y(pos.y)
	set_anchor(lane.track if lane else null)


## Stretch a pending or active additive gesture to `pos`.
func update_additive_gesture(pos: Vector2) -> void:
	if is_box_selecting:
		update_box_selection(pos)
		return
	if not is_additive_pending:
		return
	if pos.distance_to(_additive_start_pos) <= ADDITIVE_DRAG_THRESHOLD:
		return
	is_additive_pending = false
	start_box_selection(_additive_start_pos, _box_span_all_tracks)
	update_box_selection(pos)


## Finish a pending click (clip already selected on press, or set start) or an active box select.
func finish_additive_gesture(pos: Vector2) -> void:
	if is_box_selecting:
		end_box_selection()
		return
	if not is_additive_pending:
		return
	is_additive_pending = false
	var clicked_clip := _pending_additive_clip
	_pending_additive_clip = null
	if clicked_clip:
		return
	set_range_start(_ticks_from_x(_additive_start_pos.x if _additive_start_pos != Vector2.ZERO else pos.x))


## Begin a grid-snapped box select and apply any clips already under the box.
func start_box_selection(pos: Vector2, span_all_tracks: bool = false) -> void:
	is_additive_pending = false
	_pending_additive_clip = null
	is_box_selecting = true
	_box_span_all_tracks = span_all_tracks
	box_start = pos
	box_current = pos
	_rebuild_box_rect()
	_sync_selection_to_box()


## Stretch the box to `pos`, snap time and track edges, and refresh clip selection live.
func update_box_selection(pos: Vector2) -> void:
	if not is_box_selecting:
		return
	box_current = pos
	_rebuild_box_rect()
	_sync_selection_to_box()


## Finish the gesture: keep the live selection, persist grid-snapped bounds, hide the marquee.
func end_box_selection() -> void:
	if not is_box_selecting:
		return
	_sync_selection_to_box()
	var start_tick := mini(box_start_tick, box_end_tick)
	var end_tick := maxi(box_start_tick, box_end_tick)
	is_box_selecting = false
	_box_span_all_tracks = false
	_preserve_range = true
	_set_range(start_tick, end_tick, end_tick > start_tick)
	_expand_range_to_cover_selected_clips()
	box_rect = Rect2()
	box_start = Vector2.ZERO
	box_current = Vector2.ZERO
	box_start_tick = 0
	box_end_tick = 0
	_emit_box_rect_changed()
	if timeline:
		timeline.queue_redraw()


## Apply a clip click: Shift toggles, a new clip replaces, an already-selected clip waits for release.
func _on_clip_select_requested(_clip_ui: TimelineClip, additive: bool) -> void:
	if not _clip_ui or not _clip_ui.clip_instance:
		return

	var instance := _clip_ui.clip_instance
	set_anchor(instance.track, instance.start_ticks)
	if additive:
		_pending_exclusive = null
		toggle_selection(instance)
		return

	# Keep a multi-selection on press so the group can still be dragged; collapse on release.
	if selection.contains(instance) and selection.clip_instances.size() > 1:
		_pending_exclusive = instance
		return

	_pending_exclusive = null
	select_only(instance)


## Collapse a multi-selection to the clicked clip when the click did not become a drag.
func _on_exclusive_click_requested(clip_ui: TimelineClip) -> void:
	if not clip_ui or not clip_ui.clip_instance:
		return
	if _pending_exclusive == clip_ui.clip_instance:
		select_only(clip_ui.clip_instance)
	_pending_exclusive = null


func _on_selection_changed() -> void:
	var stale_instances: Array = []
	for key in _clip_ui_by_instance.keys():
		var clip_ref: WeakRef = _clip_ui_by_instance[key]
		var clip_ui: TimelineClip = clip_ref.get_ref() if clip_ref else null
		if clip_ui:
			clip_ui.set_selected(selection.contains(clip_ui.clip_instance))
		else:
			stale_instances.append(key)
	for stale in stale_instances:
		_clip_ui_by_instance.erase(stale)
	if not is_box_selecting and not _preserve_range and not selection.is_empty():
		_set_range_from_clips()
	_preserve_range = false
	_emit_selection_changed()
	if timeline:
		timeline.queue_redraw()


func _emit_selection_changed() -> void:
	var copies: Array[ClipInstance] = []
	for inst in selection.clip_instances:
		if inst:
			copies.append(inst)
	selection_changed.emit(copies)


func _emit_box_rect_changed() -> void:
	box_selection_changed.emit(box_rect)


## Rebuild `box_rect` from the drag corners, snapping time (X) and track (Y) edges.
func _rebuild_box_rect() -> void:
	var start_x := _snap_x_to_grid(box_start.x)
	var current_x := _snap_x_to_grid(box_current.x)
	var y_range := _snap_y_to_tracks(box_start.y, box_current.y)
	box_rect = Rect2(Vector2(start_x, y_range.x), Vector2.ZERO)
	box_rect = box_rect.expand(Vector2(current_x, y_range.y))
	_update_box_ticks()
	_emit_box_rect_changed()
	if timeline:
		timeline.queue_redraw()


## Select every clip that intersects the current snapped box, then expand the time range to cover them.
func _sync_selection_to_box() -> void:
	if not timeline:
		return
	select_instances(timeline.get_clip_instances_in_rect(box_rect))
	_expand_range_to_cover_selected_clips()


## Grow the visible range to cover selected clips without shrinking below the current range.
func _expand_range_to_cover_selected_clips() -> void:
	var bounds := get_selection_bounds()
	if bounds.x == bounds.y:
		return
	var start := range_start_tick
	var end := range_end_tick if range_has_end else range_start_tick
	start = mini(start, bounds.x)
	end = maxi(end, bounds.y)
	if start == range_start_tick and end == range_end_tick and range_has_end == (end > start):
		return
	_set_range(start, end, end > start)


## Snap a pixel X coordinate to the current time grid.
func _snap_x_to_grid(x: float) -> float:
	if not grid_helper:
		return x
	return grid_helper.snap_pixels(x)


## Return (top, bottom) covering every track lane between the two local Ys.
func _snap_y_to_tracks(start_y: float, current_y: float) -> Vector2:
	if _box_span_all_tracks:
		return _all_tracks_y_range()
	var start_track := _track_at_y(start_y)
	var current_track := _track_at_y(current_y)
	if not start_track and not current_track:
		return Vector2(min(start_y, current_y), max(start_y, current_y))

	var top := INF
	var bottom := -INF
	if start_track:
		top = min(top, start_track.position.y)
		bottom = max(bottom, start_track.position.y + start_track.size.y)
	if current_track:
		top = min(top, current_track.position.y)
		bottom = max(bottom, current_track.position.y + current_track.size.y)
	return Vector2(top, bottom)


## Return the track lane under `local_y`, or the nearest lane if outside all tracks.
func _track_at_y(local_y: float) -> TimelineTrack:
	if not timeline:
		return null
	var nearest: TimelineTrack = null
	var nearest_dist := INF
	for track in timeline.timeline_tracks:
		if not track:
			continue
		var top: float = track.position.y
		var bottom: float = top + track.size.y
		if local_y >= top and local_y <= bottom:
			return track
		var dist: float = min(abs(local_y - top), abs(local_y - bottom))
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = track
	return nearest


## Keep box ticks and the visible time range in sync with the snapped rect.
func _update_box_ticks() -> void:
	if not grid_helper:
		box_start_tick = 0
		box_end_tick = 0
		return
	var raw_start := grid_helper.pixels_to_ticks(box_rect.position.x)
	var raw_end := grid_helper.pixels_to_ticks(box_rect.position.x + box_rect.size.x)
	box_start_tick = mini(raw_start, raw_end)
	box_end_tick = maxi(raw_start, raw_end)
	_set_range(box_start_tick, box_end_tick, box_end_tick > box_start_tick)


## Snap a timeline-local X to a grid tick.
func _ticks_from_x(x: float) -> int:
	if not grid_helper:
		return 0
	return grid_helper.snap_ticks(grid_helper.pixels_to_ticks(x))


## Drive the visible range from the current clip selection bounds.
func _set_range_from_clips() -> void:
	var bounds := get_selection_bounds()
	if bounds.x == bounds.y:
		hide_range()
		return
	_set_range(bounds.x, bounds.y, true)


## Store and show the time-range boundaries.
func _set_range(start_tick: int, end_tick: int, has_end: bool) -> void:
	range_visible = true
	range_start_tick = start_tick
	range_end_tick = end_tick
	range_has_end = has_end
	range_changed.emit()


## Return (top, bottom) covering every track lane on the timeline.
func _all_tracks_y_range() -> Vector2:
	if not timeline or timeline.timeline_tracks.is_empty():
		return Vector2(0.0, timeline.size.y if timeline else 0.0)
	var top := INF
	var bottom := -INF
	for track in timeline.timeline_tracks:
		if not track:
			continue
		top = min(top, track.position.y)
		bottom = max(bottom, track.position.y + track.size.y)
	if top == INF:
		return Vector2(0.0, timeline.size.y)
	return Vector2(top, bottom)
