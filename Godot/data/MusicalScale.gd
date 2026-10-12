## A root pitch class plus a scale type id: the project scale (see docs/specs/026-scale-support).
## Pure value, no scene dependency. Type ids are stable strings saved in the project file.
class_name MusicalScale extends RefCounted

## Ordered catalogue (spec 038). `intervals` are semitones above the root. "none" has no intervals.
## Keep ONE ENTRY PER LINE: a cargo test (`catalogue_matches_godot` in note_fx/scale.rs) parses
## this file line by line and compares it with the engine's scale table.
const TYPES: Array[Dictionary] = [
	{"id": "none", "label": "None", "group": "", "intervals": []},
	{"id": "major", "label": "Major", "group": "Common", "intervals": [0, 2, 4, 5, 7, 9, 11]},
	{"id": "natural_minor", "label": "Natural Minor", "group": "Common", "intervals": [0, 2, 3, 5, 7, 8, 10]},
	{"id": "harmonic_minor", "label": "Harmonic Minor", "group": "Common", "intervals": [0, 2, 3, 5, 7, 8, 11]},
	{"id": "melodic_minor", "label": "Melodic Minor", "group": "Common", "intervals": [0, 2, 3, 5, 7, 9, 11]},
	{"id": "dorian", "label": "Dorian", "group": "Common", "intervals": [0, 2, 3, 5, 7, 9, 10]},
	{"id": "phrygian", "label": "Phrygian", "group": "Common", "intervals": [0, 1, 3, 5, 7, 8, 10]},
	{"id": "lydian", "label": "Lydian", "group": "Common", "intervals": [0, 2, 4, 6, 7, 9, 11]},
	{"id": "mixolydian", "label": "Mixolydian", "group": "Common", "intervals": [0, 2, 4, 5, 7, 9, 10]},
	{"id": "locrian", "label": "Locrian", "group": "Common", "intervals": [0, 1, 3, 5, 6, 8, 10]},
	{"id": "major_pentatonic", "label": "Major Pentatonic", "group": "Common", "intervals": [0, 2, 4, 7, 9]},
	{"id": "minor_pentatonic", "label": "Minor Pentatonic", "group": "Common", "intervals": [0, 3, 5, 7, 10]},
	{"id": "blues", "label": "Blues", "group": "Common", "intervals": [0, 3, 5, 6, 7, 10]},
	{"id": "dorian_b2", "label": "Dorian b2", "group": "Melodic Minor Modes", "intervals": [0, 1, 3, 5, 7, 9, 10]},
	{"id": "lydian_augmented", "label": "Lydian Augmented", "group": "Melodic Minor Modes", "intervals": [0, 2, 4, 6, 8, 9, 11]},
	{"id": "lydian_dominant", "label": "Lydian Dominant", "group": "Melodic Minor Modes", "intervals": [0, 2, 4, 6, 7, 9, 10]},
	{"id": "mixolydian_b6", "label": "Mixolydian b6", "group": "Melodic Minor Modes", "intervals": [0, 2, 4, 5, 7, 8, 10]},
	{"id": "half_diminished", "label": "Half-Diminished", "group": "Melodic Minor Modes", "intervals": [0, 2, 3, 5, 6, 8, 10]},
	{"id": "altered", "label": "Altered", "group": "Melodic Minor Modes", "intervals": [0, 1, 3, 4, 6, 8, 10]},
	{"id": "locrian_nat6", "label": "Locrian ♮6", "group": "Harmonic Modes", "intervals": [0, 1, 3, 5, 6, 9, 10]},
	{"id": "ionian_sharp5", "label": "Ionian #5", "group": "Harmonic Modes", "intervals": [0, 2, 4, 5, 8, 9, 11]},
	{"id": "ukrainian_dorian", "label": "Ukrainian Dorian", "group": "Harmonic Modes", "intervals": [0, 2, 3, 6, 7, 9, 10]},
	{"id": "phrygian_dominant", "label": "Phrygian Dominant", "group": "Harmonic Modes", "intervals": [0, 1, 4, 5, 7, 8, 10]},
	{"id": "lydian_sharp2", "label": "Lydian #2", "group": "Harmonic Modes", "intervals": [0, 3, 4, 6, 7, 9, 11]},
	{"id": "harmonic_major", "label": "Harmonic Major", "group": "Harmonic Modes", "intervals": [0, 2, 4, 5, 7, 8, 11]},
	{"id": "double_harmonic", "label": "Double Harmonic", "group": "Exotic", "intervals": [0, 1, 4, 5, 7, 8, 11]},
	{"id": "hungarian_minor", "label": "Hungarian Minor", "group": "Exotic", "intervals": [0, 2, 3, 6, 7, 8, 11]},
	{"id": "hungarian_major", "label": "Hungarian Major", "group": "Exotic", "intervals": [0, 3, 4, 6, 7, 9, 10]},
	{"id": "neapolitan_major", "label": "Neapolitan Major", "group": "Exotic", "intervals": [0, 1, 3, 5, 7, 9, 11]},
	{"id": "neapolitan_minor", "label": "Neapolitan Minor", "group": "Exotic", "intervals": [0, 1, 3, 5, 7, 8, 11]},
	{"id": "persian", "label": "Persian", "group": "Exotic", "intervals": [0, 1, 4, 5, 6, 8, 11]},
	{"id": "enigmatic", "label": "Enigmatic", "group": "Exotic", "intervals": [0, 1, 4, 6, 8, 10, 11]},
	{"id": "whole_tone", "label": "Whole Tone", "group": "Symmetric", "intervals": [0, 2, 4, 6, 8, 10]},
	{"id": "diminished_hw", "label": "Diminished (Half-Whole)", "group": "Symmetric", "intervals": [0, 1, 3, 4, 6, 7, 9, 10]},
	{"id": "diminished_wh", "label": "Diminished (Whole-Half)", "group": "Symmetric", "intervals": [0, 2, 3, 5, 6, 8, 9, 11]},
	{"id": "augmented", "label": "Augmented", "group": "Symmetric", "intervals": [0, 3, 4, 7, 8, 11]},
	{"id": "bebop_dominant", "label": "Bebop Dominant", "group": "Bebop and Blues", "intervals": [0, 2, 4, 5, 7, 9, 10, 11]},
	{"id": "bebop_major", "label": "Bebop Major", "group": "Bebop and Blues", "intervals": [0, 2, 4, 5, 7, 8, 9, 11]},
	{"id": "bebop_dorian", "label": "Bebop Dorian", "group": "Bebop and Blues", "intervals": [0, 2, 3, 4, 5, 7, 9, 10]},
	{"id": "major_blues", "label": "Major Blues", "group": "Bebop and Blues", "intervals": [0, 2, 3, 4, 7, 9]},
	{"id": "spanish_8_tone", "label": "Spanish 8-Tone", "group": "Bebop and Blues", "intervals": [0, 1, 3, 4, 5, 6, 8, 10]},
	{"id": "egyptian", "label": "Egyptian", "group": "Pentatonic and World", "intervals": [0, 2, 5, 7, 10]},
	{"id": "yo", "label": "Yo", "group": "Pentatonic and World", "intervals": [0, 2, 5, 7, 9]},
	{"id": "hirajoshi", "label": "Hirajoshi", "group": "Pentatonic and World", "intervals": [0, 2, 3, 7, 8]},
	{"id": "in_sen", "label": "In Sen", "group": "Pentatonic and World", "intervals": [0, 1, 5, 7, 10]},
	{"id": "iwato", "label": "Iwato", "group": "Pentatonic and World", "intervals": [0, 1, 5, 6, 10]},
	{"id": "kumoi", "label": "Kumoi", "group": "Pentatonic and World", "intervals": [0, 2, 3, 7, 9]},
	{"id": "pelog", "label": "Pelog", "group": "Pentatonic and World", "intervals": [0, 1, 3, 7, 8]},
]

