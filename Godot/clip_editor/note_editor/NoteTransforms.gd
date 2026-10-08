## Pure selection-transform math for the MIDI editor (quantize, mirror, strum, scale).
## Static functions on Array[MidiNoteData] with no scene dependency, so they run headless.
## NoteEditor._apply_selection_edit wraps them with history, overlap cuts and engine sync.
class_name NoteTransforms extends RefCounted


## Lowest and highest pitch of `notes` as Vector2i(lo, hi). Vector2i(0, 0) when empty.
static func pitch_bounds(notes: Array[MidiNoteData]) -> Vector2i:
	if notes.is_empty():
		return Vector2i.ZERO
	var lo := 127
	var hi := 0
	for n in notes:
		lo = mini(lo, n.note)
		hi = maxi(hi, n.note)
	return Vector2i(lo, hi)


## Earliest start and latest end of `notes` as Vector2i(start, end). Vector2i(0, 0) when empty.
static func tick_bounds(notes: Array[MidiNoteData]) -> Vector2i:
	if notes.is_empty():
		return Vector2i.ZERO
	var first := notes[0].start_tick
	var last := notes[0].start_tick + notes[0].duration_ticks
	for n in notes:
		first = mini(first, n.start_tick)
		last = maxi(last, n.start_tick + n.duration_ticks)
	return Vector2i(first, last)


## Group notes whose starts lie within `tolerance_ticks` of the group's first note
## (chords). Groups come in start order; notes inside a group keep that order.
static func group_by_start(notes: Array[MidiNoteData], tolerance_ticks: int) -> Array:
	var sorted := notes.duplicate()
	sorted.sort_custom(func(a: MidiNoteData, b: MidiNoteData): return a.start_tick < b.start_tick)
	var groups: Array = []
	var current: Array[MidiNoteData] = []
	for n: MidiNoteData in sorted:
		if not current.is_empty() and n.start_tick - current[0].start_tick > tolerance_ticks:
			groups.append(current)
			current = []
		current.append(n)
	if not current.is_empty():
		groups.append(current)
	return groups


enum QuantizeMode { START, START_AND_END }


## Move each note's start toward the grid: `start + (snap(start) - start) * strength`
## (strength 0..1, 1 = hard snap). START_AND_END moves the end toward the grid the same way,
## so the duration follows (never below one tick). `snap` is a Callable(tick: int) -> int,
## typically GridHelper.snap_ticks. Returns the number of notes that changed.
static func quantize(notes: Array[MidiNoteData], snap: Callable, strength: float,
		mode: QuantizeMode = QuantizeMode.START) -> int:
	var s := clampf(strength, 0.0, 1.0)
	var changed := 0
	for n in notes:
		var old_start := n.start_tick
		var old_duration := n.duration_ticks
		var old_end := old_start + old_duration
		var new_start := maxi(0, old_start + roundi((int(snap.call(old_start)) - old_start) * s))
		var new_end := old_end
		if mode == QuantizeMode.START_AND_END:
			new_end = old_end + roundi((int(snap.call(old_end)) - old_end) * s)
		else:
			new_end = new_start + old_duration
		n.start_tick = new_start
		n.duration_ticks = maxi(1, new_end - new_start)
		if n.start_tick != old_start or n.duration_ticks != old_duration:
			changed += 1
	return changed


## Vertical flip: mirror pitches around the middle of [lo, hi], so `new = lo + hi - note`
## (clamped to 0..127). Applying it twice restores the notes.
static func mirror_pitch(notes: Array[MidiNoteData], lo: int, hi: int) -> void:
	for n in notes:
		n.note = clampi(lo + hi - n.note, 0, 127)


## Horizontal flip: reverse time inside [range_start, range_end]. A note's span is mirrored,
## so `new_start = range_start + range_end - (start + duration)`; durations stay. With
## `use_duration` false (Drum View hits have no length) only the start point is mirrored.
## Starts stop at tick 0. Applying it twice restores the notes while they stay in range.
static func mirror_time(notes: Array[MidiNoteData], range_start: int, range_end: int,
		use_duration: bool = true) -> void:
	for n in notes:
		var length := n.duration_ticks if use_duration else 0
		n.start_tick = maxi(0, range_start + range_end - (n.start_tick + length))


## Notes whose starts lie this close (a 1/64 note) count as one chord for strumming.
const STRUM_TOLERANCE_TICKS := 60

enum StrumDirection { UP, DOWN, ALTERNATE }


## Spread chords into a strum. Chords are groups of notes starting within STRUM_TOLERANCE_TICKS
## of each other; single notes are left alone. Inside a chord the notes are ordered by pitch
## (UP = low first, DOWN = high first, ALTERNATE flips every chord, starting with UP) and the
## i-th note starts `i * spread_ticks` later. Note ends stay put, so the duration shrinks; the
## offset is clamped so a note keeps at least one tick. `velocity_ramp` (-1..1) is added to
## velocity across the strum: 0 for the first note up to the full amount for the last.
## Returns the number of notes that changed.
static func strum(notes: Array[MidiNoteData], spread_ticks: int, direction: StrumDirection,
		velocity_ramp: float = 0.0) -> int:
	var changed := 0
	var chord_index := 0
	for group: Array in group_by_start(notes, STRUM_TOLERANCE_TICKS):
		if group.size() < 2:
			continue
		var ordered := group.duplicate()
		ordered.sort_custom(func(a: MidiNoteData, b: MidiNoteData): return a.note < b.note)
		if direction == StrumDirection.DOWN or (direction == StrumDirection.ALTERNATE and chord_index % 2 == 1):
			ordered.reverse()
		chord_index += 1
		for i in ordered.size():
			var n: MidiNoteData = ordered[i]
			var old_start := n.start_tick
			var old_velocity := n.velocity
			var end := n.start_tick + n.duration_ticks
			var offset := mini(i * maxi(0, spread_ticks), n.duration_ticks - 1)
			n.start_tick = old_start + maxi(0, offset)
			n.duration_ticks = end - n.start_tick
			n.velocity = clampf(n.velocity + velocity_ramp * float(i) / float(ordered.size() - 1),
					MidiNoteData.MIN_VELOCITY, 1.0)
			if n.start_tick != old_start or n.velocity != old_velocity:
				changed += 1
	return changed


