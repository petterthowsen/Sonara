# Works out which pitches get a row in Drum View.
#
# A row exists for every pitch that is mapped in the effective map or carries at
# least one note in the bound clips (REQ-016). Including used pitches is what
# guarantees no note is ever hidden and silently edited; with several tracks on
# screen the rows are the union across all of them (REQ-024).
class_name DrumRows extends RefCounted


## Rows for one map and a set of clips, ascending.
static func rows_for(map: NoteMap, clips: Array) -> PackedInt32Array:
	var used := {}
	if map:
		for pitch in map.pitches():
			used[int(pitch)] = true
	for clip_like in clips:
		_collect_clip_pitches(clip_like, used)
	return _sorted(used)


## Union of the rows for several (map, clips) pairs — one per note editor when the
## clip editor shows more than one track (REQ-024).
static func rows_for_many(pairs: Array) -> PackedInt32Array:
	var used := {}
	for pair in pairs:
		var map: NoteMap = pair.get("map")
		if map:
			for pitch in map.pitches():
				used[int(pitch)] = true
		for clip_like in pair.get("clips", []):
			_collect_clip_pitches(clip_like, used)
	return _sorted(used)


## Accepts a ClipInstance or a bare Clip, so callers can pass whichever they hold.
## Both are reached duck-typed rather than by class: naming Clip here would pull
## Clip.gd (which references autoloads by bare name) into the compile graph of
## every script that touches DrumRows, headless tests included.
static func _collect_clip_pitches(clip_like: Variant, used: Dictionary) -> void:
	if not (clip_like is Object):
		return
	var clip: Object = clip_like
	# A ClipInstance points at its Clip; a Clip carries the notes itself.
	if not clip.get("midi_notes") is Array:
		clip = clip.get("clip")
		if not (clip is Object):
			return
	var notes: Variant = clip.get("midi_notes")
	if not (notes is Array):
		return
	for note in notes:
		if note:
			used[int(note.note)] = true


static func _sorted(used: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for pitch in used.keys():
		if pitch >= Midi.MIDI_MIN and pitch <= Midi.MIDI_MAX:
			out.append(int(pitch))
	out.sort()
	return out