## Group headings, in catalogue order. "none" belongs to no group.
const GROUPS: Array[String] = [
	"Common",
	"Melodic Minor Modes",
	"Harmonic Modes",
	"Exotic",
	"Symmetric",
	"Bebop and Blues",
	"Pentatonic and World",
]

const NONE_ID := "none"

## Root picker labels, index = pitch class. Black keys show both spellings (REQ-004).
const ROOT_LABELS: Array[String] = ["C", "C#/Db", "D", "D#/Eb", "E", "F", "F#/Gb", "G", "G#/Ab", "A", "A#/Bb", "B"]

## Reference major keys that are spelled with flats (REQ-005 tie-break): F Bb Eb Ab Db.
const _FLAT_MAJOR_ROOTS: Array[int] = [5, 10, 3, 8, 1]

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


## Group heading of `id`; "" for "none" and unknown ids.
static func group_for(id: String) -> String:
	var i := _index_of(id)
	return str(TYPES[i]["group"]) if i >= 0 else ""


func is_none() -> bool:
	return intervals_for(type_id).is_empty()


## Sorted pitch classes of the scale; empty for none.
func pitch_classes() -> PackedInt32Array:
	var pcs := PackedInt32Array()
	for iv in intervals_for(type_id):
		pcs.append(posmod(root + iv, 12))
	pcs.sort()
	return pcs


