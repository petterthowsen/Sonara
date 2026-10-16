# test_note_transfer.gd
# Spec 048 REQ-040..043: NoteTransfer.plan decides which clip instance of the target track takes
# each note, how it grows, and which new clips are needed. NoteTransfer.apply, Transfer Notes and
# Split Voices (NoteEditor) then carry it out as one undo step.
#
# Run: godot --headless --path Godot -s tests/test_note_transfer.gd -- --test
extends TestBase

const BAR := 3840

var _project_script: GDScript


func suite_name() -> String:
	return "Note transfer plan"


func run_tests() -> void:
	# Loaded at run time: naming Project would compile it before the autoloads exist.
	_project_script = load("res://data/Project.gd")
	_test_covered()
	_test_extended()
	_test_new_clip_not_stretched()
	_test_gap_note_new_clip()
	_test_two_overlapping_clips()
	_test_leftover_in_gap_extends_earlier_clip()
	_test_looped_target()
	_test_extend_start()
	_test_extend_start_with_offset()
	_test_runs_and_bars()
	_test_linked_targets()
	_test_apply_cases()
	_test_apply_extend_start_shifts_existing_notes()
	_test_apply_linked_target()
	await _test_editor_transfer()
	await _test_editor_split_voices()


## A project with a target track holding a clip instance per `(start_bar, bars)` pair (bar 1-based).
func _rig(spans: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var track: Object = project.create_instrument_track("Target").track
	var instances: Array = []
	for span: Array in spans:
		var clip: Object = project.create_clip("C%d" % instances.size())
		project.add_clip(clip)
		clip.add_midi_note(project.allocate_note_id(), 60, 0.8, 0, 480)
		instances.append(track.create_clip_instance(clip, (span[0] - 1) * BAR, span[1] * BAR))
	return {"project": project, "track": track, "instances": instances}


## A note starting `bar` (1-based) plus `offset` ticks, in song ticks.
func _note(bar: int, offset: int = 0, dur: int = 480, pitch: int = 64) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.note = pitch
	n.start_tick = (bar - 1) * BAR + offset
	n.duration_ticks = dur
	return n


func _test_covered() -> void:
	var rig := _rig([[1, 4]])
	var notes := [_note(2), _note(2, 960)]
	var plan := NoteTransfer.plan(rig.project, rig.track, notes)
	_assert(plan.size() == 1 and plan[0].instance == rig.instances[0], "notes inside a clip go into it")
	_assert(not plan[0].extended and plan[0].new_start == 0 and plan[0].new_duration == 4 * BAR, "the clip is not changed")
	_assert(plan[0].clip_ticks == PackedInt32Array([BAR, BAR + 960]), "clip ticks follow the song positions")
	_assert(plan[0].notes == notes, "the plan lists the notes")
	_assert(NoteTransfer.plan(rig.project, rig.track, []).is_empty(), "no notes, no plan")


func _test_extended() -> void:
	var rig := _rig([[1, 4]])
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(3), _note(4), _note(5)])
	_assert(plan.size() == 1 and plan[0].instance == rig.instances[0], "notes on bars 3-5 go into the bars 1-4 clip")
	_assert(plan[0].extended and plan[0].new_start == 0 and plan[0].new_duration == 5 * BAR,
			"the clip is extended to end at bar 5 (got %d..%d)" % [plan[0].new_start, plan[0].new_start + plan[0].new_duration])
	_assert(plan[0].new_clip_offset == 0 and plan[0].clip_shift == 0, "extending the end touches neither offset nor content")
	_assert(plan[0].new_content_length >= 5 * BAR - 3000, "the content length covers the new notes")
	# A note that starts inside the clip but runs past its end also grows it.
	var spill := NoteTransfer.plan(rig.project, rig.track, [_note(4, 3000, 2000)])
	_assert(spill[0].instance == rig.instances[0] and spill[0].new_duration == 5 * BAR, "a note sticking out past the end grows the clip to the next bar line")


