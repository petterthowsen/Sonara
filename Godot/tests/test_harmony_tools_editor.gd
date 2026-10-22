# test_harmony_tools_editor.gd
# Spec 048 Phase 2 on NoteEditor (and Phase 3: toolbar, menu, dialogs, hotkeys): an edit that adds notes (T-010), Select Voices and Chord
# Inversion (T-011), Harmonize, Insert Chords and Insert Bassline (T-012). Every note-changing
# tool is exactly one undo step and undo restores the notes (REQ-001).
#
# Run: godot --headless --path Godot -s tests/test_harmony_tools_editor.gd -- --test
extends TestBase

const BAR := 3840

var _project_script: GDScript
var _editor_script: GDScript
var _grid_helper_script: GDScript
var _recorded: Array = []


func suite_name() -> String:
	return "Harmony tools in the note editor"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://clip_editor/note_editor/NoteEditor.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	await _test_edit_adds_notes()
	await _test_select_voice()
	await _test_invert()
	await _test_harmonize()
	await _test_harmonize_needs_scale()
	await _test_chords_range_and_cursor()
	await _test_chords_options_and_errors()
	await _test_chords_key_change()
	await _test_bassline()
	await _test_clip_mode()
	await _test_predicates()
	await _test_toolbar_and_menu()
	await _test_harmonize_dialog()
	await _test_chords_dialog()
	await _test_bassline_dialog()
	await _test_transfer_dialog()
	await _test_hotkeys()


