## Layer slot note maps (docs/specs/006-layer-note-mapping): 128 bytes, byte n = the output note
## input note n is sent to, NONE = the slot ignores it. The full map (identity) is the default
## and plays every note, as Layer slots always have.
##
## Pure helpers over PackedByteArray: every function returns a new map and never touches the
## model or the engine. Editing helpers treat a full map as empty first, so the first edit on a
## fresh slot means "only this", not "everything plus this" (REQ-011).
class_name LayerNoteMap extends RefCounted

const SIZE := 128
const NONE := 255
## Distribute lays zoned slots out from C1 upward (REQ-015).
const DISTRIBUTE_START := 36


## Every input note to itself.
static func full() -> PackedByteArray:
	var map := PackedByteArray()
	map.resize(SIZE)
	for i in SIZE:
		map[i] = i
	return map


## No input notes mapped.
static func empty() -> PackedByteArray:
	var map := PackedByteArray()
	map.resize(SIZE)
	map.fill(NONE)
	return map


## True for a 128-byte map whose entries are output notes or NONE.
static func is_valid(map: PackedByteArray) -> bool:
	if map.size() != SIZE:
		return false
	for v in map:
		if v != NONE and v > 127:
			return false
	return true


## True when `map` is the identity map (the slot plays every note unchanged).
static func is_full(map: PackedByteArray) -> bool:
	if map.size() != SIZE:
		return false
	for i in SIZE:
		if map[i] != i:
			return false
	return true


## Mapped input notes, ascending.
static func inputs(map: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in mini(map.size(), SIZE):
		if map[i] != NONE:
			out.append(i)
	return out


## Output note for `input`, or -1 when unmapped.
static func output_of(map: PackedByteArray, input: int) -> int:
	if input < 0 or input >= map.size() or map[input] == NONE:
		return -1
	return map[input]


## Map `input` to `output` (replacing any previous output for that input).
static func connect_note(map: PackedByteArray, input: int, output: int) -> PackedByteArray:
	var out := _editable(map)
	if _in_range(input) and _in_range(output):
		out[input] = output
	return out


## Map `inputs` (in pitch order) one to one onto consecutive outputs from `out_start`.
## Inputs whose output would pass 127 are left as they were.
static func connect_range(map: PackedByteArray, p_inputs: PackedInt32Array, out_start: int) -> PackedByteArray:
	var out := _editable(map)
	var sorted := _sorted_unique(p_inputs)
	for i in sorted.size():
		var output := out_start + i
		if _in_range(sorted[i]) and _in_range(output):
			out[sorted[i]] = output
	return out


## Unmap `inputs`.
static func disconnect_notes(map: PackedByteArray, p_inputs: PackedInt32Array) -> PackedByteArray:
	var out := _editable(map)
	for input in p_inputs:
		if _in_range(input):
			out[input] = NONE
	return out


## Move the mappings of `inputs` by `delta` semitones, keeping their outputs. Moved entries
## replace whatever the slot had at their destinations. Returns `map` unchanged when any moved
## input would leave 0–127.
static func shift(map: PackedByteArray, p_inputs: PackedInt32Array, delta: int) -> PackedByteArray:
	var out := _editable(map)
	var moving: Array[Vector2i] = []  # (input, output)
	for input in _sorted_unique(p_inputs):
		if not _in_range(input) or out[input] == NONE:
			continue
		if not _in_range(input + delta):
			return map.duplicate()
		moving.append(Vector2i(input, out[input]))
	for m in moving:
		out[m.x] = NONE
	for m in moving:
		out[m.x + delta] = m.y
	return out


## "Resolve overlaps" (REQ-014): walk zoned slots in order; a slot overlapping an earlier one is
## shifted as a block by the smallest amount (up on a tie) that clears every earlier slot.
## Full maps are left alone. Returns {maps: Array[PackedByteArray], skipped: Array[int]} where
## skipped lists slots that no shift could place.
static func resolve_overlaps(maps: Array) -> Dictionary:
	var result: Array[PackedByteArray] = []
	var skipped: Array[int] = []
	var occupied := {}
	for index in maps.size():
		var map: PackedByteArray = maps[index]
		if is_full(map):
			result.append(map.duplicate())
			continue
		var ins := inputs(map)
		var delta = _smallest_free_shift(ins, occupied)
		if delta == null:
			skipped.append(index)
			result.append(map.duplicate())
		else:
			result.append(shift(map, ins, delta) if delta != 0 else map.duplicate())
			ins = _shifted(ins, delta)
		for input in ins:
			occupied[input] = true
	return {"maps": result, "skipped": skipped}


## "Distribute" (REQ-015): lay zoned slots out one after another from C1 in slot order, no gaps,
## each keeping its mappings' pitch order and outputs. Full maps are left alone. A slot that
## would run past 127 is left unchanged and listed in `skipped`; later slots still get placed.
static func distribute(maps: Array) -> Dictionary:
	var result: Array[PackedByteArray] = []
	var skipped: Array[int] = []
	var cursor := DISTRIBUTE_START
	for index in maps.size():
		var map: PackedByteArray = maps[index]
		var ins := inputs(map)
		if is_full(map) or ins.is_empty():
			result.append(map.duplicate())
			continue
		if cursor + ins.size() - 1 > 127:
			skipped.append(index)
			result.append(map.duplicate())
			continue
		var out := empty()
		for input in ins:
			out[cursor] = map[input]
			cursor += 1
		result.append(out)
	return {"maps": result, "skipped": skipped}


## Serialize for the project file: null for the full map (key omitted), else 128 ints.
static func to_json(map: PackedByteArray):
	if is_full(map) or not is_valid(map):
		return null
	var out: Array[int] = []
	for v in map:
		out.append(v)
	return out


## Parse a saved map; anything missing or malformed loads as the full map (REQ-016).
static func from_json(data) -> PackedByteArray:
	if not (data is Array) or data.size() != SIZE:
		return full()
	var map := PackedByteArray()
	map.resize(SIZE)
	for i in SIZE:
		var v := int(data[i])
		map[i] = v if (v >= 0 and v <= 127) else NONE
	return map


# ---------------------------------------------------------------------------

static func _editable(map: PackedByteArray) -> PackedByteArray:
	if is_full(map) or map.size() != SIZE:
		return empty()
	return map.duplicate()


static func _in_range(note: int) -> bool:
	return note >= 0 and note <= 127


static func _sorted_unique(values: PackedInt32Array) -> PackedInt32Array:
	var seen := {}
	var out := PackedInt32Array()
	for v in values:
		if not seen.has(v):
			seen[v] = true
			out.append(v)
	out.sort()
	return out


static func _shifted(values: PackedInt32Array, delta: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for v in values:
		out.append(v + delta)
	return out


## Smallest |delta| (positive first) that keeps every input in range and off `occupied`, or null.
static func _smallest_free_shift(ins: PackedInt32Array, occupied: Dictionary):
	if ins.is_empty():
		return 0
	var lo := ins[0]
	var hi := ins[ins.size() - 1]
	for magnitude in range(0, 128):
		for delta in ([magnitude, -magnitude] if magnitude > 0 else [0]):
			if lo + delta < 0 or hi + delta > 127:
				continue
			var clear := true
			for input in ins:
				if occupied.has(input + delta):
					clear = false
					break
			if clear:
				return delta
	return null
