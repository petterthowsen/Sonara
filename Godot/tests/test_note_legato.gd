# test_note_legato.gd
# Issue #169: Make Legato and Merge Same Notes (NoteLegato math, the Note Editor tools, the
# arranger clip context menu), Split to Tracks from the arranger, and the Transfer dialog's
# hierarchical target tree. Every tool is one undo step.
#
# Run: godot --headless --path Godot -s tests/test_note_legato.gd -- --test
extends TestBase

const BAR := 3840

var _project_script: GDScript
var _editor_script: GDScript
var _grid_helper_script: GDScript
var _recorded: Array = []
# Loaded at run time: naming these classes would compile the autoloads they use before they exist.
var _legato: GDScript
var _split: GDScript
var _dialog_script: GDScript


func suite_name() -> String:
	return "Make Legato, Merge Same Notes, hierarchical Transfer targets"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_legato = load("res://clip_editor/harmony/NoteLegato.gd")
	_split = load("res://clip_editor/harmony/NoteSplitActions.gd")
	_dialog_script = load("res://clip_editor/harmony/TransferNotesDialog.gd")
	_test_legato_math()
	_test_merge_math()
	await _test_editor_legato()
	await _test_editor_merge()
	await _test_menu_actions()
	await _test_arranger_split()
	await _test_dialog_tree()


func _record_start() -> void:
	_recorded.clear()
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: _recorded.append(cmd)


func _record_stop() -> void:
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = Callable()


## [start, note, duration] triples, sorted, to compare note lists.
func _state(clip: Object) -> Array:
	var out := []
	for n: MidiNoteData in clip.midi_notes:
		out.append([n.start_tick, n.note, n.duration_ticks])
	out.sort()
	return out


func _note(pitch: int, start: int, dur: int) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = start
	n.duration_ticks = dur
	return n


func _typed(list: Array) -> Array[MidiNoteData]:
	var out: Array[MidiNoteData] = []
	out.assign(list)
	return out


func _test_legato_math() -> void:
	var a := _note(60, 0, 100)
	var b := _note(64, 0, 200)
	var c := _note(62, 960, 100)
	var d := _note(65, 2000, 100)
	var changed: int = _legato.make_legato(_typed([a, b, c, d]))
	_assert(a.duration_ticks == 960 and b.duration_ticks == 960, "a chord's notes reach the next chord")
	_assert(c.duration_ticks == 1040, "a note reaches the start of the next note")
	_assert(d.duration_ticks == 100, "the last note keeps its length")
	_assert(changed == 3, "three notes were lengthened (got %d)" % changed)
	var long := _note(60, 0, 2000)
	var after := _note(62, 480, 100)
	_legato.make_legato(_typed([long, after]))
	_assert(long.duration_ticks == 2000, "legato never shortens a note")


func _test_merge_math() -> void:
	var a := _note(60, 0, 480)
	a.velocity = 0.9
	a.release = 0.2
	var b := _note(60, 480, 480)
	b.velocity = 0.3
	var c := _note(60, 1200, 240)  # gap: stays
	var d := _note(62, 480, 480)  # other pitch: stays
	var absorbed: Array = _legato.merge_same(_typed([c, b, d, a]))
	_assert(absorbed == [b], "the touching same-pitch note is absorbed")
	_assert(a.duration_ticks == 960 and is_equal_approx(a.velocity, 0.9) and is_equal_approx(a.release, 0.2),
			"the first note spans both and keeps its velocity and release")
	_assert(c.duration_ticks == 240 and d.duration_ticks == 480, "notes with a gap or another pitch are untouched")
	var x := _note(60, 0, 100)
	var y := _note(60, 100, 100)
	var z := _note(60, 200, 100)
	_legato.merge_same(_typed([x, y, z]))
	_assert(x.duration_ticks == 300, "a run of touching notes merges into one")


