# ClipMergeActions.gd
# Undoable "Merge Clips" for MIDI clip instances. Per track, the selected instances are baked into one
# new clip and one new instance covering first start .. last end. A loop is unrolled to the instance
# length, trims and transpose are applied, and unselected instances in between are left alone.
# A single selected instance is consolidated the same way (what it plays becomes its own clip).
# Audio clips are not merged: that needs a render, not a note copy.
class_name ClipMergeActions extends RefCounted

static var logger := Log.make("ClipMergeActions")

## Stops a tiny loop on a very long instance from producing an enormous clip.
const MAX_LOOP_SEGMENTS := 4096


## The MIDI instances of `instances` that can be merged, grouped by track and sorted by start.
## Returns [{track: Track, instances: Array[ClipInstance]}], in track order of first appearance.
static func plan(instances: Array) -> Array[Dictionary]:
	var by_track: Dictionary = {}
	var order: Array[Track] = []
	for inst in instances:
		if inst == null or inst.track == null or inst.clip == null:
			continue
		if inst.clip.type != Clip.ClipType.MIDI:
			continue
		if not by_track.has(inst.track):
			by_track[inst.track] = []
			order.append(inst.track)
		if not by_track[inst.track].has(inst):
			by_track[inst.track].append(inst)
	var groups: Array[Dictionary] = []
	for track in order:
		var list: Array = by_track[track]
		list.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
		groups.append({"track": track, "instances": list})
	return groups


## True when `instances` holds at least one MIDI instance to merge.
static func can_merge(instances: Array) -> bool:
	return not plan(instances).is_empty()


## Merge `instances` as one undo step. Returns the new instances (one per track).
static func merge(project: Project, instances: Array) -> Array[ClipInstance]:
	var created: Array[ClipInstance] = []
	if project == null:
		return created
	var cmds: Array[Command] = []
	for group in plan(instances):
		var track: Track = group["track"]
		var sources: Array = group["instances"]
		var merged := _bake(project, track, sources)
		cmds.append(ClipInstanceCreateCommand.new(
			track, merged.clip, merged.start_ticks, merged.duration_ticks, project, true, merged))
		for inst in sources:
			cmds.append(ClipInstanceDeleteCommand.new(track, inst))
		created.append(merged)
	if cmds.is_empty():
		return created
	HistoryUtil.execute_many("Merge Clips" if instances.size() > 1 else "Consolidate Clip", cmds)
	return created


## Build the unplaced merged instance (and its new clip) for `sources`, sorted by start.
static func _bake(project: Project, track: Track, sources: Array) -> ClipInstance:
	var first: ClipInstance = sources[0]
	var start: int = first.start_ticks
	var end: int = start
	for inst in sources:
		end = maxi(end, inst.get_end_ticks())

	var clip := project.create_clip(project.unique_clip_name(first.clip.name), Clip.ClipType.MIDI)
	clip.color = first.clip.color
	clip.content_length_ticks = end - start
	for inst in sources:
		if inst.muted:
			continue
		_append_played_notes(project, clip, inst, inst.start_ticks - start)

	var merged := ClipInstance.new("", clip.id)
	merged.clip = clip
	merged.start_ticks = start
	merged.duration_ticks = end - start
	merged.muted = first.muted
	merged.color_override = first.color_override
	merged.fade_in_ticks = first.fade_in_ticks
	merged.fade_out_ticks = sources[-1].fade_out_ticks
	return merged


## Add to `dest` the notes `inst` plays, at `shift` ticks from the merged clip's start. Each run of
## the instance (a loop pass, or all of it) cuts notes at its edges, as playback does.
static func _append_played_notes(project: Project, dest: Clip, inst: ClipInstance, shift: int) -> void:
	var segments := inst.get_loop_segments(MAX_LOOP_SEGMENTS)
	if segments.size() >= MAX_LOOP_SEGMENTS:
		logger.warn("Merge: '%s' loops more than %d times, the tail is dropped" % [inst.clip.name, MAX_LOOP_SEGMENTS])
	for seg in segments:
		var content_from: int = seg.z
		var content_to: int = content_from + (seg.y - seg.x)
		for note in inst.clip.midi_notes:
			var s := maxi(note.start_tick, content_from)
			var e := mini(note.get_end_tick(), content_to)
			if e <= s:
				continue
			var nn := MidiNoteData.new()
			nn.id = project.allocate_note_id()
			nn.copy_values_from(note)
			nn.note = clampi(note.note + inst.transpose, 0, 127)
			nn.start_tick = shift + seg.x + (s - content_from)
			nn.duration_ticks = e - s
			dest.midi_notes.append(nn)
