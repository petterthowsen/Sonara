class_name ClipSelectionManager extends RefCounted

signal selection_changed(instances: Array[ClipInstance])
signal box_selection_changed(rect: Rect2)

var timeline: Timeline
var grid_helper: GridHelper

var selection: ClipSelection = ClipSelection.new()

var _clip_ui_by_instance: Dictionary = {}  # ClipInstance -> WeakRef(TimelineClip)
var _select_callable := Callable(self, "_on_clip_select_requested")

var is_box_selecting: bool = false
var box_start: Vector2 = Vector2.ZERO
var box_current: Vector2 = Vector2.ZERO
var box_rect: Rect2 = Rect2()
var box_start_tick: int = 0
var box_end_tick: int = 0


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


func unregister_clip_ui(clip_ui: TimelineClip) -> void:
	if not clip_ui:
		return

	if clip_ui.clip_instance and _clip_ui_by_instance.has(clip_ui.clip_instance):
		_clip_ui_by_instance.erase(clip_ui.clip_instance)

	if clip_ui.select_requested.is_connected(_select_callable):
		clip_ui.select_requested.disconnect(_select_callable)


func remove_instance(instance: ClipInstance) -> void:
	if not instance:
		return
	selection.remove(instance)


func clear_selection() -> void:
	if selection.is_empty():
		return
	selection.clear()


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


func start_box_selection(pos: Vector2) -> void:
	is_box_selecting = true
	box_start = pos
	box_current = pos
	box_rect = Rect2(pos, Vector2.ZERO)
	_update_box_ticks()
	_emit_box_rect_changed()
	if timeline:
		timeline.queue_redraw()


func update_box_selection(pos: Vector2) -> void:
	if not is_box_selecting:
		return
	box_current = pos
	box_rect = Rect2(box_start, Vector2.ZERO)
	box_rect = box_rect.expand(box_current)
	_update_box_ticks()
	_emit_box_rect_changed()
	if timeline:
		timeline.queue_redraw()


func end_box_selection(instances: Array[ClipInstance]) -> void:
	if not is_box_selecting:
		return
	is_box_selecting = false
	box_rect = Rect2()
	box_start = Vector2.ZERO
	box_current = Vector2.ZERO
	box_start_tick = 0
	box_end_tick = 0

	if instances:
		select_instances(instances)
	else:
		clear_selection()

	_emit_box_rect_changed()
	if timeline:
		timeline.queue_redraw()


func _on_clip_select_requested(_clip_ui: TimelineClip, additive: bool) -> void:
	if not _clip_ui or not _clip_ui.clip_instance:
		return

	var instance := _clip_ui.clip_instance
	if additive:
		toggle_selection(instance)
	else:
		if selection.contains(instance):
			return
		select_only(instance)


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


func _update_box_ticks() -> void:
	if not grid_helper:
		box_start_tick = 0
		box_end_tick = 0
		return
	box_start_tick = grid_helper.pixels_to_ticks(box_rect.position.x)
	box_end_tick = grid_helper.pixels_to_ticks(box_rect.position.x + box_rect.size.x)
