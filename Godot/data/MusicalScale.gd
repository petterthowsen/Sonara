## A root pitch class plus a scale type id: the project scale (see docs/specs/026-scale-support).
## Pure value, no scene dependency. Type ids are stable strings saved in the project file.
class_name MusicalScale extends RefCounted

## Ordered catalogue. `intervals` are semitones above the root. "none" has no intervals.
const TYPES: Array[Dictionary] = [
	{"id": "none", "label": "None", "intervals": []},
	{"id": "major", "label": "Major", "intervals": [0, 2, 4, 5, 7, 9, 11]},
	{"id": "natural_minor", "label": "Natural Minor", "intervals": [0, 2, 3, 5, 7, 8, 10]},
	{"id": "harmonic_minor", "label": "Harmonic Minor", "intervals": [0, 2, 3, 5, 7, 8, 11]},
	{"id": "melodic_minor", "label": "Melodic Minor", "intervals": [0, 2, 3, 5, 7, 9, 11]},
	{"id": "dorian", "label": "Dorian", "intervals": [0, 2, 3, 5, 7, 9, 10]},
	{"id": "phrygian", "label": "Phrygian", "intervals": [0, 1, 3, 5, 7, 8, 10]},
	{"id": "lydian", "label": "Lydian", "intervals": [0, 2, 4, 6, 7, 9, 11]},
	{"id": "mixolydian", "label": "Mixolydian", "intervals": [0, 2, 4, 5, 7, 9, 10]},
	{"id": "locrian", "label": "Locrian", "intervals": [0, 1, 3, 5, 6, 8, 10]},
	{"id": "major_pentatonic", "label": "Major Pentatonic", "intervals": [0, 2, 4, 7, 9]},
	{"id": "minor_pentatonic", "label": "Minor Pentatonic", "intervals": [0, 3, 5, 7, 10]},
	{"id": "blues", "label": "Blues", "intervals": [0, 3, 5, 6, 7, 10]},
]

const NONE_ID := "none"

## Pitch class 0..11 (0 = C).
var root: int = 0
var type_id: String = NONE_ID


## Build a scale. An unknown type id becomes "none"; the root wraps into 0..11.
static func make(p_root: int, p_type_id: String) -> MusicalScale:
	var s := MusicalScale.new()
	s.root = posmod(p_root, 12)
	s.type_id = p_type_id if _index_of(p_type_id) >= 0 else NONE_ID
	return s


static func is_valid_type(id: String) -> bool:
	return _index_of(id) >= 0


static func _index_of(id: String) -> int:
	for i in TYPES.size():
		if TYPES[i]["id"] == id:
			return i
	return -1


## Semitone offsets above the root for `id`. Empty for "none" and unknown ids.
static func intervals_for(id: String) -> Array[int]:
	var out: Array[int] = []
	var i := _index_of(id)
	if i >= 0:
		for v in TYPES[i]["intervals"]:
			out.append(int(v))
	return out


## Menu label for `id` ("Natural Minor"). Unknown ids read as "None".
static func label_for(id: String) -> String:
	var i := _index_of(id)
	return str(TYPES[i]["label"]) if i >= 0 else str(TYPES[0]["label"])


func is_none() -> bool:
	return intervals_for(type_id).is_empty()


## Sorted pitch classes of the scale; empty for none.
func pitch_classes() -> PackedInt32Array:
	var pcs := PackedInt32Array()
	for iv in intervals_for(type_id):
		pcs.append(posmod(root + iv, 12))
	pcs.sort()
	return pcs


## True when `pitch`'s pitch class belongs to the scale. Always false for none.
func contains(pitch: int) -> bool:
	return pitch_classes().has(posmod(pitch, 12))


## True when `pitch` has the root's pitch class and a scale is set.
func is_root(pitch: int) -> bool:
	return not is_none() and posmod(pitch, 12) == root


## "D Dorian", or "No scale" for none.
func display_name() -> String:
	if is_none():
		return "No scale"
	return "%s %s" % [Midi.NOTE_NAMES[root], label_for(type_id)]
