# test_drum_rows.gd
# Headless tests for LaneLayout (pitch <-> row <-> Y) and DrumRows (the Drum View
# row set). The chromatic cases are the phase-1 safety net: they assert the shared
# layout reproduces the old `(127 - note) * key_height` formula exactly.
# Run: godot --headless --path Godot -s tests/test_drum_rows.gd -- --test
extends TestBase


var _clip_script: GDScript


func suite_name() -> String:
	return "LaneLayout / DrumRows tests"


func run_tests() -> void:
	_clip_script = load("res://data/Clip.gd")
	_test_chromatic_matches_old_formula()
	_test_chromatic_roundtrip()
	_test_chromatic_step()
	_test_folded_rows()
	_test_folded_geometry()
	_test_folded_step()
	_test_drum_rows()


# --- chromatic -------------------------------------------------------------

func _test_chromatic_matches_old_formula() -> void:
	for height in [8.0, 12.0, 20.0, 33.5]:
		var layout := LaneLayout.chromatic(height)
		var ok := true
		for note in 128:
			if not is_equal_approx(layout.pitch_to_y(note), (127.0 - note) * height):
				ok = false
				break
		_assert(ok, "chromatic pitch_to_y == (127 - note) * %s for all 128 pitches" % height)
	var l := LaneLayout.chromatic(20.0)
	_assert(is_equal_approx(l.total_height(), 128 * 20.0), "chromatic total_height covers 128 rows")
	_assert(not l.is_folded(), "a fresh layout is chromatic")
	_assert(l.row_count() == 128, "chromatic row_count is 128")


func _test_chromatic_roundtrip() -> void:
	var layout := LaneLayout.chromatic(16.0)
	var ok := true
	for note in 128:
		# Sample inside the lane: top edge, middle and just above the bottom edge.
		var y_top := layout.pitch_to_y(note)
		if layout.y_to_pitch(y_top) != note: ok = false
		if layout.y_to_pitch(layout.pitch_to_y_center(note)) != note: ok = false
		if layout.y_to_pitch(y_top + 15.9) != note: ok = false
	_assert(ok, "chromatic y_to_pitch inverts pitch_to_y across each lane")
	_assert(layout.y_to_pitch(-500.0) == 127, "y above the top clamps to 127")
	_assert(layout.y_to_pitch(99999.0) == 0, "y below the bottom clamps to 0")
	_assert(layout.row_of_pitch(127) == 0, "pitch 127 is the top row")
	_assert(layout.row_of_pitch(0) == 127, "pitch 0 is the bottom row")
	_assert(layout.pitch_at_row(0) == 127 and layout.pitch_at_row(127) == 0, "pitch_at_row inverts row_of_pitch")
	_assert(layout.row_of_pitch(128) == -1 and layout.row_of_pitch(-1) == -1, "out-of-range pitches have no row")


func _test_chromatic_step() -> void:
	var layout := LaneLayout.chromatic()
	_assert(layout.step_pitch(60, 1) == 61, "chromatic step up is a semitone")
	_assert(layout.step_pitch(60, -12) == 48, "chromatic step down by an octave")
	_assert(layout.step_pitch(127, 1) == 127, "chromatic step saturates at the top")
	_assert(layout.step_pitch(0, -1) == 0, "chromatic step saturates at the bottom")


# --- folded ----------------------------------------------------------------

func _folded(pitches: Array) -> LaneLayout:
	var layout := LaneLayout.new()
	layout.row_height = 20.0
	layout.set_rows(PackedInt32Array(pitches))
	return layout


func _test_folded_rows() -> void:
	var layout := _folded([42, 36, 38])
	_assert(layout.is_folded(), "set_rows folds the layout")
	_assert(layout.row_count() == 3, "three rows")
	_assert(layout.rows() == PackedInt32Array([36, 38, 42]), "set_rows sorts ascending")
	# Lowest pitch at the bottom, so row 0 (the top) is the highest pitch.
	_assert(layout.pitch_at_row(0) == 42, "top row is the highest pitch")
	_assert(layout.pitch_at_row(2) == 36, "bottom row is the lowest pitch")
	_assert(layout.row_of_pitch(38) == 1, "middle pitch is the middle row")
	_assert(layout.row_of_pitch(37) == -1, "hidden pitch has no row")
	_assert(layout.row_of_pitch(50) == -1, "pitch above every row is hidden")
	_assert(not layout.is_visible_pitch(37), "is_visible_pitch agrees with row_of_pitch")

	var deduped := _folded([36, 36, 38, 38, 38])
	_assert(deduped.rows() == PackedInt32Array([36, 38]), "set_rows de-duplicates")

	# An empty Drum View must stay folded with no rows, not spring back to the
	# 128 chromatic lanes (REQ-023's hint would never show otherwise).
	var cleared := _folded([36, 38])
	cleared.set_rows(PackedInt32Array())
	_assert(cleared.is_folded(), "an empty row set stays folded")
	_assert(cleared.row_count() == 0, "and has no rows")
	_assert(is_equal_approx(cleared.total_height(), 0.0), "and no height")
	_assert(cleared.pitch_at_row(0) == -1, "and no pitch at any row")
	cleared.set_chromatic()
	_assert(not cleared.is_folded() and cleared.row_count() == 128,
		"set_chromatic brings the 128 lanes back")


