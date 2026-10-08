# test_scale_snap.gd
# Scale math in NoteTransforms and the ScaleContext wrappers (REQ-014..017, 019, 021, 022).
# Run: godot --headless --path Godot -s tests/test_scale_snap.gd -- --test
extends TestBase

var C_MAJOR := MusicalScale.make(0, "major").pitch_classes()
var A_MINOR := MusicalScale.make(9, "natural_minor").pitch_classes()


func suite_name() -> String:
	return "Scale snap"


func run_tests() -> void:
	await _test_placement()
	await _test_drag()
	await _test_conform_selection()
	_test_snap_pitch()
	_test_step_in_scale()
	_test_saturation()
	_test_steps_between()
	_test_conform()
	_test_empty_pcs()
	_test_context_inactive()
	_test_context_active()


func _note(pitch: int) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = 0
	n.duration_ticks = 240
	return n


func _notes(pitches: Array) -> Array[MidiNoteData]:
	var out: Array[MidiNoteData] = []
	for p in pitches:
		out.append(_note(p))
	return out


func _pitches(notes: Array[MidiNoteData]) -> Array:
	return notes.map(func(n): return n.note)


func _test_snap_pitch() -> void:
	_assert(NoteTransforms.snap_pitch(61, C_MAJOR, true) == 62, "C#3 upper half -> D3")
	_assert(NoteTransforms.snap_pitch(61, C_MAJOR, false) == 60, "C#3 lower half -> C3")
	_assert(NoteTransforms.snap_pitch(60, C_MAJOR, true) == 60, "in-scale pitch unchanged")
	_assert(NoteTransforms.snap_pitch(66, C_MAJOR, false) == 65, "F#3 tie down -> F3")
	_assert(NoteTransforms.snap_pitch(66, C_MAJOR, true) == 67, "F#3 tie up -> G3")
	# Not a tie: C minor pentatonic (0 3 5 7 10), pitch 1 is nearer 0 than 3.
	var cmp := MusicalScale.make(0, "minor_pentatonic").pitch_classes()
	_assert(NoteTransforms.snap_pitch(61, cmp, true) == 60, "nearest wins over prefer_up")
	_assert(NoteTransforms.snap_pitch(62, cmp, false) == 63, "D3 -> D#3 (distance 1 beats 2)")


func _test_step_in_scale() -> void:
	_assert(NoteTransforms.step_in_scale(60, 1, C_MAJOR) == 62, "C3 +1 -> D3")
	_assert(NoteTransforms.step_in_scale(64, 1, C_MAJOR) == 65, "E3 +1 -> F3")
	_assert(NoteTransforms.step_in_scale(67, 1, C_MAJOR) == 69, "G3 +1 -> A3")
	_assert(NoteTransforms.step_in_scale(61, 1, C_MAJOR) == 63, "C#3 +1 -> D#3 (keeps +1 offset)")
	_assert(NoteTransforms.step_in_scale(59, 1, A_MINOR) == 60, "B2 +1 in A minor -> C3")
	_assert(NoteTransforms.step_in_scale(62, -1, C_MAJOR) == 60, "D3 -1 -> C3")
	_assert(NoteTransforms.step_in_scale(60, 7, C_MAJOR) == 72, "7 steps is an octave")
	_assert(NoteTransforms.step_in_scale(60, 0, C_MAJOR) == 60, "0 steps unchanged")
	_assert(NoteTransforms.step_in_scale(61, 0, C_MAJOR) == 61, "0 steps keeps out-of-scale pitch")


func _test_saturation() -> void:
	_assert(NoteTransforms.step_in_scale(60, -1000, C_MAJOR) == 0, "saturates at the lowest in-scale pitch")
	# Highest C-major pitch <= 127 is 127 % 12 = 7 (G) -> 127.
	_assert(NoteTransforms.step_in_scale(60, 1000, C_MAJOR) == 127, "saturates at 127 (G9 is in C Major)")
	# Out-of-scale offset is clamped into range.
	_assert(NoteTransforms.step_in_scale(61, 1000, C_MAJOR) == 127, "offset result clamped to 127")
	_assert(NoteTransforms.step_in_scale(1, -1000, C_MAJOR) == 1, "C#-1 at the bottom keeps its offset")


func _test_steps_between() -> void:
	_assert(NoteTransforms.scale_steps_between(60, 62, C_MAJOR) == 1, "C3 -> D3 is one step")
	_assert(NoteTransforms.scale_steps_between(62, 60, C_MAJOR) == -1, "D3 -> C3 is minus one")
	_assert(NoteTransforms.scale_steps_between(61, 62, C_MAJOR) == 1, "C#3 counts from base C3")
	_assert(NoteTransforms.scale_steps_between(60, 72, C_MAJOR) == 7, "octave is 7 steps")
	_assert(NoteTransforms.scale_steps_between(60, 60, C_MAJOR) == 0, "same pitch zero steps")
	_assert(NoteTransforms.scale_base(61, C_MAJOR) == 60, "scale_base of C#3 is C3")
	_assert(NoteTransforms.scale_base(60, C_MAJOR) == 60, "scale_base of in-scale is itself")


