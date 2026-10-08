# test_note_strum.gd
# Strum (plan 2d): pure NoteTransforms.strum math and NoteEditor.strum_selection
# (one undo step, note ends stay put).
#
# Run: godot --headless --path Godot -s tests/test_note_strum.gd -- --test
extends TestBase

const UP := NoteTransforms.StrumDirection.UP
const DOWN := NoteTransforms.StrumDirection.DOWN
const ALTERNATE := NoteTransforms.StrumDirection.ALTERNATE

var _project_script: GDScript
var _editor_script: GDScript
var _grid_helper_script: GDScript


func suite_name() -> String:
	return "Note strum"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_test_chord_up()
	_test_chord_down()
	_test_two_chords_alternate()
	_test_single_note_unchanged()
	_test_clamp_on_short_note()
	_test_velocity_ramp()
	await _test_editor_strum_is_one_undo_step()
	await _test_track_mode_instances_one_undo_step()


func _note(pitch: int, start: int, dur: int) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	return n


func _chord(start: int) -> Array[MidiNoteData]:
	# Deliberately out of pitch order.
	return [_note(67, start, 960), _note(60, start, 960), _note(64, start, 960)]


func _test_chord_up() -> void:
	var c := _chord(0)
	NoteTransforms.strum(c, 30, UP)
	_assert(c[1].start_tick == 0 and c[2].start_tick == 30 and c[0].start_tick == 60, "up: low note first, then every 30 ticks")
	_assert(c[0].start_tick + c[0].duration_ticks == 960 and c[2].start_tick + c[2].duration_ticks == 960, "note ends stay put")


func _test_chord_down() -> void:
	var c := _chord(0)
	NoteTransforms.strum(c, 30, DOWN)
	_assert(c[0].start_tick == 0 and c[2].start_tick == 30 and c[1].start_tick == 60, "down: high note first")


func _test_two_chords_alternate() -> void:
	var a := _chord(0)
	var b := _chord(1920)
	var all: Array[MidiNoteData] = []
	all.append_array(a)
	all.append_array(b)
	var changed := NoteTransforms.strum(all, 20, ALTERNATE)
	_assert(a[1].start_tick == 0 and a[0].start_tick == 40, "first chord strums up")
	_assert(b[0].start_tick == 1920 and b[1].start_tick == 1960, "second chord strums down")
	_assert(changed == 4, "the first note of each chord does not move (4 of 6 changed)")


func _test_single_note_unchanged() -> void:
	var n: Array[MidiNoteData] = [_note(60, 100, 500)]
	var changed := NoteTransforms.strum(n, 50, UP, 0.5)
	_assert(changed == 0 and n[0].start_tick == 100 and n[0].duration_ticks == 500, "a lone note is untouched")


func _test_clamp_on_short_note() -> void:
	var c: Array[MidiNoteData] = [_note(60, 0, 100), _note(64, 0, 100), _note(67, 0, 5)]
	NoteTransforms.strum(c, 50, UP)
	_assert(c[2].start_tick == 4 and c[2].duration_ticks == 1, "offset is clamped so the note keeps one tick")
	_assert(c[1].start_tick == 50 and c[1].duration_ticks == 50, "longer notes are not clamped")


func _test_velocity_ramp() -> void:
	var c := _chord(0)
	for n in c:
		n.velocity = 0.5
	NoteTransforms.strum(c, 10, UP, 0.4)
	_assert(is_equal_approx(c[1].velocity, 0.5) and is_equal_approx(c[2].velocity, 0.7) and is_equal_approx(c[0].velocity, 0.9), "velocity ramps across the strum")


func _test_editor_strum_is_one_undo_step() -> void:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Riff")
	var a: Object = clip.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 960, 480)
	var b: Object = clip.add_midi_note(project.allocate_note_id(), 64, MidiNoteData.from_midi_velocity(100), 960, 480)
	var ed = _editor_script.new()
	ed.set_grid_helper(_grid_helper_script.new())
	root.add_child(ed)
	var instances := Array([track.create_clip_instance(clip, 0, 7680)], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	ed.bind_to_clips(instances, track)
	await process_frame
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed.strum_selection()
	history_util.test_recorder = Callable()
	_assert(a.start_tick == 960 and b.start_tick == 990, "strum offsets the upper note by the default spread (30 ticks)")
	_assert(b.start_tick + b.duration_ticks == 1440, "the strummed note keeps its end")
	_assert(recorded.size() == 1, "strum is one undo step")
	recorded[0].undo()
	_assert(b.start_tick == 960 and b.duration_ticks == 480, "undo restores the chord")


## Track mode: two instances of one clip (shared notes) plus an instance of another clip.
## Shared notes are strummed once, and the whole selection is one undo step.
func _test_track_mode_instances_one_undo_step() -> void:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip_a: Object = project.create_clip("A")
	var a1: Object = clip_a.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 0, 480)
	var a2: Object = clip_a.add_midi_note(project.allocate_note_id(), 64, MidiNoteData.from_midi_velocity(100), 0, 480)
	var clip_b: Object = project.create_clip("B")
	var b1: Object = clip_b.add_midi_note(project.allocate_note_id(), 60, MidiNoteData.from_midi_velocity(100), 0, 480)
	var b2: Object = clip_b.add_midi_note(project.allocate_note_id(), 64, MidiNoteData.from_midi_velocity(100), 0, 480)
	var ed = _editor_script.new()
	ed.set_grid_helper(_grid_helper_script.new())
	root.add_child(ed)
	var instances := Array([
		track.create_clip_instance(clip_a, 0, 1920),
		track.create_clip_instance(clip_a, 1920, 1920),
		track.create_clip_instance(clip_b, 3840, 1920),
	], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	ed.bind_to_clips(instances, track)
	await process_frame
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed.strum_selection()
	history_util.test_recorder = Callable()
	_assert(a2.start_tick == 30, "a note shared by two instances is strummed once (30, not 60)")
	_assert(b2.start_tick == 30, "a note of another clip is strummed in the same edit")
	_assert(recorded.size() == 1, "a multi-clip selection is one undo step")
	recorded[0].undo()
	_assert(a2.start_tick == 0 and b2.start_tick == 0 and a2.duration_ticks == 480, "undo restores every clip")
	recorded[0].do()
	_assert(a2.start_tick == 30 and b2.start_tick == 30, "redo strums every clip again")