## Smallest scale factor at which no note of `durations` shrinks below one tick.
static func min_scale_factor(durations: PackedInt32Array) -> float:
	var shortest := 0
	for d in durations:
		shortest = d if shortest == 0 else mini(shortest, d)
	return 1.0 / float(maxi(1, shortest))


## Stretch the notes like a clip around `anchor`: both starts and ends move to
## `anchor + (tick - anchor) * factor`, so the anchor stays put and gaps scale with the notes.
## `orig_starts` / `orig_durations` (parallel to `notes`) are the snapshot to scale from, so
## repeated calls with a changing factor never accumulate rounding; omit them to scale the
## notes' current values. Starts stop at tick 0 and a note keeps at least one tick.
static func scale(notes: Array[MidiNoteData], anchor: int, factor: float,
		orig_starts: PackedInt32Array = PackedInt32Array(),
		orig_durations: PackedInt32Array = PackedInt32Array()) -> void:
	var from_snapshot := orig_starts.size() == notes.size() and orig_durations.size() == notes.size()
	for i in notes.size():
		var n := notes[i]
		var start := orig_starts[i] if from_snapshot else n.start_tick
		var duration := orig_durations[i] if from_snapshot else n.duration_ticks
		var new_start := maxi(0, anchor + roundi((start - anchor) * factor))
		var new_end := anchor + roundi((start + duration - anchor) * factor)
		n.start_tick = new_start
		n.duration_ticks = maxi(1, new_end - new_start)


# --- Scale math (spec 026). `pcs` is the sorted pitch-class set of the project scale
# (MusicalScale.pitch_classes()). An empty `pcs` means "no scale": every function returns its input.

## All in-scale pitches 0..127 in ascending order.
static func _scale_pitches(pcs: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for p in range(0, 128):
		if pcs.has(p % 12):
			out.append(p)
	return out


## Nearest in-scale pitch to `pitch`. When both neighbours are equally far, `prefer_up` picks the
## one above. An in-scale pitch returns itself. Stays within 0..127.
static func snap_pitch(pitch: int, pcs: PackedInt32Array, prefer_up: bool) -> int:
	if pcs.is_empty():
		return pitch
	var p := clampi(pitch, 0, 127)
	if pcs.has(p % 12):
		return p
	for d in range(1, 13):
		var up := p + d
		var down := p - d
		var up_ok := up <= 127 and pcs.has(up % 12)
		var down_ok := down >= 0 and pcs.has(down % 12)
		if up_ok and down_ok:
			return up if prefer_up else down
		if up_ok:
			return up
		if down_ok:
			return down
	return p


## The in-scale pitch at or below `pitch`. Below the lowest in-scale pitch it returns that lowest
## in-scale pitch instead (so the offset from it is negative).
static func scale_base(pitch: int, pcs: PackedInt32Array) -> int:
	if pcs.is_empty():
		return pitch
	var p := clampi(pitch, 0, 127)
	for q in range(p, -1, -1):
		if pcs.has(q % 12):
			return q
	for q in range(p, 128):
		if pcs.has(q % 12):
			return q
	return p


## Move `pitch` by `steps` scale steps: walk `steps` in-scale pitches from scale_base(pitch) and
## keep the semitone offset above that base. Saturates at the lowest/highest in-scale pitch, and
## the result is clamped to 0..127.
static func step_in_scale(pitch: int, steps: int, pcs: PackedInt32Array) -> int:
	if pcs.is_empty():
		return pitch
	var list := _scale_pitches(pcs)
	var base := scale_base(pitch, pcs)
	var idx := list.find(base)
	if idx < 0:
		return pitch
	var target := clampi(idx + steps, 0, list.size() - 1)
	return clampi(list[target] + (pitch - base), 0, 127)


## Scale steps from scale_base(`from`) to scale_base(`to`). Positive when `to` is higher.
static func scale_steps_between(from: int, to: int, pcs: PackedInt32Array) -> int:
	if pcs.is_empty():
		return 0
	var list := _scale_pitches(pcs)
	return list.find(scale_base(to, pcs)) - list.find(scale_base(from, pcs))


## Move each out-of-scale note to its nearest in-scale pitch, ties going down. Notes whose pitch
## is in `keyswitches` are skipped. Returns how many notes changed.
static func conform_to_scale(notes: Array[MidiNoteData], pcs: PackedInt32Array,
		keyswitches: PackedInt32Array = PackedInt32Array()) -> int:
	if pcs.is_empty():
		return 0
	var changed := 0
	for n in notes:
		if keyswitches.has(n.note):
			continue
		var snapped := snap_pitch(n.note, pcs, false)
		if snapped != n.note:
			n.note = snapped
			changed += 1
	return changed
