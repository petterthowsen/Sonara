# test_key_detect.gd
# Spec 048 REQ-010..012: KeyDetector. Histogram and detection (all 12 transpositions of major and
# natural minor material, the "Not enough notes" thresholds, duration weighting) and `collect`
# (drum-view tracks, muted instances and notes outside the span are left out).
#
# Run: godot --headless --path Godot -s tests/test_key_detect.gd -- --test
extends TestBase

const C_MAJOR_SCALE: Array[int] = [60, 62, 64, 65, 67, 69, 71]
const A_MINOR_SCALE: Array[int] = [69, 71, 72, 74, 76, 77, 79]

var _project_script: GDScript


func suite_name() -> String:
	return "Key detector"


func run_tests() -> void:
	# Loaded at run time: naming Project would compile it before the autoloads exist.
	_project_script = load("res://data/Project.gd")
	_test_histogram()
	_test_all_transpositions()
	_test_thresholds()
	_test_duration_weighting()
	_test_confidence()
	_test_collect()
	_test_spans()
	_test_picker_detect()
	await _test_picker_use_and_undo()
	await _test_key_change_track_detect()


func _note(pitch: int, start: int, dur: int) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	return n


## A tune in the key of C major (scale run plus I IV V I chords) or A natural minor (scale run plus
## i iv v i), moved up `semitones`.
func _material(minor: bool, semitones: int) -> Array[MidiNoteData]:
	var notes: Array[MidiNoteData] = []
	var scale: Array[int] = A_MINOR_SCALE if minor else C_MAJOR_SCALE
	var t := 0
	for p in scale:
		notes.append(_note(p + semitones, t, 480))
		t += 480
	var chords: Array = [[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]
	if minor:
		chords = [[57, 60, 64], [62, 65, 69], [64, 67, 71], [57, 60, 64]]
	for chord: Array in chords:
		for p: int in chord:
			notes.append(_note(p + semitones, t, 1920))
		t += 1920
	return notes


func _test_histogram() -> void:
	var notes: Array[MidiNoteData] = [_note(60, 0, 100), _note(72, 0, 50), _note(61, 0, 10)]
	var h := KeyDetector.histogram(notes)
	_assert(h.size() == 12 and h[0] == 150.0 and h[1] == 10.0, "C3 and C4 share pitch class 0, weighted by duration")
	var flat := KeyDetector.histogram(notes, false)
	_assert(flat[0] == 2.0 and flat[1] == 1.0, "without duration weighting every note counts once")


func _test_all_transpositions() -> void:
	var wrong := 0
	for semitones in 12:
		var major := KeyDetector.detect_notes(_material(false, semitones))
		if not (major.ok and major.root == posmod(0 + semitones, 12) and major.type_id == "major"):
			wrong += 1
			print("  major material +%d -> %s" % [semitones, major])
		var minor := KeyDetector.detect_notes(_material(true, semitones))
		if not (minor.ok and minor.root == posmod(9 + semitones, 12) and minor.type_id == "natural_minor"):
			wrong += 1
			print("  minor material +%d -> %s" % [semitones, minor])
	_assert(wrong == 0, "C major and A minor material are detected at all 12 transpositions (%d wrong)" % wrong)
	var c_major := KeyDetector.detect_notes(_material(false, 0))
	_assert(c_major.confidence in ["High", "Medium", "Low"], "the result carries a confidence label")


func _test_thresholds() -> void:
	var three: Array[MidiNoteData] = [_note(60, 0, 480), _note(64, 480, 480), _note(67, 960, 480)]
	var r := KeyDetector.detect_notes(three)
	_assert(not r.ok and r.reason == "Not enough notes", "3 notes: Not enough notes")
	var four_two_pcs: Array[MidiNoteData] = [_note(60, 0, 480), _note(72, 480, 480),
			_note(67, 960, 480), _note(79, 1440, 480)]
	_assert(not KeyDetector.detect_notes(four_two_pcs).ok, "4 notes on 2 pitch classes: Not enough notes")
	var four: Array[MidiNoteData] = [_note(60, 0, 480), _note(64, 480, 480), _note(67, 960, 480), _note(60, 1440, 480)]
	_assert(KeyDetector.detect_notes(four).ok, "4 notes on 3 pitch classes is enough")
	_assert(not KeyDetector.detect_notes([] as Array[MidiNoteData]).ok, "no notes: Not enough notes")


func _test_duration_weighting() -> void:
	# A long G tonic ringing under many short passing notes that, counted equally, outline C major.
	var notes: Array[MidiNoteData] = [_note(67, 0, 7680), _note(74, 0, 7680), _note(71, 0, 7680)]
	for i in 12:
		notes.append(_note([60, 61, 63, 65, 68, 70][i % 6], 7680 + i * 60, 60))
	var weighted := KeyDetector.detect_notes(notes)
	_assert(weighted.ok and weighted.root == 7 and weighted.type_id == "major",
			"a long G-B-D chord outweighs many short passing notes: G Major (got %s)" % [weighted])
	var counted := KeyDetector.detect(KeyDetector.histogram(notes, false), notes.size())
	_assert(not (counted.root == 7 and counted.type_id == "major"), "counted equally the passing notes would win")


func _test_confidence() -> void:
	var hist := PackedFloat32Array([4, 0, 2, 0, 3, 1, 0, 3, 0, 2, 0, 1])
	var r := KeyDetector.detect(hist, 8)
	_assert(r.ok and r.margin >= 0.0, "a margin is reported")
	var expected := "High" if r.margin >= KeyDetector.HIGH_MARGIN else ("Medium" if r.margin >= KeyDetector.MEDIUM_MARGIN else "Low")
	_assert(r.confidence == expected, "confidence follows the margin thresholds")


## Four instrument tracks over the 3840-tick bars. `a`: a C major clip (bars 1-2) plus an E minor
## clip (bar 3-4). `drums`: drum-view channel with F# material. `muted`: a muted instance.
func _test_collect() -> void:
	var project: Object = _project_script.new()
	var a: Object = project.create_instrument_track("A").track
	var clip_c: Object = project.create_clip("C")
	project.add_clip(clip_c)
	for i in 4:
		clip_c.add_midi_note(project.allocate_note_id(), 60 + [0, 4, 7, 12][i], 0.8, i * 960, 960)
	a.create_clip_instance(clip_c, 0, 3840)
	var clip_e: Object = project.create_clip("E")
	project.add_clip(clip_e)
	for i in 8:
		clip_e.add_midi_note(project.allocate_note_id(), 64 + [0, 2, 3, 5, 7, 8, 10, 12][i], 0.8, i * 480, 480)
	a.create_clip_instance(clip_e, 7680, 3840)

	var all: Array = KeyDetector.collect(project, 0, -1)
	_assert(all.size() == 12, "all 12 notes collected (got %d)" % all.size())
	_assert(all[0][0] == 60 and all[0][1] == 960, "a pair is [pitch, song duration]")

	var first_half: Array = KeyDetector.collect(project, 0, 7680)
	_assert(first_half.size() == 4, "only notes starting before the span end count (got %d)" % first_half.size())
	var second_half: Array = KeyDetector.collect(project, 7680, 11520)
	_assert(second_half.size() == 8 and second_half[0][0] == 64, "the span start excludes earlier notes")
	var cut: Array = KeyDetector.collect(project, 0, 480)
	_assert(cut.size() == 1 and cut[0][1] == 480, "a note running past the span end is cut to it")

	var drums: Dictionary = project.create_instrument_track("Drums")
	drums.channel.set_drum_view(1)
	var clip_d: Object = project.create_clip("D")
	project.add_clip(clip_d)
	clip_d.add_midi_note(project.allocate_note_id(), 66, 0.8, 0, 480)
	drums.track.create_clip_instance(clip_d, 0, 3840)
	_assert(KeyDetector.collect(project, 0, -1).size() == 12, "a drum-view channel's notes are excluded")

	var other: Object = project.create_instrument_track("Muted").track
	var inst: Object = other.create_clip_instance(clip_c, 0, 3840)
	inst.muted = true
	_assert(KeyDetector.collect(project, 0, -1).size() == 12, "a muted instance is excluded")
	inst.muted = false
	_assert(KeyDetector.collect(project, 0, -1).size() == 16, "unmuted it counts again")

	# REQ-011 detection half: the span of the second key change holds only the E-minor clip.
	var pairs: Array = KeyDetector.collect(project, 7680, -1)
	var result := KeyDetector.detect_pairs(pairs)
	_assert(result.ok and result.root == 4 and result.type_id == "natural_minor",
			"detecting over the second key change proposes E Natural Minor (got %s)" % [result])


# --- Detect in the ScalePicker (T-021, REQ-010, REQ-011) ---

const C_MAJOR_RUN: Array[int] = [60, 62, 64, 65, 67, 69, 71, 72, 67, 64, 60]
const E_MINOR_RUN: Array[int] = [64, 66, 67, 69, 71, 72, 74, 76, 71, 67, 64]


func _add_run(project: Object, track: Object, name: String, pitches: Array[int], start: int) -> void:
	var clip: Object = project.create_clip(name)
	project.add_clip(clip)
	for i in pitches.size():
		clip.add_midi_note(project.allocate_note_id(), pitches[i], 0.8, i * 240, 240)
	track.create_clip_instance(clip, start, 3840)


## Bar 1: C major. Key change A at bar 2 (C major again), key change B at bar 3 (E minor material).
## Returns { project, track, a, b } where a and b are the key change ids. The project key is D Dorian
## so that a detected key is never already the current one.
func _key_change_project() -> Dictionary:
	var project: Object = _project_script.new()
	project.set_scale(2, "dorian")
	var track: Object = project.create_instrument_track("Keys").track
	_add_run(project, track, "bar1", C_MAJOR_RUN, 0)
	_add_run(project, track, "bar2", C_MAJOR_RUN, 3840)
	_add_run(project, track, "bar3", E_MINOR_RUN, 7680)
	var a: int = project.key_change_map.add_change(3840, 0, "major")
	var b: int = project.key_change_map.add_change(7680, 0, "major")
	return {"project": project, "track": track, "a": a, "b": b}


func _test_spans() -> void:
	var ctx := _key_change_project()
	var project: Object = ctx.project
	_assert(KeyDetector.span_for_change(project, 0) == Vector2i(0, 3840), "the start key runs up to the first key change")
	_assert(KeyDetector.span_for_change(project, ctx.a) == Vector2i(3840, 7680), "a key change runs up to the next change")
	_assert(KeyDetector.span_for_change(project, ctx.b) == Vector2i(7680, -1), "the last key change runs to the end of the song")
	_assert(KeyDetector.span_for_change(project, 999).x < 0, "an unknown change has no span")
	var empty: Object = _project_script.new()
	_assert(KeyDetector.span_for_change(empty, 0) == Vector2i(0, -1), "without key changes the start key spans the whole song")
	var at_b := KeyDetector.detect_for_change(project, ctx.b)
	_assert(at_b.ok and at_b.root == 4 and at_b.type_id == "natural_minor", "detecting on the second key change proposes E Natural Minor (got %s)" % [at_b])
	var at_start := KeyDetector.detect_for_change(project, 0)
	_assert(at_start.ok and at_start.root == 0 and at_start.type_id == "major", "the start key sees only the notes before the first change: C Major (got %s)" % [at_start])


func _test_picker_detect() -> void:
	var picker: HBoxContainer = load("res://editor/ScalePicker.gd").new()
	_assert(not picker.detect_button.visible, "without a detect source there is no Detect button")
	var ctx := _key_change_project()
	var project: Object = ctx.project
	picker.detect_source = func() -> Dictionary: return KeyDetector.detect_for_change(project, 0)
	_assert(picker.detect_button.visible and not picker.use_button.visible, "a detect source shows Detect, and Use only after a result")
	var picked := []
	picker.scale_picked.connect(func(r, t): picked.append([r, t]))
	picker.detect_button.pressed.emit()
	_assert(picker.result_label.visible and picker.result_label.text.begins_with("C Major ("), "the result shows the key and its confidence (got '%s')" % picker.result_label.text)
	_assert(picker.use_button.visible and not picker.use_button.disabled, "Use is available for a result")
	_assert(picked.is_empty() and project.scale_root == 2 and project.scale_type == "dorian" and picker.display_text() == "No scale",
			"Detect alone changes nothing")
	picker.use_button.pressed.emit()
	_assert(picked == [[0, "major"]] and picker.display_text() == "C Major", "Use picks the detected key through scale_picked")
	_assert(not picker.result_label.visible and not picker.use_button.visible, "the result clears after Use")

	# Not enough notes: nothing to use.
	var empty: Object = _project_script.new()
	picker.detect_source = func() -> Dictionary: return KeyDetector.detect_for_change(empty, 0)
	picker.detect_button.pressed.emit()
	_assert(picker.result_label.text == "Not enough notes" and picker.use_button.disabled, "Not enough notes shows and disables Use")
	picked.clear()
	picker.use_button.pressed.emit()
	_assert(picked.is_empty(), "a disabled Use picks nothing")
	picker.detect_source = Callable()
	_assert(not picker.detect_button.visible and not picker.result_label.visible, "clearing the source hides the Detect row")
	picker.free()


## Use goes through Editor.set_project_scale, which records an undo step.
func _test_picker_use_and_undo() -> void:
	var ctx := _key_change_project()
	var project: Object = ctx.project
	var editor = load("res://editor/Editor.gd").new()
	var sonara: Node = get_root().get_node("Sonara")
	sonara.editor = editor
	editor.project = project
	var picker: HBoxContainer = load("res://editor/ScalePicker.gd").new()
	picker.scale_picked.connect(editor.set_project_scale)
	picker.detect_source = editor._detect_project_key
	picker.detect_button.pressed.emit()
	_assert(project.scale_root == 2 and project.scale_type == "dorian", "Detect through the Editor leaves the project scale alone")
	picker.use_button.pressed.emit()
	_assert(project.scale_root == 0 and project.scale_type == "major", "Use sets the project scale")
	var undo_ok: bool = editor.undo()
	_assert(undo_ok and project.scale_root == 2 and project.scale_type == "dorian", "and it is undoable")
	sonara.editor = null
	picker.free()
	editor.free()
	await process_frame


func _test_key_change_track_detect() -> void:
	var ctx := _key_change_project()
	var project: Object = ctx.project
	var track = load("res://arranger/ruler/KeyChangeTrack.gd").new()
	var grid = load("res://components/GridHelper.gd").new()
	get_root().add_child(track)
	track.set_grid_helper(grid)
	track.bind_project(project)
	var history: Array = []
	load("res://history/HistoryUtil.gd").test_recorder = func(cmd) -> void: history.append(cmd)
	track.open_dropdown(ctx.b, Vector2.ZERO)
	track._picker.detect_button.pressed.emit()
	_assert(track._picker.last_result.ok and track._picker.last_result.root == 4 and track._picker.last_result.type_id == "natural_minor",
			"Detect on the second key change proposes E Natural Minor")
	var c: Dictionary = project.key_change_map.changes[project.key_change_map.index_of(ctx.b)]
	_assert(c["root"] == 0 and c["type_id"] == "major" and history.is_empty(), "the key change is untouched until Use")
	track._picker.use_button.pressed.emit()
	c = project.key_change_map.changes[project.key_change_map.index_of(ctx.b)]
	_assert(c["root"] == 4 and c["type_id"] == "natural_minor" and history.size() == 1, "Use updates the key change as one undo step")
	history.pop_back().undo()
	c = project.key_change_map.changes[project.key_change_map.index_of(ctx.b)]
	_assert(c["root"] == 0 and c["type_id"] == "major", "undo restores it")
	track.open_dropdown(ctx.a, Vector2.ZERO)
	_assert(not track._picker.result_label.visible, "opening another change clears the old result")
	track._picker.detect_button.pressed.emit()
	_assert(track._picker.last_result.root == 0 and track._picker.last_result.type_id == "major", "the first change sees its own span: C Major")
	load("res://history/HistoryUtil.gd").test_recorder = Callable()
	track.queue_free()
	await process_frame
