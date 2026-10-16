## Voice ranks, voice selection and chord inversion for the MIDI editor (spec 048).
## Pure static math on Array[MidiNoteData], like NoteTransforms. A chord is a group of notes whose
## starts lie within NoteTransforms.STRUM_TOLERANCE_TICKS of the group's first note. Ticks are
## clip ticks, so callers pass the notes of ONE clip at a time.
class_name NoteVoices extends RefCounted

## `select` choices besides 1..n (voice N counted from the top).
const TOP := -1
const BOTTOM := -2


## Chords of `notes` (group_by_start), each sorted by pitch descending (voice 1 first). Notes of
## equal pitch keep their start order.
static func _chords_top_down(notes: Array[MidiNoteData]) -> Array:
	var chords: Array = []
	for group: Array in NoteTransforms.group_by_start(notes, NoteTransforms.STRUM_TOLERANCE_TICKS):
		var ordered := group.duplicate()
		ordered.sort_custom(func(a: MidiNoteData, b: MidiNoteData): return a.note > b.note)
		chords.append(ordered)
	return chords


## Rank of every note inside its chord: note -> Vector2i(from_top, from_bottom), both 1-based.
## A one-note chord is Vector2i(1, 1).
static func ranks(notes: Array[MidiNoteData]) -> Dictionary:
	var out := {}
	for chord: Array in _chords_top_down(notes):
		for i in chord.size():
			out[chord[i]] = Vector2i(i + 1, chord.size() - i)
	return out


## The notes of one voice: TOP, BOTTOM, or N >= 1 counted from the top. A chord with fewer than N
## notes contributes nothing for voice N. Result is in chord (start) order.
static func select(notes: Array[MidiNoteData], which: int) -> Array[MidiNoteData]:
	var out: Array[MidiNoteData] = []
	for chord: Array in _chords_top_down(notes):
		var index := -1
		if which == TOP:
			index = 0
		elif which == BOTTOM:
			index = chord.size() - 1
		elif which >= 1 and which <= chord.size():
			index = which - 1
		if index >= 0:
			out.append(chord[index])
	return out


## Invert every chord of `notes`. Up moves the lowest note up by octaves until it is strictly
## above the chord's highest other note; Down moves the highest note down until it is strictly
## below the lowest other note. One-note chords are left alone, and so is a chord whose moved
## note would leave 0..127. Returns the number of notes moved.
static func invert(notes: Array[MidiNoteData], up: bool) -> int:
	var moved := 0
	for chord: Array in _chords_top_down(notes):
		if chord.size() < 2:
			continue
		# chord is top-down: the last entry is the bottom, the first the top.
		var mover: MidiNoteData = chord[chord.size() - 1] if up else chord[0]
		# With 2+ notes the mover is never the entry its edge is read from.
		var others_edge: int = chord[0].note if up else chord[chord.size() - 1].note
		var target := mover.note
		if up:
			while target <= others_edge:
				target += 12
		else:
			while target >= others_edge:
				target -= 12
		if target < 0 or target > 127:
			continue
		mover.note = target
		moved += 1
	return moved
