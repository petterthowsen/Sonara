# ClipScaleActions.gd
# Scales the time axis of MIDI clips ("Scale Half" / "Scale Double" in the clip context menu):
# note starts and lengths, the clip's content length, and every instance of the clip (duration,
# content offset and loop region) so each one keeps showing the same music.
class_name ClipScaleActions extends RefCounted

## Shortest note length a scale leaves behind, in ticks.
const MIN_NOTE_TICKS := 1


## Scale `clips` (MIDI source clips) by `factor` as one undo step named `action_name`.
## `all_instances` are the instances to scale along with them (those of other clips are ignored);
## a clip's instances all scale because the clip data is shared. Instance start positions stay,
## and a longer instance is cut off where the next instance on its track starts (the clip content
## still scales, so the instance can be stretched again). Existing arranger moves and pastes
## refuse overlaps rather than resolve them; a bulk scale cannot refuse, so it clamps.
static func scale_clips(action_name: String, clips: Array[Clip], all_instances: Array,
		factor: float) -> void:
	if clips.is_empty() or factor <= 0.0 or is_equal_approx(factor, 1.0):
		return
	var before := ClipNotesStateCommand.capture_many(clips)
	var old_lengths := {}
	for clip: Clip in clips:
		old_lengths[clip] = clip.content_length_ticks
	var transforms: Array[Command] = []
	for inst: ClipInstance in all_instances:
		if inst == null or not clips.has(inst.clip):
			continue
		var cmd := _instance_command(inst, old_lengths[inst.clip], factor)
		cmd.new_duration = mini(cmd.new_duration, _room_before_next(inst, cmd.new_duration))
		cmd.do()
		transforms.append(cmd)
	for clip: Clip in clips:
		scale_notes(clip, factor)
		clip.set_content_length(_scaled(old_lengths[clip], factor))
	ClipNotesStateCommand.commit_many(action_name, before, [], transforms)


## Scale note starts and lengths of `clip`. Note ends are rounded, not lengths, so back-to-back
## notes stay back to back; no note gets shorter than MIN_NOTE_TICKS.
static func scale_notes(clip: Clip, factor: float) -> void:
	for note: MidiNoteData in clip.midi_notes:
		var start := roundi(note.start_tick * factor)
		var end := roundi(note.get_end_tick() * factor)
		note.start_tick = start
		note.duration_ticks = maxi(MIN_NOTE_TICKS, end - start)
	_trim_same_pitch_overlaps(clip)
	for note: MidiNoteData in clip.midi_notes:
		clip.update_midi_note(note)


## Shorten notes that now run into the next note of the same pitch (halving can do this when
## the minimum length kicked in). Notes starting at the same tick are left alone.
static func _trim_same_pitch_overlaps(clip: Clip) -> void:
	var by_pitch := {}
	for note: MidiNoteData in clip.midi_notes:
		if not by_pitch.has(note.note):
			by_pitch[note.note] = []
		by_pitch[note.note].append(note)
	for pitch in by_pitch:
		var list: Array = by_pitch[pitch]
		list.sort_custom(func(a: MidiNoteData, b: MidiNoteData) -> bool: return a.start_tick < b.start_tick)
		for i in list.size() - 1:
			var gap: int = list[i + 1].start_tick - list[i].start_tick
			if gap >= MIN_NOTE_TICKS and list[i].duration_ticks > gap:
				list[i].duration_ticks = gap


## The longest `wanted` can be before the instance runs into the next instance on its track
## (the one starting after it). Instances without a track, or with no later neighbour, keep it.
static func _room_before_next(inst: ClipInstance, wanted: int) -> int:
	if inst.track == null:
		return wanted
	var room := wanted
	for other: ClipInstance in inst.track.clip_instances:
		if other != inst and other.start_ticks > inst.start_ticks:
			room = mini(room, other.start_ticks - inst.start_ticks)
	return maxi(1, room)


static func _instance_command(inst: ClipInstance, old_length: int, factor: float) -> ClipInstanceTransformCommand:
	var loop_start := roundi(inst.loop_start_ticks * factor)
	return ClipInstanceTransformCommand.new(
		"Scale Clip", inst,
		inst.start_ticks, inst.duration_ticks, inst.clip_offset,
		inst.start_ticks, _scaled(inst.duration_ticks, factor), roundi(inst.clip_offset * factor),
		inst.get_loop_state(), [inst.loop_enabled, loop_start, _scaled(inst.loop_length_ticks, factor)],
		old_length, _scaled(old_length, factor))


static func _scaled(ticks: int, factor: float) -> int:
	return maxi(1, roundi(ticks * factor))