func _test_conform() -> void:
	var notes := _notes([61, 63, 66])
	var changed := NoteTransforms.conform_to_scale(notes, C_MAJOR, PackedInt32Array())
	_assert(_pitches(notes) == [60, 62, 65], "C Major conform [61,63,66] -> [60,62,65]")
	_assert(changed == 3, "conform reports 3 changed")
	notes = _notes([60, 61, 37])
	changed = NoteTransforms.conform_to_scale(notes, C_MAJOR, PackedInt32Array([37]))
	_assert(_pitches(notes) == [60, 60, 37], "keyswitch 37 is skipped")
	_assert(changed == 1, "only the C# changed")


func _test_empty_pcs() -> void:
	var none := PackedInt32Array()
	_assert(NoteTransforms.snap_pitch(61, none, true) == 61, "empty pcs: snap_pitch returns input")
	_assert(NoteTransforms.step_in_scale(61, 3, none) == 61, "empty pcs: step returns input")
	_assert(NoteTransforms.scale_steps_between(60, 70, none) == 0, "empty pcs: zero steps")
	var notes := _notes([61])
	_assert(NoteTransforms.conform_to_scale(notes, none) == 0 and notes[0].note == 61, "empty pcs: conform no-op")


func _context(scale: MusicalScale) -> ScaleContext:
	var ctx := ScaleContext.new()
	ctx.scale = scale
	ctx.snap_enabled = true
	return ctx


func _test_context_inactive() -> void:
	var none_ctx := _context(MusicalScale.make(0, "none"))
	_assert(not none_ctx.snap_active() and not none_ctx.highlight_active(), "scale none: inactive")
	_assert(none_ctx.snap_pitch(61, true) == 61 and none_ctx.step(61, 2) == 61, "scale none: wrappers return input")
	var drum := _context(MusicalScale.make(0, "major"))
	drum.drum_view = true
	_assert(not drum.snap_active() and not drum.highlight_active() and not drum.fold_active(), "Drum View: inactive")
	_assert(drum.snap_pitch(61, true) == 61 and drum.step(61, 2) == 61 and drum.steps_between(60, 72) == 0,
		"Drum View: wrappers return input")
	var off := _context(MusicalScale.make(0, "major"))
	off.snap_enabled = false
	_assert(off.highlight_active() and not off.snap_active(), "snap off: highlight yes, snap no")
	_assert(off.snap_pitch(61, true) == 61 and off.step(61, 2) == 61, "snap off: wrappers return input")


func _test_context_active() -> void:
	var ctx := _context(MusicalScale.make(0, "major"))
	ctx.keyswitches = PackedInt32Array([37])
	_assert(ctx.snap_active(), "active with scale and snap")
	_assert(ctx.snap_pitch(61, true) == 62 and ctx.snap_pitch(61, false) == 60, "active snap_pitch delegates")
	_assert(ctx.step(60, 1) == 62 and ctx.steps_between(60, 64) == 2, "active step / steps_between delegate")
	_assert(ctx.is_keyswitch(37) and not ctx.is_keyswitch(38), "keyswitch pitches reported")
	_assert(not ctx.fold_active(), "fold off by default")
	ctx.fold_enabled = true
	_assert(ctx.fold_active(), "fold active when enabled")
	var fired := [0]
	ctx.changed.connect(func(): fired[0] += 1)
	ctx.snap_enabled = false
	ctx.scale = MusicalScale.make(2, "dorian")
	_assert(fired[0] == 2, "changed emitted on setter changes")


# --- NoteEditor integration (T-010, T-011, T-013) ---