func _test_new_clip_not_stretched() -> void:
	var rig := _rig([[1, 4]])
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(3), _note(4), _note(5), _note(9)])
	_assert(plan.size() == 2, "bars 3-5 form one run, bar 9 another (got %d entries)" % plan.size())
	_assert(plan[0].instance == rig.instances[0] and plan[0].new_duration == 5 * BAR, "bars 3-5 extend the clip to bar 5")
	_assert(plan[1].instance == null and plan[1].new_start == 8 * BAR and plan[1].new_duration == BAR,
			"a note on bar 9 gets a new one-bar clip on bar 9")
	_assert(plan[1].clip_ticks == PackedInt32Array([0]), "a new clip starts at its first bar")
	_assert(plan[1].new_content_length == BAR, "the new clip is one bar long")
	var alone := NoteTransfer.plan(rig.project, rig.track, [_note(9)])
	_assert(alone.size() == 1 and alone[0].instance == null and rig.instances[0].duration_ticks == 4 * BAR,
			"the bars 1-4 clip is not stretched to bar 9")


func _test_gap_note_new_clip() -> void:
	# A note right after a clip's end does not overlap it, so it gets its own clip.
	var rig := _rig([[1, 2]])
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(3)])
	_assert(plan.size() == 1 and plan[0].instance == null and plan[0].new_start == 2 * BAR,
			"a note on the bar right after a clip gets a new clip; clips that don't overlap are never stretched")
	# A long note running into the clip's bars does overlap it.
	var overlap := NoteTransfer.plan(rig.project, rig.track, [_note(1, 0, 2 * BAR)])
	_assert(overlap[0].instance == rig.instances[0], "a note covering the clip's bars goes into it")


func _test_two_overlapping_clips() -> void:
	var rig := _rig([[1, 2], [3, 2]])  # A: bars 1-2, B: bars 3-4, touching.
	var notes := [_note(2), _note(2, 3000, 960), _note(3), _note(4)]
	var plan := NoteTransfer.plan(rig.project, rig.track, notes)
	_assert(plan.size() == 2, "the run overlaps both clips (got %d entries)" % plan.size())
	_assert(plan[0].instance == rig.instances[0] and plan[0].notes.size() == 2,
			"the earliest clip takes the notes it covers (bar 2)")
	_assert(plan[1].instance == rig.instances[1] and plan[1].notes.size() == 2, "the next clip takes the rest (bars 3 and 4)")
	_assert(not plan[0].extended, "the first clip cannot grow into the second one")
	# Bar 5 sticks out of the later clip only.
	var beyond := NoteTransfer.plan(rig.project, rig.track, [_note(2), _note(4), _note(5)])
	_assert(beyond.size() == 2 and beyond[1].instance == rig.instances[1] and beyond[1].new_duration == 3 * BAR,
			"a note past the end grows the clip that can grow")


func _test_leftover_in_gap_extends_earlier_clip() -> void:
	var rig := _rig([[1, 2], [4, 2]])  # A: bars 1-2, B: bars 4-5, bar 3 free.
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(2), _note(3)])
	_assert(plan.size() == 1 and plan[0].instance == rig.instances[0] and plan[0].new_duration == 3 * BAR,
			"a note in the gap after a covered note grows the earlier clip up to its neighbour")
	var wall := NoteTransfer.plan(rig.project, rig.track, [_note(3), _note(4)])
	_assert(wall[0].instance == rig.instances[1] and wall[0].new_start == 2 * BAR and wall[0].new_duration == 3 * BAR,
			"a gap note touching only the later clip grows it to the left")
	_assert(wall[0].clip_shift == BAR and wall[0].new_clip_offset == 0, "growing left of untrimmed content shifts the existing notes one bar later")


