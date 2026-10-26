# ClipStripActions.gd
# Node-free helpers for the clip editor's clip strip: range selection along a track, and copying
# clips to a later position with overwrite (Ctrl+D, Ctrl+drag). Copies replace whatever is in
# their target span (clips there are removed, trimmed or split by ClipRangeActions.clear), and the
# whole edit is one undo step.
class_name ClipStripActions extends RefCounted


## Every instance on `track` from `anchor` to `target` inclusive, in start order. Either end may
## come first. Just `target` when `anchor` is not on the track.
static func range_between(track: Track, anchor: ClipInstance, target: ClipInstance) -> Array[ClipInstance]:
	var out: Array[ClipInstance] = []
	if track == null or target == null:
		return out
	var sorted: Array[ClipInstance] = []
	for ci in track.clip_instances:
		if ci:
			sorted.append(ci)
	sorted.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
	var i := sorted.find(anchor)
	var j := sorted.find(target)
	if j < 0:
		return out
	if i < 0:
		out.append(target)
		return out
	for k in range(mini(i, j), maxi(i, j) + 1):
		out.append(sorted[k])
	return out


## Where a paste from the clip strip lands: the note selection's range start, else a pending range
## start from the ruler, else the playhead (the arranger uses its range start, the last clicked tick,
## then the playhead). Negative values mean "not set".
static func paste_tick(note_range_start: int, ruler_range_start: int, playhead: int) -> int:
	if note_range_start >= 0:
		return note_range_start
	if ruler_range_start >= 0:
		return ruler_range_start
	return maxi(0, playhead)


## The offset that puts a copy of `instances` directly after the block they span.
static func duplicate_delta(instances: Array[ClipInstance]) -> int:
	if instances.is_empty():
		return 0
	var first := instances[0].start_ticks
	var last := instances[0].get_end_ticks()
	for ci in instances:
		first = mini(first, ci.start_ticks)
		last = maxi(last, ci.get_end_ticks())
	return last - first


## True when copies of `instances` moved by `delta` start at tick 0 or later and would not land on
## any of the instances themselves.
static func copy_delta_valid(instances: Array[ClipInstance], delta: int) -> bool:
	if instances.is_empty() or delta == 0:
		return false
	for ci in instances:
		if ci.start_ticks + delta < 0:
			return false
		for src in instances:
			if ci.start_ticks + delta < src.get_end_ticks() and src.start_ticks < ci.get_end_ticks() + delta:
				return false
	return true


## Copy `instances` (all on `track`) `delta` ticks along, replacing what is under the copies. With
## "automation follows clips" on, the lane points under each source clip are copied too. One undo
## step named `label`. Returns the new instances ([] when the delta is not valid).
static func copy_clips(project: Project, track: Track, instances: Array[ClipInstance], delta: int, label: String = "Duplicate Clips") -> Array[ClipInstance]:
	var created: Array[ClipInstance] = []
	if track == null or not copy_delta_valid(instances, delta):
		return created
	var cmds: Array[Command] = []
	for ci in instances:
		cmds.append_array(ClipRangeActions.clear(track, ci.start_ticks + delta, ci.get_end_ticks() + delta))
	for ci in instances:
		var copy := ClipInstance.new("", ci.clip_id)
		copy.clip = ci.clip
		copy.start_ticks = ci.start_ticks + delta
		copy.duration_ticks = ci.duration_ticks
		copy.copy_overrides_from(ci)
		var cmd := ClipInstanceCreateCommand.new(track, ci.clip, copy.start_ticks, ci.duration_ticks, null, false, copy)
		cmd.name = "Duplicate Clip"
		cmd.do()
		cmds.append(cmd)
		created.append(copy)
	if project != null and project.get_arranger_view("automation_follows_clips"):
		var copies: Array = []
		for ci in instances:
			copies.append({"track": track, "start": ci.start_ticks, "end": ci.get_end_ticks(), "delta": delta})
		for cmd in AutomationActions.copy_track_automation_commands(copies, "Duplicate Automation"):
			cmd.do()
			cmds.append(cmd)
	HistoryUtil.record_many(label, cmds)
	return created
