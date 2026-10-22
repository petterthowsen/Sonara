## Make Legato and Merge Same Notes (issue #169). Pure static note math on one clip's notes at
## a time (clip ticks), plus whole-clip actions that record one undo step (arranger context menu).
## Chords are groups of notes starting within NoteTransforms.STRUM_TOLERANCE_TICKS of each other,
## like in NoteVoices.
class_name NoteLegato extends RefCounted


## Extend every note to the start of the next chord of `notes` so no gap is left. Notes are only
## lengthened, never shortened, and the last chord keeps its length. Returns the number of notes
## changed.
static func make_legato(notes: Array[MidiNoteData]) -> int:
	var groups := NoteTransforms.group_by_start(notes, NoteTransforms.STRUM_TOLERANCE_TICKS)
	var changed := 0
	for i in groups.size() - 1:
		var next_start: int = groups[i + 1][0].start_tick
		for n: MidiNoteData in groups[i]:
			var wanted := next_start - n.start_tick
			if wanted > n.duration_ticks:
				n.duration_ticks = wanted
				changed += 1
	return changed


## Merge consecutive notes of the same pitch whose gap is closed (the next one starts at or before
## the previous one's end) into the first one, which keeps its velocity and release and grows to
## cover both. Returns the notes that were absorbed (the caller removes them from their clip).
static func merge_same(notes: Array[MidiNoteData]) -> Array[MidiNoteData]:
	var by_pitch := {}
	for n: MidiNoteData in notes:
		if not by_pitch.has(n.note):
			by_pitch[n.note] = []
		by_pitch[n.note].append(n)
	var absorbed: Array[MidiNoteData] = []
	for pitch in by_pitch.keys():
		var list: Array = by_pitch[pitch]
		list.sort_custom(func(a: MidiNoteData, b: MidiNoteData): return a.start_tick < b.start_tick)
		var head: MidiNoteData = list[0]
		for i in range(1, list.size()):
			var n: MidiNoteData = list[i]
			if n.start_tick <= head.start_tick + head.duration_ticks:
				head.duration_ticks = maxi(head.duration_ticks, n.start_tick + n.duration_ticks - head.start_tick)
				absorbed.append(n)
			else:
				head = n
	return absorbed


## Make Legato (and, with `merge`, Merge Same Notes after it) on every note of `clips`, as ONE
## undo step. Returns the number of notes changed or removed.
static func apply_to_clips(clips: Array, legato: bool, merge: bool, label: String) -> int:
	if clips.is_empty():
		return 0
	var before := ClipNotesStateCommand.capture_many(clips)
	var count := 0
	for clip: Clip in clips:
		var notes: Array[MidiNoteData] = []
		notes.assign(clip.midi_notes)
		var lengths := {}
		for n in notes:
			lengths[n] = n.duration_ticks
		if legato:
			make_legato(notes)
		if merge:
			for n in merge_same(notes):
				clip.remove_midi_note(n)
				notes.erase(n)
				count += 1
		for n in notes:
			if n.duration_ticks != lengths[n]:
				clip.update_midi_note(n)
				count += 1
	ClipNotesStateCommand.commit_many(label, before)
	return count