func _test_looped_target() -> void:
	var rig := _rig([[1, 2]])
	var inst: Object = rig.instances[0]
	inst.set_loop(true, 0, BAR)
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(2, 960), _note(3)])
	_assert(plan.size() == 2, "a looped clip takes only the notes inside it (got %d entries)" % plan.size())
	_assert(plan[0].instance == inst and plan[0].looped and not plan[0].extended, "the looped clip is never extended")
	_assert(plan[0].clip_ticks == PackedInt32Array([960]), "a note in the second pass folds into the loop region")
	_assert(plan[1].instance == null and plan[1].new_start == 2 * BAR, "the note beyond it gets a new clip")


func _test_extend_start() -> void:
	var rig := _rig([[3, 2]])  # bars 3-4, clip_offset 0
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(2), _note(3)])
	_assert(plan.size() == 1 and plan[0].instance == rig.instances[0], "bars 2-3 go into the clip on bars 3-4")
	_assert(plan[0].new_start == BAR and plan[0].new_duration == 3 * BAR, "the clip now starts at bar 2")
	_assert(plan[0].clip_shift == BAR and plan[0].new_clip_offset == 0,
			"its content has no room on the left, so the existing notes shift one bar later")
	_assert(plan[0].clip_ticks == PackedInt32Array([0, BAR]), "new notes are placed against the shifted content")
	_assert(plan[0].new_content_length >= 3 * BAR, "the content length grows with the shift")


func _test_extend_start_with_offset() -> void:
	var rig := _rig([[3, 2]])
	var inst: Object = rig.instances[0]
	inst.clip_offset = BAR  # trimmed: content tick 3840 sits at bar 3, content origin = bar 2
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(2)])
	_assert(plan[0].new_start == BAR and plan[0].new_clip_offset == 0 and plan[0].clip_shift == 0,
			"trimmed content is revealed instead of shifted: offset 3840 -> 0, existing notes keep their ticks")
	_assert(plan[0].clip_ticks == PackedInt32Array([0]), "the note lands at content tick 0")


func _test_runs_and_bars() -> void:
	# Notes in the same bar are one run; a gap of a free bar separates runs.
	var rig := _rig([])
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(1), _note(1, 2000), _note(2), _note(4)])
	_assert(plan.size() == 2 and plan[0].new_start == 0 and plan[0].new_duration == 2 * BAR, "bars 1-2 are one new clip")
	_assert(plan[1].new_start == 3 * BAR and plan[1].new_duration == BAR, "bar 4 is another")
	# A note ending exactly on a bar line does not reach into the next bar.
	var exact := NoteTransfer.plan(rig.project, rig.track, [_note(1, 0, BAR)])
	_assert(exact[0].new_duration == BAR, "a note ending on a bar line spans only its own bar")
	# Other time signatures: 3/4 bars are 2880 ticks.
	rig.project.time_numerator = 3
	var waltz := NoteTransfer.plan(rig.project, rig.track, [_n_at(2900)])
	_assert(waltz[0].new_start == 2880 and waltz[0].new_duration == 2880, "bars follow the project time signature")


func _n_at(tick: int) -> MidiNoteData:
	var n := MidiNoteData.new()
	n.start_tick = tick
	n.duration_ticks = 100
	return n


func _test_linked_targets() -> void:
	var rig := _rig([[1, 4]])
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(2)])
	_assert(NoteTransfer.linked_targets(rig.project, plan).is_empty(), "an unshared clip is not linked")
	var other: Object = rig.project.create_instrument_track("Other").track
	other.create_clip_instance(rig.instances[0].clip, 0, 4 * BAR)
	var linked := NoteTransfer.linked_targets(rig.project, plan)
	_assert(linked.size() == 1 and linked[0] == rig.instances[0].clip, "a clip used by two instances is reported")
	var fresh := NoteTransfer.plan(rig.project, rig.track, [_note(9)])
	_assert(NoteTransfer.linked_targets(rig.project, fresh).is_empty(), "a new clip is never linked")


