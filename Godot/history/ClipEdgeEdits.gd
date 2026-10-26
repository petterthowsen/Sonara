# ClipEdgeEdits.gd
# Node-free edge-edit rules for clip instances, shared by the arranger's TimelineClip and the clip
# editor's ClipStrip: left/right edge resize held back by neighbours, MIDI padding, content growth,
# loop length and the single-track move clamp. Callers keep a `snapshot()` taken at gesture start
# and call the resize functions with the total delta from that snapshot, so dragging back undoes.
class_name ClipEdgeEdits extends RefCounted

const NO_RIGHT_LIMIT := 999999999


## The placement of `inst` before an edge gesture. `padding` accumulates the ticks `resize_left`
## adds in front of a MIDI clip's content during the gesture.
static func snapshot(inst: ClipInstance) -> Dictionary:
	return {
		"start": inst.start_ticks,
		"duration": inst.duration_ticks,
		"offset": inst.clip_offset,
		"loop": inst.get_loop_state(),
		"content": inst.clip.content_length_ticks if inst.clip else 0,
		"padding": 0,
	}


## End position of the nearest clip left of `reference_start` on `inst`'s track (0 when none).
static func neighbour_left(inst: ClipInstance, reference_start: int = -1) -> int:
	if inst == null or inst.track == null:
		return 0
	var ref_pos := reference_start if reference_start >= 0 else inst.start_ticks
	var nearest_end := 0
	for other in inst.track.clip_instances:
		if other == inst:
			continue
		var other_end: int = other.start_ticks + other.duration_ticks
		if other_end <= ref_pos and other_end > nearest_end:
			nearest_end = other_end
	return nearest_end


## Start position of the nearest clip right of `reference_end` on `inst`'s track (a huge number
## when none).
static func neighbour_right(inst: ClipInstance, reference_end: int = -1) -> int:
	if inst == null or inst.track == null:
		return NO_RIGHT_LIMIT
	var ref_pos := reference_end if reference_end >= 0 else (inst.start_ticks + inst.duration_ticks)
	var nearest_start := NO_RIGHT_LIMIT
	for other in inst.track.clip_instances:
		if other == inst:
			continue
		if other.start_ticks >= ref_pos and other.start_ticks < nearest_start:
			nearest_start = other.start_ticks
	return nearest_start


## Move the left edge `delta` ticks from where `snap` says it started: start and clip offset move
## together so the content stays put. Held back by the neighbour on the left, by tick 0 and by
## `min_duration`. Past the content start, a MIDI clip is padded. Returns the padding added now.
static func resize_left(inst: ClipInstance, snap: Dictionary, delta: int, min_duration: int) -> int:
	var start: int = snap["start"]
	var new_start := maxi(0, start + delta)
	new_start = maxi(neighbour_left(inst, start), new_start)
	var original_end: int = start + int(snap["duration"])
	var new_duration := maxi(min_duration, original_end - new_start)
	var left_edge_delta := new_start - start
	var new_offset: int = int(snap["offset"]) + left_edge_delta + int(snap["padding"])
	var added := 0
	if new_offset < 0:
		added = -new_offset
		pad_clip(inst, added)
		snap["padding"] = int(snap["padding"]) + added
		new_offset = 0
	inst.set_clip_offset(new_offset)
	inst.set_position(new_start)
	inst.set_duration(new_duration)
	return added


## Move the right edge `delta` ticks from where `snap` says it started: only the length changes,
## held back by the neighbour on the right and by `min_duration`. A MIDI clip grows to fit.
static func resize_right(inst: ClipInstance, snap: Dictionary, delta: int, min_duration: int) -> void:
	var start: int = snap["start"]
	var new_duration := maxi(min_duration, int(snap["duration"]) + delta)
	var original_end: int = start + int(snap["duration"])
	var max_duration := neighbour_right(inst, original_end) - start
	new_duration = mini(new_duration, max_duration)
	new_duration = maxi(min_duration, new_duration)
	inst.set_duration(new_duration)
	extend_clip_to(inst, new_duration, int(snap["content"]))


