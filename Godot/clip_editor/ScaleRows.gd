# Works out which pitches get a row when Fold to scale is on (spec 026, REQ-008).
#
# Every in-scale pitch 0..127, plus every pitch a note in the visible clips uses, so a
# note on an out-of-scale pitch is never hidden.
class_name ScaleRows extends RefCounted


## Rows for a scale and a set of clips, ascending.
static func rows_for(scale: MusicalScale, clips: Array) -> PackedInt32Array:
	var used := {}
	for clip_like in clips:
		DrumRows.collect_clip_pitches(clip_like, used)
	if scale != null:
		for pitch in range(Midi.MIDI_MIN, Midi.MIDI_MAX + 1):
			if scale.contains(pitch):
				used[pitch] = true
	var out := PackedInt32Array()
	for pitch in used.keys():
		if pitch >= Midi.MIDI_MIN and pitch <= Midi.MIDI_MAX:
			out.append(int(pitch))
	out.sort()
	return out