# --- apply (T-013) --------------------------------------------------------------------------

var _recorded: Array = []


func _record_start() -> void:
	_recorded.clear()
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = func(cmd) -> void: _recorded.append(cmd)


func _record_stop() -> void:
	var history_util: GDScript = load("res://history/HistoryUtil.gd")
	history_util.test_recorder = Callable()


## Song-tick starts of every note on a track, sorted, as "pitch@tick".
func _song_notes(track: Object) -> Array:
	var out := []
	for inst in track.clip_instances:
		for n: MidiNoteData in inst.clip.midi_notes:
			out.append("%d@%d" % [n.note, inst.clip_to_song_ticks(n.start_tick)])
	out.sort()
	return out


## Everything undo has to restore: instances (start, duration, offset), clip lengths and notes.
func _world(project: Object) -> Array:
	var out := []
	for track in project.tracks:
		for inst in track.clip_instances:
			var notes := []
			for n: MidiNoteData in inst.clip.midi_notes:
				notes.append([n.id, n.note, n.start_tick, n.duration_ticks])
			notes.sort()
			out.append([track.name, inst.start_ticks, inst.duration_ticks, inst.clip_offset, inst.clip.content_length_ticks, notes])
	out.sort()
	return out


func _source_rig(spans: Array) -> Dictionary:
	var rig := _rig(spans)
	var source: Object = rig.project.create_instrument_track("Source").track
	rig["source"] = source
	return rig


func _apply_to_target(rig: Dictionary, song_notes: Array) -> void:
	var plan := NoteTransfer.plan(rig.project, rig.track, song_notes)
	_record_start()
	NoteTransfer.apply(rig.project, {}, [{"track": rig.track, "entries": plan}], "Transfer Notes")
	_record_stop()


func _test_apply_cases() -> void:
	# Covered: notes land inside the existing clip.
	var rig := _rig([[1, 4]])
	var before := _world(rig.project)
	_apply_to_target(rig, [_note(2, 0, 480, 70), _note(2, 960, 480, 72)])
	_assert(_song_notes(rig.track).has("70@%d" % BAR) and _song_notes(rig.track).has("72@%d" % (BAR + 960)),
			"covered: the notes sit at the same song ticks in the existing clip")
	_assert(_recorded.size() == 1, "apply records one undo step")
	_assert(rig.instances[0].duration_ticks == 4 * BAR, "covered: the clip is untouched")
	_recorded[0].undo()
	_assert(_world(rig.project) == before, "covered: one undo restores the notes")
	_recorded[0].do()
	_assert(_song_notes(rig.track).has("70@%d" % BAR), "covered: redo applies it again")

	# Extended: bars 3-5 into a bars 1-4 clip.
	rig = _rig([[1, 4]])
	before = _world(rig.project)
	_apply_to_target(rig, [_note(3, 0, 480, 70), _note(4, 0, 480, 71), _note(5, 0, 480, 72)])
	_assert(rig.instances[0].start_ticks == 0 and rig.instances[0].duration_ticks == 5 * BAR, "extended: the clip now ends at bar 5")
	_assert(_song_notes(rig.track).has("72@%d" % (4 * BAR)) and _song_notes(rig.track).has("70@%d" % (2 * BAR)),
			"extended: notes keep their song ticks")
	_assert(rig.instances[0].clip.content_length_ticks >= 5 * BAR - 3000, "extended: the content length grows")
	_assert(_recorded.size() == 1, "extended: one step")
	_recorded[0].undo()
	_assert(_world(rig.project) == before, "extended: one undo restores the span, the length and the notes")

	# New clip: a note on bar 9 with no stretch of the bars 1-4 clip.
	rig = _rig([[1, 4]])
	before = _world(rig.project)
	var clips_before: int = rig.project.clips.size()
	_apply_to_target(rig, [_note(9, 0, 480, 75)])
	_assert(rig.track.clip_instances.size() == 2 and rig.instances[0].duration_ticks == 4 * BAR, "new clip: a second instance, the first untouched")
	var created: Object = rig.track.clip_instances[1]
	_assert(created.start_ticks == 8 * BAR and created.duration_ticks == BAR and _song_notes(rig.track).has("75@%d" % (8 * BAR)),
			"new clip: one bar at bar 9 holding the note")
	_assert(rig.project.clips.size() == clips_before + 1, "new clip: it is in the project pool")
	_assert(_recorded.size() == 1, "new clip: one step")
	_recorded[0].undo()
	_assert(_world(rig.project) == before and rig.project.clips.size() == clips_before, "new clip: undo removes the instance and the clip")
	_recorded[0].do()
	_assert(rig.track.clip_instances.size() == 2 and _song_notes(rig.track).has("75@%d" % (8 * BAR)), "new clip: redo brings it back with its note")

	# Two overlapping clips in one run.
	rig = _rig([[1, 2], [3, 2]])
	before = _world(rig.project)
	_apply_to_target(rig, [_note(2, 0, 480, 70), _note(3, 0, 480, 71)])
	_assert(rig.instances[0].clip.midi_notes.size() == 2 and rig.instances[1].clip.midi_notes.size() == 2, "two clips: each takes its own note")
	_assert(_recorded.size() == 1, "two clips: one step")
	_recorded[0].undo()
	_assert(_world(rig.project) == before, "two clips: one undo restores both")

	# Looped target: notes fold into the loop and the clip does not grow.
	rig = _rig([[1, 4]])
	rig.instances[0].set_loop(true, 0, BAR)
	before = _world(rig.project)
	_apply_to_target(rig, [_note(3, 960, 480, 70)])
	_assert(rig.instances[0].duration_ticks == 4 * BAR, "looped: not extended")
	var folded := false
	for n: MidiNoteData in rig.instances[0].clip.midi_notes:
		if n.note == 70:
			folded = n.start_tick == 960
	_assert(folded, "looped: the note was folded into the loop region")
	_recorded[0].undo()
	_assert(_world(rig.project) == before, "looped: undo restores")


