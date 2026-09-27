# test_midi_editor_features.gd
# Headless tests for the note editor batch: note ids owned by Clip, track mode placing
# trimmed instances the way they play, notes sounding at a tick (playback keys and
# Alt+right-click chords), Ctrl+drag duplicates, label sizing, and the clip editor's
# ruler regions and clip-relative coordinates.
#
# Data models reference autoloads by bare name, so they are loaded with load().
# Run: godot --headless --path Godot -s tests/test_midi_editor_features.gd -- --test
extends TestBase

var _project_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _note_editor_script: GDScript
var _grid_helper_script: GDScript
var _visual_note_script: GDScript


func suite_name() -> String:
	return "Midi editor feature tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_note_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_visual_note_script = load("res://clip_editor/VisualNote.gd")
	_test_clip_allocates_note_ids()
	_test_project_adopts_clip_ids()
	_test_instance_tick_conversion()
	await _test_track_mode_honours_clip_offset()
	await _test_pitches_sounding_at()
	await _test_duplicate_drag_commits()
	await _test_duplicate_drag_without_move_cancels()
	_test_label_font_size()
	await _test_clip_editor_ruler_regions()


func _typed_instances(instances: Array) -> Array:
	return Array(instances, TYPE_OBJECT, &"RefCounted", _instance_script)


func _test_clip_allocates_note_ids() -> void:
	var clip: Object = _clip_script.new()
	_assert(clip.allocate_note_id() == 1, "an empty standalone clip starts at id 1")
	clip.add_midi_note(7, 60, 100, 0, 240)
	_assert(clip.allocate_note_id() == 8, "a standalone clip hands out one above its highest id")

	var loose: Object = load("res://data/MidiNote.gd").new()
	clip.midi_notes.append(loose)
	clip.ensure_note_ids()
	_assert(loose.id == 8, "ensure_note_ids numbers a note without an id: %d" % loose.id)


func _test_project_adopts_clip_ids() -> void:
	var project: Object = _project_script.new()
	var clip: Object = _clip_script.new()
	clip.add_midi_note(41, 60, 100, 0, 240)
	var loose: Object = load("res://data/MidiNote.gd").new()
	clip.midi_notes.append(loose)
	project.add_clip(clip)
	_assert(loose.id > 41, "adding a clip numbers its id-less notes above its ids: %d" % loose.id)
	var next: int = clip.allocate_note_id()
	_assert(next > loose.id, "the clip then draws from the project counter: %d" % next)
	_assert(project.allocate_note_id() == next + 1, "and the project counter moved with it")


func _test_instance_tick_conversion() -> void:
	var inst: Object = _instance_script.new()
	inst.start_ticks = 3840
	inst.clip_offset = 960
	inst.duration_ticks = 1920
	_assert(inst.content_origin_ticks() == 2880, "content origin is start minus offset")
	_assert(inst.clip_to_song_ticks(960) == 3840, "the first played tick lands on the instance start")
	_assert(inst.song_to_clip_ticks(3840) == 960, "and converts back")
	_assert(inst.plays_clip_span(960, 1200), "a note at the offset plays")
	_assert(not inst.plays_clip_span(0, 480), "a note before the offset is trimmed")
	_assert(not inst.plays_clip_span(2880, 3000), "a note past the window is trimmed")


## Track mode draws each note where its instance plays it and hides trimmed content.
func _test_track_mode_honours_clip_offset() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	var clip: Object = project.create_clip("Riff")
	project.add_clip(clip)
	var inst: Object = pair.track.create_clip_instance(clip, 3840, 1920)
	inst.clip_offset = 960
	clip.add_midi_note(clip.allocate_note_id(), 60, 100, 0, 240)     # trimmed away
	clip.add_midi_note(clip.allocate_note_id(), 62, 100, 960, 240)   # first played note

	var gh: Object = _grid_helper_script.new()
	var editor: Object = _note_editor_script.new()
	editor.set_grid_helper(gh)
	root.add_child(editor)
	editor.bind_to_clips(_typed_instances([inst]), pair.track)
	await process_frame

	var shown: Array = editor.get_all_visual_notes()
	_assert(shown.size() == 1, "only the played note is shown: %d" % shown.size())
	if shown.size() == 1:
		var x: float = shown[0].position.x
		_assert(is_equal_approx(x, gh.ticks_to_pixels(3840)), "it sits at the instance start: %.1f" % x)
	editor.queue_free()
	await process_frame


func _test_pitches_sounding_at() -> void:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	var clip: Object = project.create_clip("Chord")
	project.add_clip(clip)
	var inst: Object = pair.track.create_clip_instance(clip, 0, 3840)
	inst.clip_offset = 480
	inst.duration_ticks = 960
	clip.add_midi_note(clip.allocate_note_id(), 60, 90, 0, 960)
	clip.add_midi_note(clip.allocate_note_id(), 64, 80, 0, 960)
	clip.add_midi_note(clip.allocate_note_id(), 67, 70, 960, 480)

	var editor: Object = _note_editor_script.new()
	editor.set_grid_helper(_grid_helper_script.new())
	root.add_child(editor)
	editor.bind(inst)
	await process_frame

	var at_600: Dictionary = editor.pitches_sounding_at(600)
	_assert(at_600.size() == 2 and at_600.get(60) == 90 and at_600.get(64) == 80,
		"the chord under tick 600 with velocities: %s" % str(at_600))
	_assert(editor.pitches_sounding_at(100).is_empty(), "nothing plays before the clip offset")
	_assert(editor.pitches_sounding_at(100, false).size() == 2, "a preview still hears trimmed notes")
	_assert(editor.pitches_sounding_at(1500).is_empty(), "nothing plays past the instance window")
	editor.queue_free()
	await process_frame


