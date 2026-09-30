# test_midi_editor_clip_paste.gd
# Headless tests for copy/paste between tracks in the clip editor and the time range
# carrying over: track mode shares one note clipboard between the per-track editors,
# copies in song ticks (not the clip's content ticks), pastes at a carried range start
# into the target track's clips (creating one when there is none), Ctrl+C with nothing
# selected copies the edited clips whole, and the range survives switching tracks and
# opening another clip.
#
# Data models reference autoloads by bare name, so they are loaded with load().
# Run: godot --headless --path Godot -s tests/test_midi_editor_clip_paste.gd -- --test
extends TestBase

const BAR := 3840

var _project_script: GDScript
var _instance_script: GDScript


func suite_name() -> String:
	return "Midi editor clip paste tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	await _test_copy_notes_paste_on_other_track()
	await _test_copy_edited_clips_paste_creates_clip()
	await _test_range_carries_over_to_another_clip()
	await _test_ruler_click_drops_bare_range()


func _typed_instances(instances: Array) -> Array:
	return Array(instances, TYPE_OBJECT, &"RefCounted", _instance_script)


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.ctrl_pressed = true
	event.pressed = true
	return event


func _make_clip_editor() -> Control:
	var editor: Control = load("res://clip_editor/ClipEditor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	await process_frame
	return editor


func _open(editor: Control, instances: Array, multi_track: bool) -> void:
	editor._on_editor_clips_selected(_typed_instances(instances), multi_track)
	editor.visible = true
	await process_frame
	await process_frame


func _add_clip(project: Object, track: Object, start: int, length: int) -> Object:
	var clip: Object = project.create_clip("Clip")
	project.add_clip(clip)
	return track.create_clip_instance(clip, start, length)


## Sorted [clip-content start, pitch] pairs of a clip's notes.
func _notes_of(clip: Object) -> Array:
	var out: Array = []
	for n in clip.midi_notes:
		out.append([n.start_tick, n.note])
	out.sort()
	return out


## Notes selected on track A (clip at bar 2) are copied relative to the range in song
## ticks; after switching to track B the range is still there, and Ctrl+V lands at its
## start in B's clip, at the same song position.
func _test_copy_notes_paste_on_other_track() -> void:
	var editor := await _make_clip_editor()
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")
	var inst_a: Object = _add_clip(project, a.track, BAR, BAR)
	inst_a.clip.add_midi_note(project.allocate_note_id(), 60, 100, 0, 240)
	inst_a.clip.add_midi_note(project.allocate_note_id(), 64, 90, 480, 240)
	var inst_b: Object = _add_clip(project, b.track, 0, 4 * BAR)
	await _open(editor, [inst_a, inst_b], true)

	var midi: Object = editor.midi_editor
	midi.current_track = a.track
	var editor_a: Object = midi.get_active_note_editor()
	editor_a.selection_manager.select_all(editor_a.get_all_visual_notes())
	_assert(editor_a.selection_manager.selected_notes.size() == 2, "setup: both notes on A selected")
	editor_a.handle_key_input(_key(KEY_C))

	var clipboard: Object = editor_a.selection_manager.clipboard
	_assert(clipboard != null and clipboard.notes.size() == 2, "Ctrl+C filled the clipboard")
	if clipboard:
		_assert(clipboard.start_tick == BAR and clipboard.end_tick == BAR + 720,
			"the copied range is in song ticks: %d-%d" % [clipboard.start_tick, clipboard.end_tick])
		var offsets: Array = []
		for n in clipboard.notes:
			offsets.append(n.start_tick)
		offsets.sort()
		_assert(offsets == [0, 480], "notes are relative to the range, not the clip content: %s" % [offsets])

	midi.current_track = b.track
	var editor_b: Object = midi.get_active_note_editor()
	_assert(editor_b == editor_a and midi._editor_track(editor_b) == b.track, "switching tracks rebinds the one editor to B")
	var sm_b: Object = editor_b.selection_manager
	_assert(sm_b.box_selection_start_tick == BAR and sm_b.box_selection_end_tick == BAR + 720,
		"the range carried over to B: %d-%d" % [sm_b.box_selection_start_tick, sm_b.box_selection_end_tick])
	_assert(sm_b.selected_notes.is_empty(), "no notes are selected on B")
	_assert(sm_b.clipboard == clipboard, "B's editor sees the same clipboard")
	_assert(editor._song_to_ruler_ticks(BAR) == BAR, "track mode ruler is song ticks")

	editor_b.handle_key_input(_key(KEY_V))
	_assert(_notes_of(inst_b.clip) == [[BAR, 60], [BAR + 480, 64]],
		"B's clip got the notes at the same song position: %s" % [_notes_of(inst_b.clip)])
	_assert(sm_b.selected_notes.size() == 2, "the pasted notes are selected")
	_assert(_notes_of(inst_a.clip).size() == 2, "A is untouched")

	# Back on A, the range is B's (the pasted span) again.
	midi.current_track = a.track
	var sm_a: Object = midi.get_active_note_editor().selection_manager
	_assert(sm_a.box_selection_start_tick == BAR and sm_a.box_selection_end_tick == BAR + 720,
		"the range carries back to A")

	editor.queue_free()
	await process_frame


## With nothing selected, Ctrl+C copies the edited clip on the active track whole (range =
## the clip's span). On a track with no clip there, Ctrl+V creates one long enough for it.
func _test_copy_edited_clips_paste_creates_clip() -> void:
	var editor := await _make_clip_editor()
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")
	var inst_a: Object = _add_clip(project, a.track, 2 * BAR, 5 * BAR)
	inst_a.clip.add_midi_note(project.allocate_note_id(), 48, 100, 0, 480)
	inst_a.clip.add_midi_note(project.allocate_note_id(), 50, 100, 4 * BAR + 960, 480)
	var inst_b: Object = _add_clip(project, b.track, 0, BAR)
	await _open(editor, [inst_a, inst_b], true)

	var midi: Object = editor.midi_editor
	midi.current_track = a.track
	var editor_a: Object = midi.get_active_note_editor()
	editor_a.selection_manager.clear_selection()
	editor_a.handle_key_input(_key(KEY_C))
	var sm_a: Object = editor_a.selection_manager
	_assert(sm_a.selected_notes.size() == 2, "Ctrl+C with nothing selected selects the clip's notes")
	_assert(sm_a.box_selection_start_tick == 2 * BAR and sm_a.box_selection_end_tick == 7 * BAR,
		"the range is the clip's span: %d-%d" % [sm_a.box_selection_start_tick, sm_a.box_selection_end_tick])
	_assert(sm_a.clipboard.duration_ticks == 5 * BAR, "the clipboard spans the whole clip")

	midi.current_track = b.track
	var editor_b: Object = midi.get_active_note_editor()
	_assert(editor_b.get_paste_tick() == 2 * BAR, "the paste target is the carried range start")
	editor_b.handle_key_input(_key(KEY_V))

	_assert(b.track.clip_instances.size() == 2, "the paste created one clip on B: %d" % b.track.clip_instances.size())
	if b.track.clip_instances.size() == 2:
		var created: Object = null
		for ci in b.track.clip_instances:
			if ci != inst_b:
				created = ci
		_assert(created.start_ticks == 2 * BAR, "the new clip starts at the range: %d" % created.start_ticks)
		_assert(created.duration_ticks >= 5 * BAR, "and is long enough for the span: %d" % created.duration_ticks)
		_assert(_notes_of(created.clip) == [[0, 48], [4 * BAR + 960, 50]],
			"both notes landed in it: %s" % [_notes_of(created.clip)])
	_assert(_notes_of(inst_b.clip).is_empty(), "B's existing clip is untouched")

	editor.queue_free()
	await process_frame


## Clip mode: the range is in the clip's content ticks and survives opening a clip on
## another track that starts elsewhere (converted through song ticks); paste lands there.
func _test_range_carries_over_to_another_clip() -> void:
	var editor := await _make_clip_editor()
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var b: Dictionary = project.create_instrument_track("B")
	var inst_a: Object = _add_clip(project, a.track, BAR, 2 * BAR)
	inst_a.clip.add_midi_note(project.allocate_note_id(), 72, 100, 960, 240)
	var inst_b: Object = _add_clip(project, b.track, 0, 4 * BAR)

	await _open(editor, [inst_a], false)
	var midi: Object = editor.midi_editor
	var ne: Object = midi.get_active_note_editor()
	ne.selection_manager.select_all(ne.get_all_visual_notes())
	_assert(ne.selection_manager.box_selection_start_tick == 960, "clip mode range is in content ticks")
	ne.handle_key_input(_key(KEY_C))

	await _open(editor, [inst_b], false)
	ne = midi.get_active_note_editor()
	var sm: Object = ne.selection_manager
	_assert(sm.box_selection_start_tick == BAR + 960 and sm.box_selection_end_tick == BAR + 1200,
		"the range carried to B's clip at the same song position: %d-%d" % [sm.box_selection_start_tick, sm.box_selection_end_tick])
	_assert(sm.selected_notes.is_empty(), "no stale notes are selected")

	ne.handle_key_input(_key(KEY_V))
	_assert(_notes_of(inst_b.clip) == [[BAR + 960, 72]], "pasted at the carried range start: %s" % [_notes_of(inst_b.clip)])

	# Track mode keeps it as well.
	await _open(editor, [inst_a, inst_b], true)
	midi.current_track = a.track
	sm = midi.get_active_note_editor().selection_manager
	_assert(sm.box_selection_start_tick == BAR + 960 and sm.box_selection_end_tick == BAR + 1200,
		"switching to track mode keeps the range in song ticks: %d-%d" % [sm.box_selection_start_tick, sm.box_selection_end_tick])

	editor.queue_free()
	await process_frame


## A plain ruler click sets the paste cursor, so it drops a bare range that would win over it.
func _test_ruler_click_drops_bare_range() -> void:
	var editor := await _make_clip_editor()
	var project: Object = _project_script.new()
	var a: Dictionary = project.create_instrument_track("A")
	var inst_a: Object = _add_clip(project, a.track, 0, BAR)
	await _open(editor, [inst_a], false)
	var ne: Object = editor.midi_editor.get_active_note_editor()
	ne.selection_manager.set_range(960, 1920)
	_assert(ne.get_paste_tick() == 960, "a bare range is the paste target")
	editor._on_ruler_position_requested(2880)
	_assert(not ne.selection_manager.has_range(), "a plain ruler click clears it")
	_assert(ne.get_paste_tick() == 2880, "the paste then goes to the clicked cursor")
	editor.queue_free()
	await process_frame
