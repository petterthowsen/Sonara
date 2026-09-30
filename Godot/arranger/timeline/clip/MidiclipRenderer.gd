# Draws the MIDI notes of a clip. Audio clips draw through the child WaveformView instead.
class_name MidiclipRenderer extends Control

@export var note_color := Color("#eee")
## Minimum vertical span in semitones so single-pitch loops still fill the clip.
@export var min_pitch_range: int = 12
## Extra semitones above/below when notes already span more than min_pitch_range.
@export var pitch_padding: int = 1
## Notes are never drawn thinner than this. When the clip is too short for one lane per
## semitone, neighbouring pitches are merged into shared lanes.
@export var min_note_height: float = 2.0

var clip_instance : ClipInstance:
	set(c):
		if clip_instance and clip_instance.clip:
			if clip_instance.clip.clip_modified.is_connected(_on_clip_modified):
				clip_instance.clip.clip_modified.disconnect(_on_clip_modified)
		clip_instance = c
		if clip_instance and clip_instance.clip:
			if not clip_instance.clip.clip_modified.is_connected(_on_clip_modified):
				clip_instance.clip.clip_modified.connect(_on_clip_modified)
		queue_redraw()


func _on_clip_modified():
	# TODO: check specifically for MIDI note changes.
	queue_redraw()


func _draw() -> void:
	if clip_instance and clip_instance.clip and clip_instance.clip.type == Clip.ClipType.MIDI:
		_draw_midi()


## Draw MIDI notes in a window of at least one octave around their actual pitches.
func _draw_midi():
	var clip = clip_instance.clip
	if clip.midi_notes.is_empty() or size.y <= 0.0:
		return

	var display := _display_pitch_range(clip.find_lowest_note(), clip.find_highest_note())
	var lowest: int = display.x
	var highest: int = display.y
	var pitch_count := highest - lowest + 1
	# Collapse semitones into fewer lanes when each would be thinner than min_note_height.
	var lane_count := clampi(int(size.y / min_note_height), 1, pitch_count)
	var note_height := size.y / float(lane_count)

	var clip_length_ticks = clip_instance.duration_ticks
	var clip_offset = clip_instance.clip_offset
	var visible_start = clip_offset
	var visible_end = clip_offset + clip_length_ticks

	for note: MidiNoteData in clip.midi_notes:
		var note_end = note.start_tick + note.duration_ticks
		if note_end <= visible_start or note.start_tick >= visible_end:
			continue

		var note_local_start = note.start_tick - clip_offset
		var note_local_end = note_end - clip_offset
		var draw_start = max(note_local_start, 0)
		var draw_end = min(note_local_end, clip_length_ticks)
		var draw_duration = draw_end - draw_start

		var x = remap(draw_start, 0, clip_length_ticks, 0, size.x)
		var w = remap(draw_duration, 0, clip_length_ticks, 0, size.x)
		var y = (highest - note.note) * note_height
		y = clampf(y, 0.0, size.y - note_height)

		draw_rect(Rect2(x, y, w, note_height), note_color, true, -1.0, true)


## Expand [lowest, highest] to at least one octave, centered, clamped to 0–127.
func _display_pitch_range(lowest: int, highest: int) -> Vector2i:
	var lo := mini(lowest, highest)
	var hi := maxi(lowest, highest)
	var span := hi - lo
	if span < min_pitch_range:
		var extra: int = min_pitch_range - span
		var down: int = int(extra / 2)
		lo -= down
		hi += extra - down
	else:
		lo -= pitch_padding
		hi += pitch_padding
	if lo < Midi.MIDI_MIN:
		hi = mini(Midi.MIDI_MAX, hi - lo)
		lo = Midi.MIDI_MIN
	if hi > Midi.MIDI_MAX:
		lo = maxi(Midi.MIDI_MIN, lo - (hi - Midi.MIDI_MAX))
		hi = Midi.MIDI_MAX
	return Vector2i(lo, hi)
