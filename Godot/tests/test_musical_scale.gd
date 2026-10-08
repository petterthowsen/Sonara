# test_musical_scale.gd
# MusicalScale catalogue: pitch classes per type, display names, unknown-id fallback (REQ-001).
# Run: godot --headless --path Godot -s tests/test_musical_scale.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Musical scale"


func run_tests() -> void:
	_test_c_pitch_classes()
	_test_examples()
	_test_membership()
	_test_display_names()
	_test_unknown_falls_back()


func _pcs(root: int, type_id: String) -> Array:
	return Array(MusicalScale.make(root, type_id).pitch_classes())


func _test_c_pitch_classes() -> void:
	var expected := {
		"none": [],
		"major": [0, 2, 4, 5, 7, 9, 11],
		"natural_minor": [0, 2, 3, 5, 7, 8, 10],
		"harmonic_minor": [0, 2, 3, 5, 7, 8, 11],
		"melodic_minor": [0, 2, 3, 5, 7, 9, 11],
		"dorian": [0, 2, 3, 5, 7, 9, 10],
		"phrygian": [0, 1, 3, 5, 7, 8, 10],
		"lydian": [0, 2, 4, 6, 7, 9, 11],
		"mixolydian": [0, 2, 4, 5, 7, 9, 10],
		"locrian": [0, 1, 3, 5, 6, 8, 10],
		"major_pentatonic": [0, 2, 4, 7, 9],
		"minor_pentatonic": [0, 3, 5, 7, 10],
		"blues": [0, 3, 5, 6, 7, 10],
	}
	_assert(MusicalScale.TYPES.size() == expected.size(), "catalogue has 13 types")
	for id in expected:
		_assert(_pcs(0, id) == expected[id], "C %s pitch classes" % id)


func _test_examples() -> void:
	_assert(_pcs(0, "harmonic_minor") == [0, 2, 3, 5, 7, 8, 11], "C Harmonic Minor")
	_assert(_pcs(9, "blues") == [0, 2, 3, 4, 7, 9], "A Blues is A C D D# E G (sorted)")
	_assert(_pcs(2, "dorian") == [0, 2, 4, 5, 7, 9, 11], "D Dorian uses the C major notes")


func _test_membership() -> void:
	var c_major := MusicalScale.make(0, "major")
	_assert(c_major.contains(60) and c_major.contains(72), "C and C an octave up are in C Major")
	_assert(not c_major.contains(61), "C# is not in C Major")
	_assert(c_major.contains(0) and c_major.contains(127 - 7), "contains works at the edges of the range")
	_assert(c_major.is_root(48) and not c_major.is_root(50), "is_root marks only the root pitch class")
	_assert(not MusicalScale.make(0, "none").is_root(60), "none has no root")
	_assert(not MusicalScale.make(0, "none").contains(60), "none contains nothing")


func _test_display_names() -> void:
	_assert(MusicalScale.make(2, "dorian").display_name() == "D Dorian", "D Dorian name")
	_assert(MusicalScale.make(6, "natural_minor").display_name() == "F# Natural Minor", "F# Natural Minor name")
	_assert(MusicalScale.make(5, "none").display_name() == "No scale", "none reads No scale")
	_assert(MusicalScale.label_for("major_pentatonic") == "Major Pentatonic", "label_for")
	_assert(MusicalScale.intervals_for("major") == [0, 2, 4, 5, 7, 9, 11], "intervals_for")


func _test_unknown_falls_back() -> void:
	var s := MusicalScale.make(14, "nonsense")
	_assert(s.type_id == "none" and s.is_none(), "unknown id becomes none")
	_assert(s.root == 2, "root wraps into 0..11")
	_assert(MusicalScale.make(-1, "major").root == 11, "negative root wraps")
	_assert(MusicalScale.intervals_for("nonsense").is_empty(), "unknown intervals empty")