## The scale's pitch classes as a 12-bit mask (bit 0 = C, bit 1 = C#, ...). 0 for none. The
## engine receives this as the project scale (`/project/scale`, spec 027).
func mask() -> int:
	var bits := 0
	for pc in pitch_classes():
		bits |= 1 << pc
	return bits


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
	return "%s %s" % [root_name(), label_for(type_id)]


## True when the key is spelled with flats (REQ-005): the spelling that repeats fewer letter
## names wins; on a tie the reference major key decides. False for none.
func uses_flats() -> bool:
	if is_none():
		return false
	var pcs := pitch_classes()
	var sharp_repeats := _letter_repeats(pcs, Midi.NOTE_NAMES)
	var flat_repeats := _letter_repeats(pcs, Midi.FLAT_NOTE_NAMES)
	if flat_repeats != sharp_repeats:
		return flat_repeats < sharp_repeats
	var ref := root if intervals_for(type_id).has(4) else posmod(root + 3, 12)
	return _FLAT_MAJOR_ROOTS.has(ref)


static func _letter_repeats(pcs: PackedInt32Array, names: Array[String]) -> int:
	var seen := {}
	for pc in pcs:
		seen[names[pc][0]] = true
	return pcs.size() - seen.size()


## Name of pitch class `pitch` (any MIDI note) in the key's spelling: "Bb", "F#".
func note_name(pitch: int) -> String:
	var names := Midi.FLAT_NOTE_NAMES if uses_flats() else Midi.NOTE_NAMES
	return names[posmod(pitch, 12)]


## Root name in the key's spelling ("Eb").
func root_name() -> String:
	return note_name(root)


# --- Spec 038 REQ-007: migration of saved Transpose Scale Type values -------------------------

## The Transpose Scale Type enum before spec 038: 12 entries (no "none"), old order. A normalized
## value was index / 11.
const LEGACY_TYPE_IDS: Array[String] = [
	"major", "natural_minor", "harmonic_minor", "melodic_minor", "dorian", "phrygian",
	"lydian", "mixolydian", "locrian", "major_pentatonic", "minor_pentatonic", "blues",
]


## Map a normalized Transpose Scale Type saved with the 12-entry enum to the same scale's
## normalized value in the current enum (TYPES without "none", index / (count - 1)).
static func migrate_v1_type_norm(norm: float) -> float:
	var old_index := clampi(roundi(norm * float(LEGACY_TYPE_IDS.size() - 1)), 0, LEGACY_TYPE_IDS.size() - 1)
	var new_index := _index_of(LEGACY_TYPE_IDS[old_index]) - 1  # engine enum has no "none"
	var divisor := maxi(TYPES.size() - 2, 1)
	return float(new_index) / float(divisor)