func _test_apply_extend_start_shifts_existing_notes() -> void:
	var rig := _rig([[3, 2]])  # bars 3-4, with its own note at clip tick 0 (song bar 3)
	var before := _world(rig.project)
	var existing_song := _song_notes(rig.track)
	_apply_to_target(rig, [_note(2, 0, 480, 70), _note(3, 0, 480, 71)])
	_assert(rig.instances[0].start_ticks == BAR and rig.instances[0].duration_ticks == 3 * BAR, "start extended: the clip begins at bar 2")
	var after := _song_notes(rig.track)
	_assert(after.has("60@%d" % (2 * BAR)) and after.has("70@%d" % BAR), "start extended: existing notes keep their song ticks (%s)" % [after])
	_assert(existing_song.size() == 1 and after.size() == 3, "start extended: two notes were added")
	_assert(_recorded.size() == 1, "start extended: one step")
	_recorded[0].undo()
	_assert(_world(rig.project) == before, "start extended: undo restores offsets, spans and note ticks")
	# A trimmed clip reveals its hidden content instead of shifting notes.
	var trimmed := _rig([[3, 2]])
	trimmed.instances[0].clip_offset = BAR
	var trimmed_before := _world(trimmed.project)
	var trimmed_song := _song_notes(trimmed.track)
	_apply_to_target(trimmed, [_note(2, 0, 480, 70), _note(3, 0, 480, 71)])
	_assert(trimmed.instances[0].clip_offset == 0 and trimmed.instances[0].start_ticks == BAR, "trimmed clip: the offset shrinks")
	_assert(_song_notes(trimmed.track).has(trimmed_song[0]), "trimmed clip: existing notes keep their song ticks")
	_recorded[0].undo()
	_assert(_world(trimmed.project) == trimmed_before, "trimmed clip: undo restores the offset")


