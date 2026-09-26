# test_select_all.gd
# Headless tests for the Ctrl+A selections: every note in the active note editor
# (clip mode: the clip; track mode: the active track) and every clip on the active
# track / on all tracks in the arranger.
#
# Timeline and the data models reference autoloads by bare name, so they are loaded with
# load() inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_select_all.gd -- --test
extends TestBase

var _project_script: GDScript
var _track_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _note_editor_script: GDScript
var _grid_helper_script: GDScript
var _clip_manager_script: GDScript
var _timeline_script: GDScript


func suite_name() -> String:
	return "Select all tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_script = load("res://data/Track.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_note_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_clip_manager_script = load("res://arranger/timeline/ClipSelectionManager.gd")
	_timeline_script = load("res://arranger/timeline/Timeline.gd")
	await _test_ctrl_a_selects_all_notes()
	_test_select_all_on_one_track()
	_test_select_all_across_tracks()
	_test_timeline_select_all_clips()


## A typed array of `instances` (naming ClipInstance in a -s test breaks the class lookup).
func _typed_instances(instances: Array) -> Array:
	return Array(instances, TYPE_OBJECT, &"RefCounted", _instance_script)


func _ctrl_a() -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = KEY_A
	event.ctrl_pressed = true
	event.pressed = true
	return event


## NoteEditor bound to a track with two notes on one clip; Ctrl+A selects both and
## replaces a one-note selection. Returns nothing; frees the editor.
func _test_ctrl_a_selects_all_notes() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	var clip: Object = project.create_clip("Riff")
	project.add_clip(clip)
	var inst: Object = pair.track.create_clip_instance(clip, 0, 3840)

	var editor: Object = _note_editor_script.new()
	editor.set_grid_helper(_grid_helper_script.new())
	root.add_child(editor)
	editor.bind_to_clips(_typed_instances([inst]), pair.track)
	await process_frame

	clip.add_midi_note(project.allocate_note_id(), 60, 100, 0, 240)
	clip.add_midi_note(project.allocate_note_id(), 64, 100, 480, 240)
	await process_frame

	var all_notes: Array = editor.get_all_visual_notes()
	_assert(all_notes.size() == 2, "both notes have visuals: %d" % all_notes.size())
	if all_notes.size() != 2:
		editor.queue_free()
		return

	editor.selection_manager.select_note(all_notes[0])
	_assert(editor.selection_manager.selected_notes.size() == 1, "setup: one note selected")

	editor.handle_key_input(_ctrl_a())

	var manager: Object = editor.selection_manager
	_assert(manager.selected_notes.size() == 2, "Ctrl+A selects every note: %d" % manager.selected_notes.size())
	_assert(manager.box_selection_start_tick == 0, "range starts at the first note: %d" % manager.box_selection_start_tick)
	_assert(manager.box_selection_end_tick == 720, "range ends at the last note: %d" % manager.box_selection_end_tick)

	editor.queue_free()
	await process_frame


## A third instance on another track must not be touched by select_all_on_track.
func _test_select_all_on_one_track() -> void:
	var manager: Object = _clip_manager_script.new()
	var track: Object = _track_script.new(2)
	var other: Object = _track_script.new(3)
	var first: Object = _clip_on(track, 0)
	var second: Object = _clip_on(track, 960)
	_clip_on(other, 0)

	manager.select_all_on_track(track)
	var selected: Array = manager.get_selected_instances()
	_assert(selected.size() == 2, "every clip on the track, once: %d" % selected.size())
	_assert(selected.has(first) and selected.has(second), "both track clips are in the selection")
	_assert(not manager.get_selected_instances().has(other.clip_instances[0]), "the other track is untouched")


func _test_select_all_across_tracks() -> void:
	var manager: Object = _clip_manager_script.new()
	var track: Object = _track_script.new(2)
	var other: Object = _track_script.new(3)
	_clip_on(track, 0)
	_clip_on(track, 960)
	_clip_on(other, 0)

	var tracks := Array([track, other], TYPE_OBJECT, &"RefCounted", _track_script)
	manager.select_all_on_tracks(tracks)
	_assert(manager.get_selected_instances().size() == 3, "all clips on both tracks")
	_assert(manager.get_selection_bounds() == Vector2i(0, 1920), "bounds cover the whole selection")


func _test_timeline_select_all_clips() -> void:
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")
	_add_clip(project, a.track, 0)
	_add_clip(project, b.track, 0)
	_add_clip(project, b.track, 960)

	var timeline: Object = _timeline_script.new()
	timeline.project = project

	timeline.select_all_clips(a.track)
	_assert(timeline.clip_selection_manager.get_selected_instances().size() == 1, "active track only")

	timeline.select_all_clips(b.track)
	_assert(timeline.clip_selection_manager.get_selected_instances().size() == 2, "the new active track replaces it")

	timeline.select_all_clips(null)
	_assert(timeline.clip_selection_manager.get_selected_instances().size() == 3, "null track selects every track")

	timeline.free()


func _clip_on(track: Object, start: int) -> Object:
	var inst: Object = _instance_script.new()
	inst.clip = _clip_script.new()
	inst.start_ticks = start
	inst.duration_ticks = 960
	track.add_clip_instance(inst)
	return inst


func _add_clip(project: Object, track: Object, start: int) -> Object:
	var clip: Object = project.create_clip("Riff")
	project.add_clip(clip)
	return track.create_clip_instance(clip, start, 960)