## An empty clip bound to a NoteEditor, with a C Major scale context and snap on.
func _rig(pitches: Array, snap := true) -> Dictionary:
	var project: Object = load("res://data/Project.gd").new()
	var track: Object = project.create_instrument_track("Piano").track
	var clip: Object = project.create_clip("Riff")
	var datas: Array = []
	for p in pitches:
		datas.append(clip.add_midi_note(project.allocate_note_id(), p, MidiNoteData.from_midi_velocity(100), 960, 480))
	var editor = load("res://clip_editor/note_editor/NoteEditor.gd").new()
	editor.set_grid_helper(load("res://components/GridHelper.gd").new())
	root.add_child(editor)
	var instances := Array([track.create_clip_instance(clip, 0, 7680)], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	editor.bind_to_clips(instances, track)
	await process_frame
	editor.scale_context.scale = MusicalScale.make(0, "major")
	editor.scale_context.snap_enabled = snap
	return {"editor": editor, "clip": clip, "datas": datas}


func _test_placement() -> void:
	var ctx := await _rig([])
	var ed = ctx.editor
	var h: float = ed.layout.row_height
	var y: float = ed.layout.pitch_to_y(61)
	var x: float = ed.ticks_to_pixels(960)
	var up = ed.place_note_at_position(Vector2(x, y + h * 0.25))
	_assert(up != null and up.midi_note_data.note == 62, "C#3 row, upper half places D3")
	var low = ed.place_note_at_position(Vector2(x, y + h * 0.75))
	_assert(low != null and low.midi_note_data.note == 60, "C#3 row, lower half places C3")
	ed.scale_context.keyswitches = PackedInt32Array([61])
	var ks = ed.place_note_at_position(Vector2(x, y + h * 0.25))
	_assert(ks != null and ks.midi_note_data.note == 61, "a keyswitch row keeps its pitch")
	ed.scale_context.snap_enabled = false
	ed.scale_context.keyswitches = PackedInt32Array()
	var off = ed.place_note_at_position(Vector2(x, y + h * 0.25))
	_assert(off != null and off.midi_note_data.note == 61, "snap off places the row's pitch")


func _visual_for(ed: Object, data: MidiNoteData) -> VisualNote:
	for vn in ed.get_all_visual_notes():
		if vn.midi_note_data == data:
			return vn
	return null


func _test_drag() -> void:
	var ctx := await _rig([60, 64, 67])
	var ed = ctx.editor
	var d: Array = ctx.datas
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	var h: float = ed.layout.row_height
	var y60: float = ed.layout.pitch_to_y(60) + h * 0.25
	ed._on_drag_started(_visual_for(ed, d[0]), Vector2(100, y60))
	# One row up: the cursor is on the C#3 row, upper half, so the target is D3.
	ed._on_drag_updated(_visual_for(ed, d[0]), Vector2(100, ed.layout.pitch_to_y(61) + h * 0.25))
	_assert([d[0].note, d[1].note, d[2].note] == [62, 65, 69], "C-E-G dragged one row up -> D-F-A")
	ed._on_drag_ended(_visual_for(ed, d[0]))

	var ctx2 := await _rig([61])
	var ed2 = ctx2.editor
	ed2.selection_manager.select_all(ed2.get_all_visual_notes())
	ed2._on_drag_started(_visual_for(ed2, ctx2.datas[0]), Vector2(100, ed2.layout.pitch_to_y(61) + h * 0.5))
	ed2._on_drag_updated(_visual_for(ed2, ctx2.datas[0]), Vector2(100, ed2.layout.pitch_to_y(62) + h * 0.5))
	_assert(ctx2.datas[0].note == 63, "C#3 in the selection dragged one row up -> D#3")
	ed2._on_drag_ended(_visual_for(ed2, ctx2.datas[0]))

	var ctx3 := await _rig([60, 61])
	var ed3 = ctx3.editor
	ed3.scale_context.keyswitches = PackedInt32Array([61])
	ed3.selection_manager.select_all(ed3.get_all_visual_notes())
	ed3._on_drag_started(_visual_for(ed3, ctx3.datas[0]), Vector2(100, ed3.layout.pitch_to_y(60) + h * 0.25))
	ed3._on_drag_updated(_visual_for(ed3, ctx3.datas[0]), Vector2(100, ed3.layout.pitch_to_y(61) + h * 0.25))
	_assert(ctx3.datas[0].note == 62 and ctx3.datas[1].note == 62, "keyswitch note moves by the row delta (+1 semitone)")
	ed3._on_drag_ended(_visual_for(ed3, ctx3.datas[0]))


func _test_conform_selection() -> void:
	var ctx := await _rig([61, 63, 66])
	var ed = ctx.editor
	var d: Array = ctx.datas
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	var recorded: Array = []
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	ed.conform_selection_to_scale()
	history_util.test_recorder = Callable()
	_assert([d[0].note, d[1].note, d[2].note] == [60, 62, 65], "conform [61, 63, 66] -> [60, 62, 65]")
	_assert(recorded.size() == 1, "conform is one undo step")
	if recorded.size() == 1:
		recorded[0].undo()
		_assert([d[0].note, d[1].note, d[2].note] == [61, 63, 66], "one undo restores the notes")
	ed.scale_context.scale = MusicalScale.new()
	ed.conform_selection_to_scale()
	_assert(d[0].note == 61, "no scale: conform does nothing")