func _rig(notes: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Pad")
	project.add_clip(clip)
	for t: Array in notes:
		clip.add_midi_note(project.allocate_note_id(), t[0], 0.8, t[1], t[2])
	var ed = _editor_script.new()
	ed.set_grid_helper(_grid_helper_script.new())
	root.add_child(ed)
	var inst: Object = track.create_clip_instance(clip, 0, 4 * BAR)
	ed.bind_to_clips(Array([inst], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd")), track)
	await process_frame
	return {"project": project, "track": track, "clip": clip, "ed": ed, "inst": inst}


func _test_editor_legato() -> void:
	var ctx := await _rig([[60, 0, 240], [62, 480, 240], [64, 1920, 240]])
	var ed = ctx.ed
	var clip: Object = ctx.clip
	var before := _state(clip)
	_assert(ed.make_legato_selection() == 0, "nothing happens without a selection")
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_record_start()
	var changed: int = ed.make_legato_selection()
	_record_stop()
	_assert(changed == 2, "two notes were lengthened (got %d)" % changed)
	_assert(_state(clip) == [[0, 60, 480], [480, 62, 1440], [1920, 64, 240]], "gaps close up to the next note")
	_assert(_recorded.size() == 1, "Make Legato is one undo step")
	var after := _state(clip)
	_recorded[0].undo()
	_assert(_state(clip) == before, "undo restores the lengths")
	_recorded[0].do()
	_assert(_state(clip) == after, "redo applies legato again")
	ed.queue_free()


func _test_editor_merge() -> void:
	var ctx := await _rig([[60, 0, 480], [60, 480, 480], [60, 960, 480], [62, 1440, 480], [60, 2400, 240]])
	var ed = ctx.ed
	var clip: Object = ctx.clip
	var first: MidiNoteData = clip.midi_notes[0]
	first.velocity = 0.6
	first.release = 0.25
	var before := _state(clip)
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_record_start()
	var absorbed: int = ed.merge_same_notes_selection()
	_record_stop()
	_assert(absorbed == 2, "two notes were absorbed (got %d)" % absorbed)
	_assert(_state(clip) == [[0, 60, 1440], [1440, 62, 480], [2400, 60, 240]], "touching notes merge, the rest stays")
	_assert(clip.midi_notes.has(first) and is_equal_approx(first.velocity, 0.6) and is_equal_approx(first.release, 0.25),
			"the merged note keeps the first note's velocity and release")
	_assert(_recorded.size() == 1, "Merge Same Notes is one undo step")
	var after := _state(clip)
	_recorded[0].undo()
	_assert(_state(clip) == before, "undo brings the merged notes back")
	_recorded[0].do()
	_assert(_state(clip) == after, "redo merges again")
	ed.queue_free()


func _open_menu() -> Object:
	var scene: PackedScene = load("res://arranger/timeline/ClipContextMenu.tscn")
	var menu = scene.instantiate()
	root.add_child(menu)
	await process_frame
	return menu


func _bind(menu: Object, instances: Array) -> void:
	var typed := Array([], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	for inst in instances:
		typed.append(inst)
	menu.bind_to_instances(typed)


func _test_menu_actions() -> void:
	var ctx := await _rig([[60, 0, 240], [60, 240, 240], [62, 960, 240]])
	ctx.ed.queue_free()
	var clip: Object = ctx.clip
	var menu := await _open_menu()
	_bind(menu, [ctx.inst])
	_assert(not menu.make_legato.disabled and not menu.merge_same.disabled, "legato and merge are enabled for a MIDI clip")
	var before := _state(clip)
	_record_start()
	menu.make_legato.pressed.emit()
	_record_stop()
	_assert(_state(clip) == [[0, 60, 240], [240, 60, 720], [960, 62, 240]], "Make Legato lengthens the clip's notes")
	_assert(_recorded.size() == 1, "context menu Make Legato is one undo step")
	_recorded[0].undo()
	_assert(_state(clip) == before, "undo restores the clip")
	_record_start()
	menu.merge_same.pressed.emit()
	_record_stop()
	_assert(_state(clip) == [[0, 60, 480], [960, 62, 240]], "Merge Same Notes merges the touching notes")
	_assert(_recorded.size() == 1, "context menu Merge Same Notes is one undo step")
	_recorded[0].undo()
	_assert(_state(clip) == before, "undo restores the merged notes")
	menu.queue_free()


func _test_arranger_split() -> void:
	var project: Object = _project_script.new()
	var src: Object = project.create_instrument_track("Src").track
	var other: Object = project.create_instrument_track("Other").track
	var clip: Object = project.create_clip("Chords")
	project.add_clip(clip)
	for p in [60, 64, 67]:
		clip.add_midi_note(project.allocate_note_id(), p, 0.8, 0, 480)
	var inst: Object = src.create_clip_instance(clip, 0, BAR)
	_record_start()
	var moved: int = _split.split_instances(project, [inst], [src, other])
	_record_stop()
	_assert(moved == 1, "the second voice moved to the second target (got %d)" % moved)
	_assert(clip.midi_notes.size() == 2, "the source clip lost that note")
	var landed := 0
	for i in other.clip_instances:
		landed += i.clip.midi_notes.size()
	_assert(landed == 1, "the other track received the note")
	_assert(_recorded.size() == 1, "Split to Tracks is one undo step")
	_recorded[0].undo()
	_assert(clip.midi_notes.size() == 3 and other.clip_instances.is_empty(), "undo puts the note back")


func _test_dialog_tree() -> void:
	var project: Object = _project_script.new()
	var folder: Object = project.create_folder_track("Folder").track
	var inside: Object = project.create_instrument_track("Inside").track
	var empty_folder: Object = project.create_folder_track("Unused").track
	var piano: Object = project.create_instrument_track("Piano").track
	var bass: Object = project.create_instrument_track("Bass").track
	project.place_track(inside, folder.id)
	var clip: Object = project.create_clip("Pad")
	project.add_clip(clip)
	clip.add_midi_note(project.allocate_note_id(), 60, 0.8, 0, 480)
	var inst: Object = bass.create_clip_instance(clip, 0, BAR)
	var ed = _editor_script.new()
	ed.set_grid_helper(_grid_helper_script.new())
	root.add_child(ed)
	ed.bind_to_clips(Array([inst], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd")), bass)
	await process_frame
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	var dlg: Object = _dialog_script.new()
	root.add_child(dlg)
	dlg.open_for(ed, [])
	_assert(dlg._targets == [inside, piano], "targets follow arranger order, the edited track is not one (got %s)" % [dlg._targets])
	var item: TreeItem = dlg._items[inside]
	_assert(item.get_parent() == dlg._items[folder], "a track sits under its folder")
	_assert(not dlg._items[folder].is_selectable(0), "the folder is a non-selectable parent")
	_assert(not dlg._items.has(empty_folder), "a folder without qualifying tracks is left out")
	_assert(dlg._items.has(bass) and not dlg._items[bass].is_selectable(0), "the edited track is shown but not selectable")
	_assert(dlg._items[bass].get_custom_bg_color(0).a > 0.0, "the edited track is highlighted")
	_assert(dlg.selected_target() == inside, "the first target is preselected")
	dlg._items[folder].collapsed = true
	_assert(dlg._items[folder].collapsed, "a group can be folded")
	dlg.hide()
	dlg.queue_free()
	ed.queue_free()
