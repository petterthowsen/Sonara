# test_chord_theory.gd
# Spec 048 REQ-033/034/036: ChordTheory. Progression parser, diatonic chords (Major, Natural Minor,
# Harmonic Minor, a pentatonic scale), voicing inside a range (Close, Spread, Smooth) and chord
# root detection for every quality and inversion.
#
# Run: godot --headless --path Godot -s tests/test_chord_theory.gd -- --test
extends TestBase

const CLOSE := ChordTheory.Voicing.CLOSE
const SPREAD := ChordTheory.Voicing.SPREAD


func suite_name() -> String:
	return "Chord theory"


func run_tests() -> void:
	_test_parser()
	_test_chord_tones()
	_test_voicing_examples()
	_test_voicing_ranges()
	_test_narrow_range_clamps()
	_test_smooth()
	_test_detect_root_examples()
	_test_detect_root_all_qualities()


func _pcs(arr: PackedInt32Array) -> Array:
	return Array(arr)


func _degrees(parsed: Dictionary) -> Array:
	var out := []
	for s: Dictionary in parsed.steps:
		out.append(s.degree)
	return out


func _test_parser() -> void:
	var p := ChordTheory.parse_progression("I V vi IV")
	_assert(p.error == "" and _degrees(p) == [0, 4, 5, 3], "I V vi IV parses to degrees 0 4 5 3")
	_assert(not p.steps[0].seventh, "no 7 means a triad")
	var dashes := ChordTheory.parse_progression("ii7-V7-I")
	_assert(dashes.error == "" and _degrees(dashes) == [1, 4, 0], "dashes separate chords")
	_assert(dashes.steps[0].seventh and dashes.steps[1].seventh and not dashes.steps[2].seventh, "7 marks seventh chords")
	var mixed := ChordTheory.parse_progression("  i  Iv, V -  vII ")
	_assert(mixed.error == "" and _degrees(mixed) == [0, 3, 4, 6], "mixed case, runs of separators and commas")
	_assert(ChordTheory.parse_progression("v").steps[0].degree == ChordTheory.parse_progression("V").steps[0].degree,
			"v and V are the same degree")
	var bad := ChordTheory.parse_progression("I V bVII IV")
	_assert(bad.error != "" and bad.bad_token == "bVII" and bad.error.contains("bVII") and bad.steps.is_empty(),
			"an invalid token is named and no steps are returned")
	for token in ["VIII", "iiii", "7", "IIV", "V/V", "I7x"]:
		_assert(ChordTheory.parse_progression("I " + token).bad_token == token, "'%s' is rejected" % token)
	_assert(ChordTheory.parse_progression("").error != "", "an empty progression is an error")
	_assert(ChordTheory.parse_progression(" - ").error != "", "only separators is an error")
	_assert(not ChordTheory.PRESETS.is_empty(), "there are presets")
	var all_ok := true
	for preset: Dictionary in ChordTheory.PRESETS:
		all_ok = all_ok and ChordTheory.parse_progression(preset.text).error == ""
	_assert(all_ok, "every preset parses")


func _test_chord_tones() -> void:
	var c_major := MusicalScale.make(0, "major")
	_assert(_pcs(ChordTheory.chord_tones(c_major, 1)) == [2, 5, 9], "ii in C Major is D F A")
	_assert(_pcs(ChordTheory.chord_tones(c_major, 0, true)) == [0, 4, 7, 11], "I7 in C Major is C E G B")
	_assert(_pcs(ChordTheory.chord_tones(c_major, 6)) == [11, 2, 5], "vii in C Major is B D F")
	var a_minor := MusicalScale.make(9, "natural_minor")
	_assert(_pcs(ChordTheory.chord_tones(a_minor, 4, true)) == [4, 7, 11, 2], "V7 in A Natural Minor is E G B D")
	_assert(_pcs(ChordTheory.chord_tones(a_minor, 0)) == [9, 0, 4], "i in A Natural Minor is A C E")
	var a_harm := MusicalScale.make(9, "harmonic_minor")
	_assert(_pcs(ChordTheory.chord_tones(a_harm, 4)) == [4, 8, 11], "V in A Harmonic Minor is E G# B")
	var c_pent := MusicalScale.make(0, "major_pentatonic")
	_assert(_pcs(ChordTheory.chord_tones(c_pent, 0)) == [0, 4, 9], "pentatonic: degree 0 stacks every other of 5 notes: C E A")
	_assert(_pcs(ChordTheory.chord_tones(c_pent, 6)) == [2, 7, 0], "pentatonic: degree 6 wraps mod 5 to D, then G C")
	_assert(ChordTheory.chord_tones(MusicalScale.make(0, "none"), 0).is_empty(), "no scale gives no chord")
	# Rotation matters: D Dorian must start its chords from D, not from the lowest pitch class.
	var d_dorian := MusicalScale.make(2, "dorian")
	_assert(_pcs(ChordTheory.chord_tones(d_dorian, 0)) == [2, 5, 9], "I in D Dorian is D F A")