func _test_folded_geometry() -> void:
	var layout := _folded([36, 38, 42])
	_assert(is_equal_approx(layout.pitch_to_y(42), 0.0), "top row starts at y 0")
	_assert(is_equal_approx(layout.pitch_to_y(38), 20.0), "middle row at one row height")
	_assert(is_equal_approx(layout.pitch_to_y(36), 40.0), "bottom row at two row heights")
	_assert(is_equal_approx(layout.total_height(), 60.0), "total_height covers three rows only")
	_assert(layout.y_to_pitch(10.0) == 42, "y inside the top row reads back the top pitch")
	_assert(layout.y_to_pitch(50.0) == 36, "y inside the bottom row reads back the bottom pitch")
	_assert(layout.y_to_pitch(9999.0) == 36, "y below the rows clamps to the lowest pitch")
	_assert(layout.y_to_pitch(-10.0) == 42, "y above the rows clamps to the highest pitch")


func _test_folded_step() -> void:
	var layout := _folded([36, 38, 42])
	_assert(layout.step_pitch(38, 1) == 42, "stepping up walks to the next row, not the next semitone")
	_assert(layout.step_pitch(38, -1) == 36, "stepping down walks to the previous row")
	_assert(layout.step_pitch(42, 1) == 42, "stepping saturates at the top row")
	_assert(layout.step_pitch(36, -1) == 36, "stepping saturates at the bottom row")
	_assert(layout.step_pitch(36, 2) == 42, "stepping by two rows skips the middle")


# --- DrumRows --------------------------------------------------------------

## A Clip carrying notes on `pitches`. Clip.gd references autoloads by bare name,
## so it is loaded with load() rather than named by class (as in
## test_multi_out_devices.gd) - naming it would break this script's compilation.
func _clip(pitches: Array) -> Object:
	var clip: Object = _clip_script.new()
	var id := 1
	for p in pitches:
		clip.add_midi_note(id, int(p), 100, 0, 240)
		id += 1
	return clip


func _test_drum_rows() -> void:
	var map := NoteMap.new()
	map.set_entry(36, "Kick", Color.RED)
	map.set_entry(38, "Snare", Color.BLUE)
	map.set_entry(42, "Hat", Color.GREEN)

	# REQ-016's worked example: mapped {36, 38, 42} plus notes on 38 and 50.
	var rows := DrumRows.rows_for(map, [_clip([38, 50])])
	_assert(rows == PackedInt32Array([36, 38, 42, 50]),
		"REQ-016: rows are mapped union used, ascending: %s" % str(rows))

	_assert(DrumRows.rows_for(map, []) == PackedInt32Array([36, 38, 42]),
		"REQ-016: with no clips, rows are just the mapped pitches")
	_assert(DrumRows.rows_for(null, [_clip([60, 60, 55])]) == PackedInt32Array([55, 60]),
		"REQ-016: with no map, rows are the used pitches, de-duplicated")
	_assert(DrumRows.rows_for(NoteMap.new(), []).is_empty(),
		"REQ-023: an unmapped channel with an empty clip has no rows")

	# REQ-024: two tracks mapped {36} and {38} give rows [36, 38].
	var a := NoteMap.new()
	a.set_entry(36, "Kick", Color.RED)
	var b := NoteMap.new()
	b.set_entry(38, "Snare", Color.BLUE)
	var union := DrumRows.rows_for_many([
		{"map": a, "clips": []},
		{"map": b, "clips": []},
	])
	_assert(union == PackedInt32Array([36, 38]), "REQ-024: rows are the union across tracks: %s" % str(union))

	var union_with_notes := DrumRows.rows_for_many([
		{"map": a, "clips": [_clip([50])]},
		{"map": b, "clips": [_clip([36])]},
	])
	_assert(union_with_notes == PackedInt32Array([36, 38, 50]),
		"REQ-024: the union covers used pitches from every track: %s" % str(union_with_notes))