## Notes are [pitch, start, duration] triples in clip ticks. The instance starts at song tick 0.
## `scale_id` "none" leaves the project and the editor without a key.
func _rig(notes: Array, scale_id: String = "major") -> Dictionary:
	var project: Object = _project_script.new()
	project.scale_root = 0
	project.scale_type = scale_id
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Pad")
	var made: Array = []
	for t: Array in notes:
		made.append(clip.add_midi_note(project.allocate_note_id(), t[0], 0.8, t[1], t[2]))
	var ed = _editor_script.new()
	ed.set_grid_helper(_grid_helper_script.new())
	root.add_child(ed)
	var inst: Object = track.create_clip_instance(clip, 0, 4 * BAR)
	var instances := Array([inst], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	ed.bind_to_clips(instances, track)
	ed.scale_context.scale = MusicalScale.make(0, scale_id)
	await process_frame
	return {"project": project, "track": track, "clip": clip, "notes": made, "ed": ed, "inst": inst}


func _record_start() -> void:
	_recorded.clear()
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: _recorded.append(cmd)


func _record_stop() -> void:
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = Callable()


## Sorted [pitch, start] pairs of the clip, to compare note lists.
func _state(clip: Object) -> Array:
	var out := []
	for n: MidiNoteData in clip.midi_notes:
		out.append([n.start_tick, n.note, n.duration_ticks])
	out.sort()
	return out


func _selected_pitches(ed: Object) -> Array:
	var out := []
	for vn in ed._selected_note_visuals():
		out.append(vn.midi_note_data.note)
	out.sort()
	return out


func _two_chords() -> Array:
	# C3-E3-G3 and D3-F3-A3-C4 (REQ-020 example).
	return [[60, 0, 960], [64, 0, 960], [67, 0, 960],
			[62, 1920, 960], [65, 1920, 960], [69, 1920, 960], [72, 1920, 960]]


func _test_edit_adds_notes() -> void:
	var ctx := await _rig([[60, 0, 960]])
	var ed = ctx.ed
	var clip: Object = ctx.clip
	var before := _state(clip)
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_record_start()
	var added: int = ed._apply_selection_edit("Test Add", func(_notes: Array[MidiNoteData]):
		var fresh := MidiNoteData.new()
		fresh.note = 64
		fresh.start_tick = 960
		fresh.duration_ticks = 480
		return {clip: [fresh]})
	_record_stop()
	_assert(added == 1 and clip.midi_notes.size() == 2, "an edit returning a clip-to-notes map adds the notes")
	_assert(clip.midi_notes[1].id > 0, "the added note gets an id from the clip")
	_assert(_recorded.size() == 1, "adding notes is one undo step")
	_assert(_selected_pitches(ed) == [60, 64], "the added note joins the selection")
	_recorded[0].undo()
	_assert(_state(clip) == before, "one undo removes the added note")
	_recorded[0].do()
	_assert(clip.midi_notes.size() == 2, "redo adds it again")
	# Without a selection the edit only runs when extra clips are named.
	ed.selection_manager.clear_selection()
	var ran := [false]
	_record_start()
	ed._apply_selection_edit("Test Add", func(_n): ran[0] = true)
	_record_stop()
	_assert(not ran[0] and _recorded.is_empty(), "no selection and no extra clip: nothing runs")
	# A same-pitch overlap at the landing spot is cut, inside the same step.
	_record_start()
	ed._apply_selection_edit("Test Add", func(_n):
		var over := MidiNoteData.new()
		over.note = 60
		over.start_tick = 480
		over.duration_ticks = 960
		return {clip: [over]}, [clip])
	_record_stop()
	_assert(_recorded.size() == 1, "an edit on an extra clip with no selection records one step")
	var original: MidiNoteData = clip.midi_notes[0]
	_assert(original.duration_ticks == 480, "the overlapped note was cut to make room")
	_recorded[0].undo()
	_assert(original.duration_ticks == 960 and clip.midi_notes.size() == 2, "undo restores the cut note and drops the new one")
	ed.queue_free()


func _test_select_voice() -> void:
	var ctx := await _rig(_two_chords())
	var ed = ctx.ed
	_record_start()
	ed.select_voice(NoteVoices.TOP)
	_assert(_selected_pitches(ed) == [67, 72], "Top selects G3 and C4 (nothing was selected: all notes are candidates)")
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	ed.select_voice(NoteVoices.BOTTOM)
	_assert(_selected_pitches(ed) == [60, 62], "Bottom selects C3 and D3")
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	ed.select_voice(2)
	_assert(_selected_pitches(ed) == [64, 69], "Voice 2 selects E3 and A3")
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	ed.select_voice(4)
	_assert(_selected_pitches(ed) == [62], "Voice 4 selects only D3")
	_record_stop()
	_assert(_recorded.is_empty(), "choosing a voice changes the selection only: no undo step")
	# With a selection the candidates are the selected notes only.
	var first_chord: Array[VisualNote] = []
	for vn in ed.get_all_visual_notes():
		if vn.midi_note_data.start_tick == 0:
			first_chord.append(vn)
	ed.selection_manager.select_visuals(first_chord)
	ed.select_voice(NoteVoices.TOP)
	_assert(_selected_pitches(ed) == [67], "Top of a selected chord only")
	ed.queue_free()


func _test_invert() -> void:
	var ctx := await _rig([[60, 0, 960], [64, 0, 960], [67, 0, 960]])
	var ed = ctx.ed
	var clip: Object = ctx.clip
	var original := _state(clip)
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	var pitches := func() -> Array:
		var out := []
		for n: MidiNoteData in clip.midi_notes:
			out.append(n.note)
		out.sort()
		return out
	_record_start()
	ed.invert_selection(true)
	_assert(pitches.call() == [64, 67, 72], "Up: C3 E3 G3 -> E3 G3 C4")
	_assert(_recorded.size() == 1, "the first inversion is one undo step")
	ed.invert_selection(true)
	_assert(pitches.call() == [67, 72, 76], "Up again: G3 C4 E4")
	_assert(_recorded.size() == 2, "each inversion is one step")
	ed.invert_selection(false)
	_assert(pitches.call() == [64, 67, 72], "Down: E3 G3 C4")
	_assert(_recorded.size() == 3, "three runs, three steps")
	_record_stop()
	_recorded[2].undo()
	_assert(pitches.call() == [67, 72, 76], "undo restores the notes before the last inversion")
	_recorded[1].undo()
	_recorded[0].undo()
	_assert(_state(clip) == original, "undoing every step restores the chord")
	# Up then Down restores the original.
	ed.invert_selection(true)
	ed.invert_selection(false)
	_assert(_state(clip) == original, "Up followed by Down restores the notes")
	# A single note is left alone and records nothing.
	var lone := await _rig([[60, 0, 960]])
	lone.ed.selection_manager.select_all(lone.ed.get_all_visual_notes())
	_record_start()
	lone.ed.invert_selection(true)
	_record_stop()
	_assert(_recorded.is_empty() and lone.clip.midi_notes[0].note == 60, "a one-note chord is left alone and records nothing")
	ed.queue_free()
	lone.ed.queue_free()


func _test_harmonize() -> void:
	var ctx := await _rig([[60, 0, 960], [62, 960, 960], [64, 1920, 960]])
	var ed = ctx.ed
	var clip: Object = ctx.clip
	var original := _state(clip)
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_record_start()
	var added: int = ed.harmonize_selection([HarmonyGenerators.THIRD], 0.0)
	_record_stop()
	_assert(added == 3 and clip.midi_notes.size() == 6, "C D E harmonized a 3rd above adds three notes")
	var pitches := []
	for n: MidiNoteData in clip.midi_notes:
		pitches.append(n.note)
	pitches.sort()
	_assert(pitches == [60, 62, 64, 64, 65, 67], "the copies are E F G")
	_assert(_recorded.size() == 1, "Harmonize is one undo step")
	_assert(_selected_pitches(ed) == [60, 62, 64, 64, 65, 67], "the copies join the selection")
	_recorded[0].undo()
	_assert(_state(clip) == original, "undo removes the copies")
	_recorded[0].do()
	_assert(clip.midi_notes.size() == 6, "redo brings them back")
	ed.queue_free()


func _test_harmonize_needs_scale() -> void:
	var ctx := await _rig([[60, 0, 960]], "none")
	var ed = ctx.ed
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_record_start()
	var added: int = ed.harmonize_selection([HarmonyGenerators.THIRD])
	_record_stop()
	_assert(added == 0 and _recorded.is_empty() and ctx.clip.midi_notes.size() == 1, "without a key Harmonize does nothing")
	_assert(not ed.has_scale() and not ed.can_harmonize() and not ed.can_insert_bassline() and not ed.can_insert_chords(),
			"the scale predicates are false without a key")
	_assert(ed.can_invert() and ed.can_select_voices(), "inversion and voice selection need no key")
	ed.queue_free()


func _test_chords_range_and_cursor() -> void:
	var ctx := await _rig([[60, 0, 960]])
	var ed = ctx.ed
	var clip: Object = ctx.clip
	var before := _state(clip)
	# No range: Count chords from the paste position (the cursor).
	ed.selection_manager.clear_selection()
	ed.cursor_position_ticks = BAR
	_record_start()
	var added: int = ed.insert_chords({"progression": "I V", "length_ticks": BAR, "count": 3, "range": Vector2i(48, 72)})
	_record_stop()
	_assert(added == 9, "3 chords of 3 notes (got %d)" % added)
	var starts := {}
	for n: MidiNoteData in clip.midi_notes:
		if n.start_tick > 0:
			starts[n.start_tick] = true
	_assert(starts.keys() == [BAR, 2 * BAR, 3 * BAR], "the chords land at the cursor and follow each other")
	_assert(_recorded.size() == 1, "Insert Chords is one undo step")
	_assert(_selected_pitches(ed).size() == 9, "the new chords are selected")
	_recorded[0].undo()
	_assert(_state(clip) == before, "undo restores the clip")
	# With a range: fill it, cutting the last chord.
	ed.selection_manager.set_range(0, 2 * BAR + 960)
	_record_start()
	added = ed.insert_chords({"progression": "I V vi IV", "length_ticks": BAR, "range": Vector2i(48, 72)})
	_record_stop()
	_assert(added == 9, "a range of 2 bars + a bit fills three chords (got %d)" % added)
	var last_len := 0
	for n: MidiNoteData in clip.midi_notes:
		if n.start_tick == 2 * BAR:
			last_len = n.duration_ticks
	_assert(last_len == 960, "the last chord is cut at the range end")
	_assert(_recorded.size() == 1, "still one step")
	_recorded[0].undo()
	_assert(_state(clip) == before, "undo restores the clip again")
	ed.queue_free()


func _test_chords_options_and_errors() -> void:
	var ctx := await _rig([])
	var ed = ctx.ed
	ed.cursor_position_ticks = 0
	_record_start()
	var added: int = ed.insert_chords({"progression": "I X"})
	_record_stop()
	_assert(added == 0 and _recorded.is_empty() and ed.last_chords_error != "", "a bad progression adds nothing and reports the error")
	_record_start()
	added = ed.insert_chords({"progression": "I", "length_ticks": BAR, "count": 1, "range": Vector2i(60, 61)})
	_record_stop()
	_assert(added == 3 and ed.last_chords_clamped, "a range too narrow for the chord is folded and flagged")
	var defaults: Dictionary = ed.chords_options()
	_assert(defaults.progression == "I V vi IV" and defaults.length_ticks == 3840 and defaults.count == 4
			and defaults.range == Vector2i(48, 72) and defaults.inversion == "root",
			"the remembered options default to the design values")
	_assert(ed.harmonize_steps() == [HarmonyGenerators.THIRD] and ed.bassline_range() == Vector2i(36, 48)
			and ed.bassline_pattern() == HarmonyGenerators.Pattern.SUSTAINED, "harmonize and bassline defaults")
	ed.queue_free()


func _test_chords_key_change() -> void:
	# C major for two bars, then A minor (REQ-003).
	var ctx := await _rig([])
	var ed = ctx.ed
	var clip: Object = ctx.clip
	ctx.project.key_change_map.add_change(2 * BAR, 9, "natural_minor")
	ed.selection_manager.set_range(0, 4 * BAR)
	_record_start()
	ed.insert_chords({"progression": "I", "length_ticks": BAR, "range": Vector2i(48, 72)})
	_record_stop()
	var pcs := func(tick: int) -> Array:
		var out := []
		for n: MidiNoteData in clip.midi_notes:
			if n.start_tick == tick:
				out.append(n.note % 12)
		out.sort()
		return out
	_assert(pcs.call(0) == [0, 4, 7] and pcs.call(BAR) == [0, 4, 7], "bars 1-2 are C major")
	_assert(pcs.call(2 * BAR) == [0, 4, 9] and pcs.call(3 * BAR) == [0, 4, 9], "bars 3-4 are A minor (A C E)")
	_assert(ed._scale_at_clip_tick(clip, 3 * BAR).root == 9, "_scale_at_clip_tick follows the key change")
	# The same instance moved later shifts the song tick the key is read at.
	ctx.inst.set_position(2 * BAR)
	_assert(ed._scale_at_clip_tick(clip, 0).root == 9, "clip tick 0 of an instance at bar 3 is in A minor")
	ed.queue_free()


func _test_bassline() -> void:
	var ctx := await _rig([[60, 0, BAR], [64, 0, BAR], [67, 0, BAR], [57, BAR, BAR], [60, BAR, BAR], [64, BAR, BAR]])
	var ed = ctx.ed
	var clip: Object = ctx.clip
	var original := _state(clip)
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_record_start()
	var added: int = ed.insert_bassline(HarmonyGenerators.Pattern.SUSTAINED, Vector2i(36, 48))
	_record_stop()
	_assert(added == 2, "one sustained bass note per chord (got %d)" % added)
	var bass := {}
	for n: MidiNoteData in clip.midi_notes:
		if n.note < 48:
			bass[n.start_tick] = n.note
	_assert(bass == {0: 36, BAR: 45}, "C1 under C major, A1 under A minor")
	_assert(_recorded.size() == 1, "Insert Bassline is one undo step")
	_recorded[0].undo()
	_assert(_state(clip) == original, "undo removes the bass notes")
	ed.queue_free()


func _test_clip_mode() -> void:
	# Single-clip mode: editor ticks are clip ticks.
	var project: Object = _project_script.new()
	project.scale_type = "major"
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Pad")
	for p in [60, 64, 67]:
		clip.add_midi_note(project.allocate_note_id(), p, 0.8, 0, 960)
	var inst: Object = track.create_clip_instance(clip, BAR, 2 * BAR)
	var ed = _editor_script.new()
	ed.set_grid_helper(_grid_helper_script.new())
	root.add_child(ed)
	ed.bind(inst)
	ed.scale_context.scale = MusicalScale.make(0, "major")
	await process_frame
	_assert(ed.source_track() == track, "clip mode finds its track through the instance")
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_record_start()
	var added: int = ed.harmonize_selection([HarmonyGenerators.THIRD], 0.0)
	_record_stop()
	_assert(added == 1 and clip.midi_notes.size() == 4 and _recorded.size() == 1, "Harmonize works in clip mode as one step (E and G thirds already in the chord are skipped, B is new)")
	ed.selection_manager.clear_selection()
	ed.cursor_position_ticks = BAR
	_record_start()
	added = ed.insert_chords({"progression": "I", "length_ticks": BAR, "count": 1})
	_record_stop()
	_assert(added == 3 and _recorded.size() == 1, "Insert Chords works in clip mode")
	var at_cursor := 0
	for n: MidiNoteData in clip.midi_notes:
		if n.start_tick == BAR:
			at_cursor += 1
	_assert(at_cursor == 3, "clip-mode chords start at the cursor's clip tick")
	ed.queue_free()


func _test_predicates() -> void:
	var ctx := await _rig(_two_chords())
	var ed = ctx.ed
	ed.selection_manager.clear_selection()
	_assert(not ed.can_invert() and not ed.can_harmonize() and not ed.can_transfer(), "selection tools are off with no selection")
	_assert(ed.can_select_voices(), "Select Voices works on all notes with no selection")
	ed.cursor_position_ticks = 0
	_assert(ed.can_insert_chords(), "Insert Chords works with no selection when there is a key and a clip")
	ed.cursor_position_ticks = 6 * BAR
	_assert(not ed.can_insert_chords(), "track mode: no clip at the cursor, nothing to write into")
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_assert(ed.can_invert() and ed.can_harmonize() and ed.can_insert_bassline() and ed.can_transfer(), "selection tools are on with a selection")
	ed.queue_free()


# --- Phase 3: toolbar, Harmony menu, dialogs, hotkeys ---

## A ClipEditor.tscn bound to one instrument track "Piano" (C3-E3-G3 and D3-F3-A3-C4 over 4 bars)
## and a second track "Bass". The editor shows the Piano clip in clip mode.
func _clip_editor_rig(scale_id: String = "major") -> Dictionary:
	var project: Object = _project_script.new()
	project.scale_root = 0
	project.scale_type = scale_id
	var piano: Object = project.create_instrument_track("Piano").track
	var bass: Object = project.create_instrument_track("Bass").track
	var clip: Object = project.create_clip("Pad")
	project.add_clip(clip)
	for t: Array in _two_chords():
		clip.add_midi_note(project.allocate_note_id(), t[0], 0.8, t[1], t[2])
	var inst: Object = piano.create_clip_instance(clip, 0, 4 * BAR)
	var scene: PackedScene = load("res://clip_editor/ClipEditor.tscn")
	var ce: Control = scene.instantiate()
	root.add_child(ce)
	await process_frame
	await process_frame
	ce.midi_editor.bind_to_clip_instance(inst)
	await process_frame
	await process_frame
	ce.midi_editor.scale_context.scale = MusicalScale.make(0, scale_id)
	var ed: Object = ce.midi_editor.get_active_note_editor()
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	ce._sync_selection_tools()
	return {"project": project, "piano": piano, "bass": bass, "clip": clip, "inst": inst, "ce": ce, "ed": ed}


func _menu_item_index(popup: PopupMenu, text: String) -> int:
	for i in popup.item_count:
		if popup.get_item_text(i) == text:
			return i
	return -1


func _test_toolbar_and_menu() -> void:
	var ctx := await _clip_editor_rig("major")
	var ce: Control = ctx.ce
	var popup: PopupMenu = ce.harmony_button.get_popup()
	var texts := []
	for i in popup.item_count:
		texts.append("-" if popup.is_item_separator(i) else popup.get_item_text(i))
	_assert(texts == ["Select Voices", "Harmonize...", "Insert Chords...", "Insert Bassline...", "-", "Transfer Notes...", "Split Voices", "Split Into Child Tracks", "-", "Make Legato", "Merge Same Notes"],
			"the Harmony menu lists its items in order (got %s)" % [texts])
	var sub: PopupMenu = popup.get_item_submenu_node(0)
	var sub_texts := []
	for i in sub.item_count:
		sub_texts.append(sub.get_item_text(i))
	_assert(sub_texts == ["Top", "Bottom", "Voice 2", "Voice 3", "Voice 4", "Voice 5", "Voice 6"],
			"Select Voices lists Top, Bottom and Voice 2-6 (got %s)" % [sub_texts])
	var tools: Node = ce.tools_group
	var up: Button = tools.find_child("InvertUp", true, false)
	var down: Button = tools.find_child("InvertDown", true, false)
	_assert(up != null and down != null and not up.disabled and not down.disabled, "Invert Up and Down are on with a selection")
	_assert(not ce.harmony_button.disabled, "the Harmony button is always usable")
	var idx := {}
	for name in ["Harmonize...", "Insert Chords...", "Insert Bassline...", "Transfer Notes...", "Split Voices"]:
		idx[name] = _menu_item_index(popup, name)
	_assert(not popup.is_item_disabled(idx["Harmonize..."]) and not popup.is_item_disabled(idx["Insert Chords..."])
			and not popup.is_item_disabled(idx["Insert Bassline..."]), "with C Major the three generators are enabled")
	_assert(not popup.is_item_disabled(idx["Transfer Notes..."]), "Transfer Notes is enabled with a selection")
	_assert(popup.is_item_disabled(idx["Split Voices"]) and popup.get_item_tooltip(idx["Split Voices"]) != "",
			"Split Voices is disabled with no other selected instrument track, and says why")

	# REQ-042: a selected instrument track besides the source enables Split Voices.
	var editor_node: Object = ctx.ed
	var enabled: bool = editor_node.has_split_targets([ctx.piano, ctx.bass])
	_assert(enabled and not editor_node.has_split_targets([ctx.piano]), "split targets: the Bass track counts, the source alone does not")

	# REQ-002: no scale.
	ctx.ce.midi_editor.scale_context.scale = MusicalScale.make(0, MusicalScale.NONE_ID)
	ce._sync_selection_tools()
	for name in ["Harmonize...", "Insert Chords...", "Insert Bassline..."]:
		_assert(popup.is_item_disabled(idx[name]) and popup.get_item_tooltip(idx[name]).contains("key"),
				"%s is disabled with no scale and the tooltip asks for a key" % name)
	_assert(not popup.is_item_disabled(idx["Transfer Notes..."]) and not up.disabled and not popup.is_item_disabled(0),
			"Transfer, Invert and Select Voices work without a scale")
	ctx.ce.midi_editor.scale_context.scale = MusicalScale.make(0, "major")
	ce._sync_selection_tools()
	_assert(not popup.is_item_disabled(idx["Insert Chords..."]), "setting C Major enables the generators again")

	# Drum View disables everything.
	ce.midi_editor.drum_view = true
	await process_frame
	ce._sync_selection_tools()
	var all_off: bool = up.disabled and down.disabled
	for i in popup.item_count:
		if not popup.is_item_separator(i):
			all_off = all_off and popup.is_item_disabled(i)
	_assert(all_off, "in Drum View the inversion buttons and every Harmony item are disabled")
	ce.midi_editor.drum_view = false
	ce.queue_free()

	# The Select Voices submenu runs select_voice, the Invert buttons run invert_selection.
	var ctx2 := await _clip_editor_rig("major")
	var ed2: Object = ctx2.ed
	ctx2.ce._on_voice_menu_pressed(ctx2.ce.VOICE_ID_BASE + NoteVoices.TOP)
	_assert(_selected_pitches(ed2) == [67, 72], "the Top menu item selects the top voice")
	ed2.selection_manager.select_all(ed2.get_all_visual_notes())
	_record_start()
	ctx2.ce.tools_group.find_child("InvertUp", true, false).pressed.emit()
	_record_stop()
	_assert(_recorded.size() == 1 and ctx2.clip.midi_notes[0].note == 72, "the Invert Up button inverts the chords in one undo step")
	ctx2.ce.queue_free()


func _test_harmonize_dialog() -> void:
	var ctx := await _clip_editor_rig("major")
	var ce: Control = ctx.ce
	var steps_before: Array = _editor_script.harmonize_steps()
	ce.open_harmony_dialog(&"harmonize")
	var dlg: Object = ce._harmonize_dialog
	_assert(dlg != null and dlg.visible, "Harmonize opens its dialog")
	_assert(dlg.selected_steps() == steps_before, "it opens with the remembered intervals (default: a 3rd above)")
	dlg.checks[HarmonyGenerators.THIRD].button_pressed = false
	_assert(dlg.get_ok_button().disabled, "OK is disabled with no interval")
	dlg.checks[-HarmonyGenerators.SIXTH].button_pressed = true
	dlg.checks[HarmonyGenerators.FIFTH].button_pressed = true
	dlg.velocity_spin.value = -20
	_assert(not dlg.get_ok_button().disabled, "OK is enabled again")
	var before := _state(ctx.clip)
	_record_start()
	dlg.confirmed.emit()
	_record_stop()
	_assert(_recorded.size() == 1 and ctx.clip.midi_notes.size() > before.size(), "OK runs Harmonize as one undo step")
	_assert(_editor_script.harmonize_steps() == [HarmonyGenerators.FIFTH, -HarmonyGenerators.SIXTH],
			"the options are stored (got %s)" % [_editor_script.harmonize_steps()])
	_assert(is_equal_approx(_editor_script.harmonize_velocity_offset(), -0.2), "the velocity offset is stored")
	dlg.hide()
	ce.open_harmony_dialog(&"harmonize")
	_assert(dlg.selected_steps() == [HarmonyGenerators.FIFTH, -HarmonyGenerators.SIXTH] and is_equal_approx(dlg.velocity_offset(), -0.2),
			"reopening shows the confirmed options")
	_editor_script.store_config(_editor_script.HARMONIZE_INTERVALS_KEY, steps_before)
	_editor_script.store_config(_editor_script.HARMONIZE_VELOCITY_KEY, 0.0)
	dlg.hide()
	ce.queue_free()


func _test_chords_dialog() -> void:
	var ctx := await _clip_editor_rig("major")
	var ce: Control = ctx.ce
	var ed: Object = ctx.ed
	ed.selection_manager.clear_selection()
	ed.cursor_position_ticks = 2 * BAR
	ce.open_harmony_dialog(&"chords")
	var dlg: Object = ce._chords_dialog
	_assert(dlg != null and dlg.visible, "Insert Chords opens its dialog")
	_assert(dlg.progression_edit.text == "I V vi IV" and dlg.is_valid(), "it starts with the default progression")
	_assert(dlg.count_row.visible, "the Count field shows without a selection range")
	dlg.progression_edit.text = "I V xx IV"
	dlg.progression_edit.text_changed.emit(dlg.progression_edit.text)
	_assert(dlg.get_ok_button().disabled and dlg.error_label.text.contains("xx"), "an invalid token disables OK and names the token (got '%s')" % dlg.error_label.text)
	dlg.preset_option.select(2)
	dlg.preset_option.item_selected.emit(2)
	_assert(dlg.progression_edit.text == ChordTheory.PRESETS[1].text and not dlg.get_ok_button().disabled, "picking a preset fills the progression")
	dlg.progression_edit.text = "I IV"
	dlg.progression_edit.text_changed.emit("I IV")
	dlg.length_option.select(dlg.length_option.get_item_index(1920))
	dlg.count_spin.value = 2
	dlg.voicing_option.select(dlg.voicing_option.get_item_index(ChordTheory.Voicing.SPREAD))
	dlg.inversion_option.select(1)
	dlg.range_row.set_range(Vector2i(50, 70))
	_record_start()
	dlg.confirmed.emit()
	_record_stop()
	_assert(_recorded.size() == 1, "OK runs Insert Chords as one undo step")
	var starts := {}
	for n: MidiNoteData in ctx.clip.midi_notes:
		if n.start_tick >= 2 * BAR:
			starts[n.start_tick] = true
	_assert(starts.keys() == [2 * BAR, 2 * BAR + 1920], "two half-bar chords land at the edit position (got %s)" % [starts.keys()])
	var stored: Dictionary = _editor_script.chords_options()
	_assert(stored.progression == "I IV" and stored.length_ticks == 1920 and stored.count == 2 \
			and stored.voicing == ChordTheory.Voicing.SPREAD and stored.inversion == "smooth" and stored.range == Vector2i(50, 70),
			"the options are stored (got %s)" % [stored])
	dlg.hide()
	ce.open_harmony_dialog(&"chords")
	_assert(dlg.progression_edit.text == "I IV" and dlg.length_option.get_selected_id() == 1920 and int(dlg.count_spin.value) == 2
			and dlg.range_row.range_value() == Vector2i(50, 70) and dlg.inversion_option.get_selected_id() == 1
			and dlg.voicing_option.get_selected_id() == ChordTheory.Voicing.SPREAD, "reopening shows the confirmed options")
	dlg.hide()
	# With a selection range the Count field is hidden.
	ed.selection_manager.set_range(0, BAR)
	ce.open_harmony_dialog(&"chords")
	_assert(not dlg.count_row.visible, "the Count field is hidden when a selection range exists")
	dlg.hide()
	# 7th chords toggle.
	dlg.seventh_check.button_pressed = true
	_assert(dlg.progression_edit.text == "I7 IV7", "7th chords adds a 7 to every numeral (got '%s')" % dlg.progression_edit.text)
	dlg.seventh_check.button_pressed = false
	_assert(dlg.progression_edit.text == "I IV", "and unchecking removes them")
	# Reset the remembered options to their defaults.
	var defaults := {_editor_script.CHORDS_PROGRESSION_KEY: "I V vi IV", _editor_script.CHORDS_LENGTH_KEY: 3840,
			_editor_script.CHORDS_COUNT_KEY: 4, _editor_script.CHORDS_RANGE_KEY: [48, 72],
			_editor_script.CHORDS_VOICING_KEY: "close", _editor_script.CHORDS_INVERSION_KEY: "root",
			_editor_script.CHORDS_SEVENTH_KEY: false}
	for key: String in defaults:
		_editor_script.store_config(key, defaults[key])
	ce.queue_free()

	# A pentatonic scale gets the notice.
	var ctx2 := await _clip_editor_rig("major_pentatonic")
	ctx2.ce.open_harmony_dialog(&"chords")
	_assert(ctx2.ce._chords_dialog.scale_notice.visible and ctx2.ce._chords_dialog.scale_notice.text.contains("5-note"),
			"a non-heptatonic scale shows the n-note notice")
	ctx2.ce._chords_dialog.hide()
	ctx2.ce.queue_free()


func _test_bassline_dialog() -> void:
	var ctx := await _clip_editor_rig("major")
	var ce: Control = ctx.ce
	ce.open_harmony_dialog(&"bassline")
	var dlg: Object = ce._bassline_dialog
	_assert(dlg != null and dlg.visible and dlg.pattern() == HarmonyGenerators.Pattern.SUSTAINED, "Insert Bassline opens with the default pattern")
	dlg.pattern_option.select(dlg.pattern_option.get_item_index(HarmonyGenerators.Pattern.ROOT_FIFTH))
	dlg.range_row.set_range(Vector2i(30, 50))
	var count: int = ctx.clip.midi_notes.size()
	_record_start()
	dlg.confirmed.emit()
	_record_stop()
	_assert(_recorded.size() == 1 and ctx.clip.midi_notes.size() > count, "OK runs Insert Bassline as one undo step")
	_assert(_editor_script.bassline_pattern() == HarmonyGenerators.Pattern.ROOT_FIFTH and _editor_script.bassline_range() == Vector2i(30, 50),
			"the pattern and range are stored")
	dlg.hide()
	ce.open_harmony_dialog(&"bassline")
	_assert(dlg.pattern() == HarmonyGenerators.Pattern.ROOT_FIFTH and dlg.range_row.range_value() == Vector2i(30, 50),
			"reopening shows the confirmed options")
	dlg.hide()
	_editor_script.store_config(_editor_script.BASSLINE_PATTERN_KEY, "sustained")
	_editor_script.store_config(_editor_script.BASSLINE_RANGE_KEY, [36, 48])
	ce.queue_free()


func _test_transfer_dialog() -> void:
	var ctx := await _clip_editor_rig("major")
	var ce: Control = ctx.ce
	var ed: Object = ctx.ed
	var project: Object = ctx.project
	var extra: Object = project.create_instrument_track("Strings").track
	ce.open_harmony_dialog(&"transfer")
	var dlg: Object = ce._transfer_dialog
	_assert(dlg != null and dlg.visible, "Transfer Notes opens its dialog")
	_assert(dlg._targets == [ctx.bass, extra], "the targets are the other instrument tracks (not the source)")
	_assert(dlg.default_target_index([]) == 0, "no selected track and no history: the first target")
	_assert(dlg.default_target_index([extra]) == 1, "the selected track is the default target")
	_assert(dlg.default_target_index([ctx.piano]) == 0, "the source track as selection is not a target: falls back")
	_editor_script.store_config(_editor_script.TRANSFER_TARGET_KEY, extra.id)
	_assert(dlg.default_target_index([]) == 1, "otherwise the last target")
	_assert(dlg.default_target_index([ctx.bass]) == 0, "a selected track wins over the last target")
	_editor_script.store_config(_editor_script.TRANSFER_TARGET_KEY, -1)
	_assert(not dlg.warning_label.visible, "no warning for an unlinked target")
	dlg.hide()
	# A linked target: a clip on Strings that is also used on Bass.
	var linked: Object = project.create_clip("Linked")
	project.add_clip(linked)
	extra.create_clip_instance(linked, 0, 4 * BAR)
	ctx.bass.create_clip_instance(linked, 0, 4 * BAR)
	ce.open_harmony_dialog(&"transfer")
	dlg.select_target(extra)
	dlg.target_tree.item_selected.emit()
	_assert(dlg.warning_label.visible and dlg.warning_label.text.contains("Linked"), "the warning shows for a linked target (got '%s')" % dlg.warning_label.text)
	var before_selected: int = ed._selected_note_visuals().size()
	_record_start()
	dlg.confirmed.emit()
	_record_stop()
	_assert(_recorded.size() == 1, "OK transfers the notes as one undo step")
	_assert(ctx.clip.midi_notes.is_empty() and linked.midi_notes.size() == before_selected,
			"the notes left the source clip and are in the linked clip (%d)" % linked.midi_notes.size())
	_assert(int(_editor_script._config_value(_editor_script.TRANSFER_TARGET_KEY, -1)) == extra.id, "the target is remembered")
	_editor_script.store_config(_editor_script.TRANSFER_TARGET_KEY, -1)
	ce.queue_free()


func _key_event(keycode: Key, ctrl: bool, shift: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	event.pressed = true
	return event


func _test_hotkeys() -> void:
	var ids := ["notes_invert_up", "notes_invert_down", "notes_select_voice_top", "notes_select_voice_bottom",
			"notes_harmonize", "notes_insert_chords", "notes_insert_bassline", "notes_transfer", "notes_split_voices"]
	for id in ids:
		var def := HotkeyActions.get_action(id)
		_assert(not def.is_empty() and def.context == "clip_editor", "%s is a registered clip_editor action" % id)
	_assert(HotkeyActions.get_action("notes_invert_up").defaults == ["Ctrl+Shift+Up"]
			and HotkeyActions.get_action("notes_invert_down").defaults == ["Ctrl+Shift+Down"], "the inversion hotkeys default to Ctrl+Shift+Up/Down")
	var hotkeys: Node = root.get_node("Hotkeys")
	_assert(hotkeys.find_conflicts("notes_invert_up", "Ctrl+Shift+Up").is_empty() and hotkeys.find_conflicts("notes_invert_down", "Ctrl+Shift+Down").is_empty(),
			"no other action uses those chords")
	# Every Harmony menu item that is not a numbered voice has an action.
	var menu_to_action := {"Harmonize...": "notes_harmonize", "Insert Chords...": "notes_insert_chords",
			"Insert Bassline...": "notes_insert_bassline", "Transfer Notes...": "notes_transfer",
			"Split Voices": "notes_split_voices", "Top": "notes_select_voice_top", "Bottom": "notes_select_voice_bottom"}
	for text: String in menu_to_action:
		_assert(not HotkeyActions.get_action(menu_to_action[text]).is_empty(), "the menu item %s has an action" % text)

	var ctx := await _rig(_two_chords())
	var ed = ctx.ed
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_record_start()
	ed.handle_key_input(_key_event(KEY_UP, true, true))
	_record_stop()
	_assert(_recorded.size() == 1 and ctx.notes[0].note == 72, "Ctrl+Shift+Up inverts the chords up")
	_record_start()
	ed.handle_key_input(_key_event(KEY_DOWN, true, true))
	_record_stop()
	_assert(_recorded.size() == 1 and ctx.notes[0].note == 60, "Ctrl+Shift+Down inverts them back down")
	# The dialog actions (unbound by default) go out as a signal once bound.
	var asked := []
	ed.harmony_dialog_requested.connect(func(tool: StringName): asked.append(tool))
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	for entry in [["notes_harmonize", &"harmonize"], ["notes_insert_chords", &"chords"],
			["notes_insert_bassline", &"bassline"], ["notes_transfer", &"transfer"]]:
		var event := _key_event(KEY_F13, false, false)
		InputMap.action_add_event(entry[0], event)
		ed.handle_key_input(event)
		InputMap.action_erase_events(entry[0])
	_assert(asked == [&"harmonize", &"chords", &"bassline", &"transfer"], "the dialog hotkeys request their dialogs (got %s)" % [asked])
	ed.queue_free()
