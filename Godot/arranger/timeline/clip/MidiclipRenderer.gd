# Draws the MIDI notes of a clip. Audio clips draw through the sibling WaveformView instead.
#
# With culling on (the Timeline turns it on for every clip it shows), only the notes inside
# `_window` are drawn: the on-screen part of the clip plus a margin. The Timeline passes the
# on-screen range every frame through show_px_range(), and the clip redraws only when that range
# leaves the window. A clip that is off screen draws nothing, so a zoom (which resizes, and so
# redraws, every clip) costs only what is visible.
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
		_pitch_range_dirty = true
		if clip_instance and clip_instance.clip:
			if not clip_instance.clip.clip_modified.is_connected(_on_clip_modified):
				clip_instance.clip.clip_modified.connect(_on_clip_modified)
		queue_redraw()


## Display pitch window of the notes, recomputed after the clip changes rather than on every
## draw (a zoom redraws every clip).
var _pitch_range := Vector2i.ZERO
var _pitch_range_dirty := true
var _pitch_range_clip: Clip = null  # The clip the cache is for; a retargeted instance recomputes

## Extra range drawn on each side of the on-screen part, as a fraction of its width, so a scroll
## redraws a clip only every so often.
const WINDOW_MARGIN := 1.0
var _culling := false
## Instance-local tick range [x, y) that the last draw covered. Empty (y <= x) draws nothing.
var _window := Vector2i.ZERO


## Draw only the part of the clip that show_px_range() reports on screen. Until the first report
## the clip draws nothing.
func enable_culling() -> void:
	if _culling:
		return
	_culling = true
	_window = Vector2i.ZERO
	queue_redraw()


## The on-screen part of this control, in local pixels (x0 >= x1 when none of it is). Redraws
## only when that part is not already drawn; going off screen just drops the window, leaving the
## stale drawing where it can't be seen, so the next resize draws nothing.
func show_px_range(x0: float, x1: float) -> void:
	if not _culling:
		return
	var duration := clip_instance.duration_ticks if clip_instance else 0
	if size.x <= 0.0 or duration <= 0:
		_window = Vector2i.ZERO
		return
	var t0 := clampi(floori(x0 / size.x * duration), 0, duration)
	var t1 := clampi(ceili(x1 / size.x * duration), 0, duration)
	if t1 <= t0:
		_window = Vector2i.ZERO
		return
	if t0 >= _window.x and t1 <= _window.y:
		return
	var margin := int((t1 - t0) * WINDOW_MARGIN)
	_window = Vector2i(maxi(0, t0 - margin), mini(duration, t1 + margin))
	queue_redraw()


func _on_clip_modified():
	# TODO: check specifically for MIDI note changes.
	_pitch_range_dirty = true
	queue_redraw()


func _draw() -> void:
	if clip_instance and clip_instance.clip and clip_instance.clip.type == Clip.ClipType.MIDI:
		_draw_midi()


## Draw MIDI notes in a window of at least one octave around their actual pitches.
func _draw_midi():
	var clip = clip_instance.clip
	if clip.midi_notes.is_empty() or size.y <= 0.0:
		return

	if _pitch_range_dirty or _pitch_range_clip != clip:
		_pitch_range = _display_pitch_range(clip.find_lowest_note(), clip.find_highest_note())
		_pitch_range_dirty = false
		_pitch_range_clip = clip
	var lowest: int = _pitch_range.x
	var highest: int = _pitch_range.y
	var pitch_count := highest - lowest + 1
	# Collapse semitones into fewer lanes when each would be thinner than min_note_height.
	var lane_count := clampi(int(size.y / min_note_height), 1, pitch_count)
	var note_height := size.y / float(lane_count)

	var clip_length_ticks = clip_instance.duration_ticks
	var clip_offset = clip_instance.clip_offset
	var visible_start = clip_offset
	var visible_end = clip_offset + clip_length_ticks
	if _culling:
		if _window.y <= _window.x:
			return
		visible_start = clip_offset + _window.x
		visible_end = clip_offset + mini(_window.y, clip_length_ticks)

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
