class_name ClipSelection extends RefCounted

## Maintains a collection of selected ClipInstances and cached metadata

signal changed()

var clip_instances: Array[ClipInstance] = []
var start_tick: int = 0
var end_tick: int = 0

func clear() -> void:
	if clip_instances.is_empty():
		return
	clip_instances.clear()
	_recalculate_bounds()
	changed.emit()


func set_from(instances: Array[ClipInstance]) -> void:
	var unique: Array[ClipInstance] = []
	for inst in instances:
		if inst and not unique.has(inst):
			unique.append(inst)
	var was_same = unique.size() == clip_instances.size()
	if was_same:
		for inst in unique:
			if not clip_instances.has(inst):
				was_same = false
				break
	if was_same:
		return
	clip_instances = unique
	_recalculate_bounds()
	changed.emit()


func add(instance: ClipInstance) -> bool:
	if not instance:
		return false
	if clip_instances.has(instance):
		return false
	clip_instances.append(instance)
	_recalculate_bounds()
	changed.emit()
	return true


func remove(instance: ClipInstance) -> bool:
	if not clip_instances.has(instance):
		return false
	clip_instances.erase(instance)
	_recalculate_bounds()
	changed.emit()
	return true


func contains(instance: ClipInstance) -> bool:
	return clip_instances.has(instance)


func is_empty() -> bool:
	return clip_instances.is_empty()


func get_duration_ticks() -> int:
	return max(0, end_tick - start_tick)


func recompute_bounds() -> void:
	_recalculate_bounds()


func clone() -> ClipSelection:
	var copy := ClipSelection.new()
	var copied_instances: Array[ClipInstance] = []
	copied_instances.assign(clip_instances)
	copy.set_from(copied_instances)
	return copy


func get_sorted_by_start() -> Array[ClipInstance]:
	var result: Array[ClipInstance] = []
	result.assign(clip_instances)
	result.sort_custom(func(a: ClipInstance, b: ClipInstance):
		if a.start_ticks == b.start_ticks:
			return a.track.id < b.track.id if a.track and b.track else a.start_ticks < b.start_ticks
		return a.start_ticks < b.start_ticks
	)
	return result


func get_track_ids() -> Array[int]:
	var ids: Array[int] = []
	for inst in clip_instances:
		if inst and inst.track:
			if not ids.has(inst.track.id):
				ids.append(inst.track.id)
	return ids


func _recalculate_bounds() -> void:
	if clip_instances.is_empty():
		start_tick = 0
		end_tick = 0
		return

	var min_tick := 2147483647
	var max_tick := -2147483647
	for inst in clip_instances:
		if not inst:
			continue
		min_tick = min(min_tick, inst.start_ticks)
		max_tick = max(max_tick, inst.start_ticks + inst.duration_ticks)

	if max_tick < min_tick:
		min_tick = 0
		max_tick = 0

	start_tick = min_tick
	end_tick = max_tick