## Shift a MIDI clip's content forward by `ticks` and lengthen the clip by as much. The caller
## moves the instance back to keep the content where it was. Audio can't be padded.
static func pad_clip(inst: ClipInstance, ticks: int) -> void:
	if inst == null or inst.clip == null:
		return
	var clip := inst.clip
	if clip.type == Clip.ClipType.MIDI:
		for note in clip.midi_notes:
			note.start_tick += ticks
		clip.content_length_ticks += ticks
		for note in clip.midi_notes:
			clip.update_midi_note(note)
	elif clip.type == Clip.ClipType.AUDIO:
		push_warning("[ClipEdgeEdits] Audio clip padding not yet implemented - clamping to 0")


## Grow a MIDI clip's length so the instance's end is inside it, never below `start_length` (so
## dragging the edge back undoes the growth). Audio can't grow, and a looping instance repeats its
## content rather than lengthening it.
static func extend_clip_to(inst: ClipInstance, instance_end_ticks: int, start_length: int) -> void:
	var clip := inst.clip
	if clip == null or clip.type != Clip.ClipType.MIDI or inst.loop_enabled:
		return
	var wanted := maxi(start_length, inst.clip_offset + instance_end_ticks)
	if wanted != clip.content_length_ticks:
		clip.set_content_length(wanted)


## Set a looped instance's loop length (the loop start stays). Past the end of the notes a MIDI
## clip grows (never below `start_content`, so pulling back gives the growth up again); audio stops
## at the end of the file.
static func set_loop_length(inst: ClipInstance, new_length: int, start_content: int) -> void:
	new_length = maxi(1, new_length)
	var clip := inst.clip
	if clip and clip.type == Clip.ClipType.MIDI:
		clip.set_content_length(maxi(start_content, inst.loop_start_ticks + new_length))
	elif clip:
		new_length = mini(new_length, maxi(1, inst.content_end_ticks() - inst.loop_start_ticks))
	inst.set_loop(true, inst.loop_start_ticks, new_length)


## Only the landing spot is checked, so a move may jump over clips into any gap that fits.
## The largest move (in the direction of `delta`, at most `delta` in size) that keeps an instance
## spanning `inst_start`..`inst_start + duration` from overlapping any clip of `track` outside
## `moving`, and from going before tick 0 when `clamp_zero` is set. Returns the clamped delta.
static func clamp_move_on_track(inst_start: int, duration: int, track: Track, moving: Array, delta: int, clamp_zero: bool = true) -> int:
	if delta == 0:
		return 0
	var max_delta := delta
	var inst_end := inst_start + duration
	if track:
		for other in track.clip_instances:
			if moving.has(other):
				continue
			var other_end: int = other.start_ticks + other.duration_ticks
			var proposed_start := inst_start + delta
			var proposed_end := proposed_start + duration
			if proposed_start < other_end and other.start_ticks < proposed_end:
				if delta > 0:
					max_delta = mini(max_delta, other.start_ticks - inst_end)
				else:
					max_delta = maxi(max_delta, -(inst_start - other_end))
	if clamp_zero and inst_start + max_delta < 0:
		max_delta = -inst_start
	return max_delta


## An undo command for the change from `snap` to `inst`'s state now, or null when nothing changed.
static func transform_command(cmd_name: String, inst: ClipInstance, snap: Dictionary) -> Command:
	var content_now: int = inst.clip.content_length_ticks if inst.clip else -1
	if (
		inst.start_ticks == snap["start"]
		and inst.duration_ticks == snap["duration"]
		and inst.clip_offset == snap["offset"]
		and inst.get_loop_state() == snap["loop"]
		and (inst.clip == null or content_now == snap["content"])
	):
		return null
	return ClipInstanceTransformCommand.new(
		cmd_name, inst,
		snap["start"], snap["duration"], snap["offset"],
		inst.start_ticks, inst.duration_ticks, inst.clip_offset,
		snap["loop"], inst.get_loop_state(),
		snap["content"], content_now
	)