func _test_apply_linked_target() -> void:
	var rig := _rig([[1, 4]])
	var other: Object = rig.project.create_instrument_track("Other").track
	var linked: Object = other.create_clip_instance(rig.instances[0].clip, 4 * BAR, 4 * BAR)
	var plan := NoteTransfer.plan(rig.project, rig.track, [_note(2, 0, 480, 70)])
	_assert(NoteTransfer.linked_targets(rig.project, plan) == [rig.instances[0].clip], "the linked clip is reported before applying")
	_apply_to_target(rig, [_note(2, 0, 480, 70)])
	_assert(_song_notes(rig.track).has("70@%d" % BAR) and _song_notes(other).has("70@%d" % (5 * BAR)),
			"both instances of the linked clip show the new note")
	_assert(linked.clip == rig.instances[0].clip, "the instances still share one clip")


# --- editor: Transfer Notes (T-013) and Split Voices (T-014) ----------------------------------

func _editor_rig(notes: Array, extra_tracks: int = 0) -> Dictionary:
	var project: Object = _project_script.new()
	var source: Object = project.create_instrument_track("Source").track
	var clip: Object = project.create_clip("Src")
	var made: Array = []
	for t: Array in notes:
		made.append(clip.add_midi_note(project.allocate_note_id(), t[0], 0.8, t[1], t[2]))
	var inst: Object = source.create_clip_instance(clip, 0, 4 * BAR)
	var targets: Array = []
	for i in extra_tracks:
		targets.append(project.create_instrument_track("Target %d" % (i + 1)).track)
	var ed = load("res://clip_editor/note_editor/NoteEditor.gd").new()
	ed.set_grid_helper(load("res://components/GridHelper.gd").new())
	root.add_child(ed)
	var instances := Array([inst], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd"))
	ed.bind_to_clips(instances, source)
	await process_frame
	return {"project": project, "source": source, "clip": clip, "inst": inst, "targets": targets, "ed": ed, "notes": made}


func _test_editor_transfer() -> void:
	var ctx := await _editor_rig([[60, BAR, 480], [64, 2 * BAR, 480]], 1)
	var ed = ctx.ed
	var target: Object = ctx.targets[0]
	var before := _world(ctx.project)
	_assert(not ed.can_transfer(), "nothing selected: Transfer is not available")
	ed.selection_manager.select_all(ed.get_all_visual_notes())
	_assert(ed.can_transfer() and ed.is_transfer_target(target) and not ed.is_transfer_target(ctx.source), "a track other than the source is a target")
	_assert(ed.transfer_linked_clips(target).is_empty(), "an empty target has no linked clips")
	_record_start()
	var moved: int = ed.transfer_selection(target)
	_record_stop()
	_assert(moved == 2, "two notes moved (got %d)" % moved)
	_assert(ctx.clip.midi_notes.is_empty(), "none are left on the source")
	_assert(_song_notes(target) == ["60@%d" % BAR, "64@%d" % (2 * BAR)], "the notes sit at the same song ticks on the target (%s)" % [_song_notes(target)])
	_assert(target.clip_instances.size() == 1 and target.clip_instances[0].start_ticks == BAR and target.clip_instances[0].duration_ticks == 2 * BAR,
			"a new two-bar clip was made on the target")
	_assert(_recorded.size() == 1, "Transfer Notes is one undo step")
	await process_frame
	_assert(ed.get_all_visual_notes().is_empty(), "the source editor shows no notes any more")
	_recorded[0].undo()
	await process_frame
	_assert(_world(ctx.project) == before, "one undo restores both tracks")
	_assert(ed.get_all_visual_notes().size() == 2, "the source notes are back in the editor")
	_assert(ed.transfer_selection(ctx.source) == 0, "the source track is not a target")
	ed.queue_free()

	# Transfer into an existing, shared clip: both instances show the notes.
	var linked := await _editor_rig([[60, 0, 480]], 1)
	var shared: Object = linked.project.create_clip("Shared")
	linked.project.add_clip(shared)
	var target_inst: Object = linked.targets[0].create_clip_instance(shared, 0, 2 * BAR)
	var mirror_track: Object = linked.project.create_instrument_track("Mirror").track
	var mirror: Object = mirror_track.create_clip_instance(shared, 8 * BAR, 2 * BAR)
	linked.ed.selection_manager.select_all(linked.ed.get_all_visual_notes())
	_assert(linked.ed.transfer_linked_clips(linked.targets[0]) == [shared], "the linked target clip is reported")
	linked.ed.transfer_selection(linked.targets[0])
	_assert(_song_notes(linked.targets[0]) == ["60@0"] and _song_notes(mirror_track) == ["60@%d" % (8 * BAR)], "both instances of the linked clip show the transferred note")
	_assert(target_inst.clip == mirror.clip, "still one shared clip")
	linked.ed.queue_free()


func _test_editor_split_voices() -> void:
	# A 4-voice pad on the source, the source plus two tracks below it selected (REQ-041).
	var pad := [[48, 0, 960], [55, 0, 960], [64, 0, 960], [72, 0, 960],
			[50, BAR, 960], [57, BAR, 960], [65, BAR, 960], [74, BAR, 960]]
	var ctx := await _editor_rig(pad, 2)
	var ed = ctx.ed
	var t1: Object = ctx.targets[0]
	var t2: Object = ctx.targets[1]
	var before := _world(ctx.project)
	_assert(not ed.has_split_targets([ctx.source]), "only the source selected: no targets (disabled, REQ-042)")
	_assert(not ed.can_split_voices([ctx.source]), "Split Voices is unavailable with only the source selected")
	_assert(not ed.has_split_targets([]), "no selected tracks: no targets")
	_assert(ed.has_split_targets([t1]) and ed.can_split_voices([ctx.source, t1, t2]), "a non-source track makes it available")
	# Track order, not selection order.
	var ordered: Array = ed.split_target_tracks([t2, ctx.source, t1])
	_assert(ordered == [ctx.source, t1, t2], "targets follow the project track order, the source keeping its place")
	_record_start()
	var moved: int = ed.split_voices([t2, ctx.source, t1])
	_record_stop()
	_assert(moved == 4, "voices 2 and 3 of two chords moved (got %d)" % moved)
	var on_source := []
	for n: MidiNoteData in ctx.clip.midi_notes:
		on_source.append(n.note)
	on_source.sort()
	_assert(on_source == [48, 50, 72, 74], "voices 1 (top) and 4 (bottom) stay on the source")
	_assert(_song_notes(t1) == ["64@0", "65@%d" % BAR], "voice 2 went to the next track (%s)" % [_song_notes(t1)])
	_assert(_song_notes(t2) == ["55@0", "57@%d" % BAR], "voice 3 went to the one after (%s)" % [_song_notes(t2)])
	_assert(_recorded.size() == 1, "Split Voices is one undo step")
	_recorded[0].undo()
	_assert(_world(ctx.project) == before, "one undo restores all three tracks")
	_recorded[0].do()
	_assert(_song_notes(t1).size() == 2 and _song_notes(t2).size() == 2, "redo splits again")
	ed.queue_free()

	# The source not selected: voice 1 goes to the first selected track.
	var two := await _editor_rig([[60, 0, 960], [64, 0, 960], [67, 0, 960]], 2)
	_record_start()
	two.ed.split_voices([two.targets[0], two.targets[1]])
	_record_stop()
	_assert(_song_notes(two.targets[0]) == ["67@0"] and _song_notes(two.targets[1]) == ["64@0"] and two.clip.midi_notes.size() == 1,
			"without the source in the list voice 1 and 2 go to the selected tracks, voice 3 stays")
	two.ed.queue_free()
