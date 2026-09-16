# One source of truth for pitch <-> row <-> Y in the clip editor.
#
# Chromatic mode is the piano roll: 128 rows, row 0 at the top holding pitch 127,
# which reproduces the old `(127 - note) * key_height` formula exactly.
# Folded mode is Drum View: rows are an arbitrary ascending pitch list, lowest at
# the bottom, and every other pitch is hidden.
#
# Held by MidiEditor and handed to VPiano, NoteLanes and each NoteEditor, the same
# way GridHelper is shared between the clip editor views.
class_name LaneLayout extends RefCounted

## Emitted whenever the row set or the row height changes, so views can redraw.
signal changed

const CHROMATIC_ROWS := 128

## Height of one row in pixels.
var row_height := 20.0:
	set(h):
		if not is_equal_approx(row_height, h):
			row_height = h
			changed.emit()

## Ascending pitch list in folded mode.
var _rows := PackedInt32Array()
## Folded (Drum View) rather than chromatic. Tracked separately from `_rows` so a
## Drum View with no rows stays folded instead of springing back to 128 lanes.
var _folded := false


## A chromatic (piano roll) layout. Used as the default by the @tool controls.
static func chromatic(height := 20.0) -> LaneLayout:
	var layout := LaneLayout.new()
	layout.row_height = height
	return layout


## Switch to chromatic mode (all 128 pitches, one row each).
func set_chromatic() -> void:
	if not _folded and _rows.is_empty():
		return
	_folded = false
	_rows = PackedInt32Array()
	changed.emit()


## Switch to folded mode. `pitches` is sorted ascending and de-duplicated here, so
## callers can pass rows in any order. An empty array folds to no rows at all
## (Drum View with nothing to show), not back to chromatic.
func set_rows(pitches: PackedInt32Array) -> void:
	var sorted := PackedInt32Array()
	var seen := {}
	var copy := PackedInt32Array(pitches)
	copy.sort()
	for p in copy:
		if p < Midi.MIDI_MIN or p > Midi.MIDI_MAX or seen.has(p):
			continue
		seen[p] = true
		sorted.append(p)
	if _folded and sorted == _rows:
		return
	_folded = true
	_rows = sorted
	changed.emit()


func is_folded() -> bool:
	return _folded


## The folded row pitches, ascending. Empty in chromatic mode.
func rows() -> PackedInt32Array:
	return PackedInt32Array(_rows)


func row_count() -> int:
	return _rows.size() if is_folded() else CHROMATIC_ROWS


## Pitch shown in `row`, counting from the top. -1 when the row does not exist.
func pitch_at_row(row: int) -> int:
	var count := row_count()
	if row < 0 or row >= count:
		return -1
	if is_folded():
		return _rows[count - 1 - row]
	return Midi.MIDI_MAX - row


## Row a pitch occupies, counting from the top. -1 when the pitch is hidden.
func row_of_pitch(pitch: int) -> int:
	if is_folded():
		var i := _index_of(pitch)
		if i < 0:
			return -1
		return _rows.size() - 1 - i
	if pitch < Midi.MIDI_MIN or pitch > Midi.MIDI_MAX:
		return -1
	return Midi.MIDI_MAX - pitch


func is_visible_pitch(pitch: int) -> bool:
	return row_of_pitch(pitch) >= 0


## Top Y of a pitch's row. Hidden pitches return the Y of the row they would
## border, so callers that forget to check never draw at a wild offset.
func pitch_to_y(pitch: int) -> float:
	var row := row_of_pitch(pitch)
	if row < 0:
		return _nearest_row(pitch) * row_height
	return row * row_height


func pitch_to_y_bottom(pitch: int) -> float:
	return pitch_to_y(pitch) + row_height


func pitch_to_y_center(pitch: int) -> float:
	return pitch_to_y(pitch) + row_height * 0.5


func row_to_y(row: int) -> float:
	return row * row_height


## Row at a Y position, clamped into range. -1 when there are no rows at all
## (an empty Drum View).
func y_to_row(y: float) -> int:
	var count := row_count()
	if count == 0:
		return -1
	if row_height <= 0.0:
		return 0
	return clampi(int(floor(y / row_height)), 0, count - 1)


## Pitch at a Y position, clamped into range.
func y_to_pitch(y: float) -> int:
	return pitch_at_row(y_to_row(y))


func total_height() -> float:
	return row_count() * row_height


## Move `pitch` by `delta` rows, saturating at the ends. In chromatic mode this
## is plain semitone stepping; in folded mode it walks the visible rows (REQ-020).
func step_pitch(pitch: int, delta: int) -> int:
	if not is_folded():
		return clampi(pitch + delta, Midi.MIDI_MIN, Midi.MIDI_MAX)
	if _rows.is_empty():
		return pitch
	var i := _index_of(pitch)
	if i < 0:
		# Hidden pitch: step from the row it would sit between.
		i = _nearest_index(pitch)
		if delta > 0 and _rows[i] > pitch:
			delta -= 1
		elif delta < 0 and _rows[i] < pitch:
			delta += 1
	return _rows[clampi(i + delta, 0, _rows.size() - 1)]


## Index into the ascending row list, or -1.
func _index_of(pitch: int) -> int:
	var i := _rows.bsearch(pitch, true)
	if i < _rows.size() and _rows[i] == pitch:
		return i
	return -1


## Index of the row closest to a hidden pitch.
func _nearest_index(pitch: int) -> int:
	var i := _rows.bsearch(pitch, true)
	if i >= _rows.size():
		return _rows.size() - 1
	if i == 0:
		return 0
	# Prefer the lower-pitched neighbour on a tie, matching the ascending order.
	if pitch - _rows[i - 1] <= _rows[i] - pitch:
		return i - 1
	return i


## Row index (from the top) nearest to a hidden pitch.
func _nearest_row(pitch: int) -> int:
	if not is_folded():
		return clampi(Midi.MIDI_MAX - pitch, 0, CHROMATIC_ROWS - 1)
	if _rows.is_empty():
		return 0
	return _rows.size() - 1 - _nearest_index(pitch)