func _test_voicing_examples() -> void:
	var c_major := ChordTheory.chord_tones(MusicalScale.make(0, "major"), 0)
	var range := Vector2i(48, 72)
	_assert(_pcs(ChordTheory.voice(c_major, 0, range, CLOSE)) == [48, 52, 55], "Close root position: C2 E2 G2 from the range floor")
	_assert(_pcs(ChordTheory.voice(c_major, 1, range, CLOSE)) == [52, 55, 60], "Close first inversion: E G C")
	_assert(_pcs(ChordTheory.voice(c_major, 2, range, CLOSE)) == [55, 60, 64], "Close second inversion: G C E")
	_assert(_pcs(ChordTheory.voice(c_major, 0, range, SPREAD)) == [48, 55, 64], "Spread: root, fifth, third an octave up")
	var c7 := ChordTheory.chord_tones(MusicalScale.make(0, "major"), 0, true)
	_assert(_pcs(ChordTheory.voice(c7, 0, range, SPREAD)) == [48, 55, 64, 71], "Spread seventh chord: 2nd and 4th tones up an octave")
	var ex := ChordTheory.voice_ex(c_major, 0, range, CLOSE)
	_assert(not ex.clamped, "a chord that fits is not flagged")


func _test_voicing_ranges() -> void:
	var scales := [MusicalScale.make(0, "major"), MusicalScale.make(9, "natural_minor"), MusicalScale.make(2, "dorian")]
	var ranges: Array[Vector2i] = [Vector2i(48, 72), Vector2i(36, 48 + 12), Vector2i(60, 96), Vector2i(0, 24), Vector2i(100, 127)]
	var bad := 0
	var checked := 0
	for scale: MusicalScale in scales:
		for degree in 7:
			for seventh in [false, true]:
				var tones := ChordTheory.chord_tones(scale, degree, seventh)
				for range in ranges:
					for voicing in [CLOSE, SPREAD]:
						for inversion in tones.size():
							checked += 1
							var r := ChordTheory.voice_ex(tones, inversion, range, voicing)
							for p in r.pitches:
								if p < range.x or p > range.y:
									bad += 1
							if r.pitches.size() != tones.size():
								bad += 1
	_assert(bad == 0, "every voiced note lies in its range across %d voicing combinations (%d bad)" % [checked, bad])
	# Smooth too, chained through a whole progression.
	bad = 0
	var c_major := MusicalScale.make(0, "major")
	for range in ranges:
		var prev := PackedInt32Array()
		for degree in [0, 3, 4, 0, 5, 1]:
			var r := ChordTheory.smooth_next_ex(prev, ChordTheory.chord_tones(c_major, degree), range, SPREAD)
			for p in r.pitches:
				if p < range.x or p > range.y:
					bad += 1
			prev = r.pitches
	_assert(bad == 0, "Smooth keeps every note in range too (%d bad)" % bad)


func _test_narrow_range_clamps() -> void:
	var tones := ChordTheory.chord_tones(MusicalScale.make(0, "major"), 0)
	var r := ChordTheory.voice_ex(tones, 0, Vector2i(60, 64), CLOSE)
	_assert(r.clamped, "a range too narrow for the chord sets clamped")
	var in_range := true
	for p in r.pitches:
		in_range = in_range and p >= 60 and p <= 64
	_assert(in_range, "clamped notes still land inside the range")
	# Fits only by folding down: Spread near the ceiling is flagged but repaired.
	var high := ChordTheory.voice_ex(tones, 2, Vector2i(48, 62), CLOSE)
	_assert(high.clamped or high.pitches[high.pitches.size() - 1] <= 62, "a chord running past the ceiling is folded or flagged")