## Clip-mode editor with two notes, both selected. Returns [editor, clip].
func _make_selected_pair() -> Array:
	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	var clip: Object = project.create_clip("Riff")
	project.add_clip(clip)
	var inst: Object = pair.track.create_clip_instance(clip, 0, 7680)
	clip.add_midi_note(clip.allocate_note_id(), 60, 100, 0, 480)
	clip.add_midi_note(clip.allocate_note_id(), 64, 100, 480, 480)

	var editor: Object = _note_editor_script.new()
	var gh: Object = _grid_helper_script.new()
	editor.set_grid_helper(gh)
	root.add_child(editor)
	editor.bind(inst)
	return [editor, clip, gh]


func _test_duplicate_drag_commits() -> void:
	var parts := _make_selected_pair()
	var editor: Object = parts[0]
	var clip: Object = parts[1]
	var gh: Object = parts[2]
	await process_frame
	var notes: Array = editor.get_all_visual_notes()
	editor.selection_manager.select_all(notes)

	var grabbed: Object = notes[0]
	var start: Vector2 = grabbed.position + Vector2(2, 2)
	_assert(editor.start_duplicate_drag(grabbed, start), "duplicating starts")
	_assert(editor.get_pending_duplicates().size() == 2, "one pending duplicate per selected note")
	_assert(clip.midi_notes.size() == 2, "pending duplicates are not in the clip yet")
	_assert(editor.get_all_visual_notes().size() == 2, "pending duplicates are not real notes")

	# One bar to the right, one row up.
	var bar_px: float = gh.ticks_to_pixels(3840)
	editor.update_duplicate_drag(start + Vector2(bar_px, -editor.layout.row_height))
	editor.finish_duplicate_drag()

	_assert(clip.midi_notes.size() == 4, "release writes the duplicates: %d" % clip.midi_notes.size())
	var found := {}
	for n in clip.midi_notes:
		found["%d@%d" % [n.note, n.start_tick]] = true
	_assert(found.has("61@3840") and found.has("65@4320"), "duplicates keep their layout, moved together: %s" % str(found.keys()))
	_assert(editor.selection_manager.selected_notes.size() == 2, "the duplicates end up selected")
	_assert(editor.get_pending_duplicates().is_empty(), "no pending notes remain")
	_assert(editor.interaction_mode == editor.InteractionMode.NONE, "the interaction is over")
	editor.queue_free()
	await process_frame


func _test_duplicate_drag_without_move_cancels() -> void:
	var parts := _make_selected_pair()
	var editor: Object = parts[0]
	var clip: Object = parts[1]
	await process_frame
	var grabbed: Object = editor.get_all_visual_notes()[0]
	editor.start_duplicate_drag(grabbed, grabbed.position)
	_assert(editor.get_pending_duplicates().size() == 1, "an unselected grab duplicates only itself")
	editor.finish_duplicate_drag()
	_assert(clip.midi_notes.size() == 2, "dropping in place adds nothing")
	await process_frame
	_assert(editor.get_children().size() == 2, "the pending visual is gone")
	editor.queue_free()
	await process_frame


func _test_label_font_size() -> void:
	_assert(_visual_note_script.label_font_size_for(40.0) == 16, "full size at tall rows")
	_assert(_visual_note_script.label_font_size_for(20.0) == 12, "scaled down at 20 px rows")
	_assert(_visual_note_script.label_font_size_for(12.0) == 7, "still shown at 12 px rows")
	_assert(_visual_note_script.label_font_size_for(8.0) == 0, "hidden at the smallest rows")


## Clip mode: the ruler is in clip-content ticks and shades the instance's played window.
func _test_clip_editor_ruler_regions() -> void:
	var scene: PackedScene = load("res://clip_editor/ClipEditor.tscn")
	var editor: Control = scene.instantiate()
	root.add_child(editor)
	await process_frame

	var project: Object = _project_script.new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	var clip: Object = project.create_clip("Riff")
	project.add_clip(clip)
	var inst: Object = pair.track.create_clip_instance(clip, 3840, 1920)
	inst.clip_offset = 960

	editor.bound_clip_instance = inst
	editor.midi_editor.bind_to_clip_instance(inst)
	editor._mark_ruler_context_dirty()
	await process_frame
	await process_frame

	var stack: Object = editor.ruler
	_assert(stack.get_script() == load("res://components/RulerStack.gd"), "the clip editor uses the shared ruler stack")
	var regions: Array = stack.beats_ruler.regions
	_assert(regions.size() == 1, "one region for the bound instance: %d" % regions.size())
	if regions.size() == 1:
		_assert(regions[0].start == 960 and regions[0].end == 2880,
			"it spans the played window in clip ticks: %d-%d" % [regions[0].start, regions[0].end])
	_assert(editor._ruler_to_song_ticks(960) == 3840, "ruler ticks convert to song ticks through the instance")
	editor._on_editor_playhead_moved(3840)
	_assert(editor.midi_editor.playhead_ticks == 960, "the playhead lands on the first played tick")

	# Moving the instance refreshes the shading.
	inst.set_clip_offset(0)
	await process_frame
	await process_frame
	regions = stack.beats_ruler.regions
	_assert(regions.size() == 1 and regions[0].start == 0, "regions follow instance edits")
	editor.queue_free()
	await process_frame