func _test_smooth() -> void:
	var c_major := MusicalScale.make(0, "major")
	var range := Vector2i(48, 72)
	var degrees := [0, 3, 4, 0]  # I IV V I
	var root_chords := []
	var smooth_chords := []
	var prev := PackedInt32Array()
	for d in degrees:
		var tones := ChordTheory.chord_tones(c_major, d)
		root_chords.append(ChordTheory.voice(tones, 0, range, CLOSE))
		var next := ChordTheory.smooth_next(prev, tones, range, CLOSE)
		smooth_chords.append(next)
		prev = next
	var root_move := ChordTheory.total_movement(root_chords)
	var smooth_move := ChordTheory.total_movement(smooth_chords)
	_assert(smooth_move < root_move, "I IV V I: Smooth moves less (%d) than Root position (%d)" % [smooth_move, root_move])
	_assert(_pcs(smooth_chords[0]) == [48, 52, 55] or smooth_chords[0].size() == 3, "the first Smooth chord is a plain triad")
	_assert(ChordTheory.smooth_next(PackedInt32Array(), ChordTheory.chord_tones(c_major, 0), range) \
			== ChordTheory.voice(ChordTheory.chord_tones(c_major, 0), 0, range), "with no previous chord Smooth is root position")
	# Chords of different sizes: a triad after a seventh chord pads with the nearest note.
	var seventh := ChordTheory.voice(ChordTheory.chord_tones(c_major, 0, true), 0, range)
	var tri := ChordTheory.smooth_next(seventh, ChordTheory.chord_tones(c_major, 4), range)
	_assert(tri.size() == 3, "Smooth between a 7th chord and a triad works")


func _test_detect_root_examples() -> void:
	_assert(ChordTheory.detect_root(PackedInt32Array([64, 67, 72])) == 0, "E3 G3 C4 (C major, first inversion) -> C")
	_assert(ChordTheory.detect_root(PackedInt32Array([60, 64, 67, 69])) == 0, "C3 E3 G3 A3 (C6) -> C, not A minor 7")
	_assert(ChordTheory.detect_root(PackedInt32Array([60, 61, 62])) == 0, "an unmatched cluster returns the lowest note")
	_assert(ChordTheory.detect_root(PackedInt32Array([62, 61, 63])) == 1, "the lowest note of an unmatched cluster, any order")
	_assert(ChordTheory.detect_root(PackedInt32Array()) == -1, "no notes -> -1")
	_assert(ChordTheory.detect_root(PackedInt32Array([67])) == 7, "a lone note is its own root")
	_assert(ChordTheory.detect_root(PackedInt32Array([60, 64])) == 0, "C E (fifth missing) -> C")
	_assert(ChordTheory.detect_root(PackedInt32Array([60, 64, 70])) == 0, "C E Bb (C7 without the fifth) -> C")
	_assert(ChordTheory.detect_root(PackedInt32Array([48, 60, 64, 67, 76])) == 0, "doublings across octaves are fine")
	# Am7 in root position still reads as A (only the major-sixth shape is the C6 exception).
	_assert(ChordTheory.detect_root(PackedInt32Array([57, 60, 64, 67])) == 9, "A2 C3 E3 G3 -> A")


## Every quality, every root, root position and every inversion. Two documented exceptions:
## symmetric chords (augmented, dim7) cannot tell their root, so an inversion reads as its bass;
## and the first inversion of a minor 7th is the major-sixth shape, which reads as its bass (C6).
func _test_detect_root_all_qualities() -> void:
	var qualities := {
		"maj": [0, 4, 7], "min": [0, 3, 7], "dim": [0, 3, 6], "aug": [0, 4, 8],
		"maj7": [0, 4, 7, 11], "7": [0, 4, 7, 10], "m7": [0, 3, 7, 10], "m7b5": [0, 3, 6, 10], "dim7": [0, 3, 6, 9],
	}
	var wrong := []
	var count := 0
	for quality: String in qualities:
		var shape: Array = qualities[quality]
		for root in 12:
			for inversion in shape.size():
				var pitches := PackedInt32Array()
				for i in shape.size():
					var interval: int = shape[(inversion + i) % shape.size()]
					var p := 48 + root + interval
					# Tones after the wrap-around sit an octave up so the bass really is lowest.
					if (inversion + i) >= shape.size():
						p += 12
					pitches.append(p)
				var bass_pc := posmod(pitches[0], 12)
				var expected := root
				if inversion > 0 and (quality == "aug" or quality == "dim7"):
					expected = bass_pc
				if quality == "m7" and inversion == 1:
					expected = bass_pc
				count += 1
				var got := ChordTheory.detect_root(pitches)
				if got != expected:
					wrong.append("%s root %d inv %d: got %d want %d" % [quality, root, inversion, got, expected])
	if not wrong.is_empty():
		print("  ", wrong.slice(0, 8))
	_assert(wrong.is_empty(), "root detection for 9 qualities x 12 roots x all inversions (%d cases, %d wrong)" % [count, wrong.size()])
