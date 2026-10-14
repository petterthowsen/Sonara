# test_audio_drop_length.gd
# Dropping an audio asset on a timeline track: the clip and its instance end up at the file's
# duration once it is known (the decode-ready callback corrects the placeholder instance), as
# part of the one undoable drop. Existing instances and MIDI drops are untouched.
#
# Run: godot --headless --path Godot -s tests/test_audio_drop_length.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"
const DURATION_S := 3.0  # 6 beats at 120 bpm, not the 4-beat placeholder
const SAMPLE_RATE := 48000


func suite_name() -> String:
	return "Audio drop length"


func run_tests() -> void:
	await _test_late_decode_corrects_instance()
	await _test_undo_redo_keeps_corrected_length()
	await _test_known_duration_used_immediately()
	await _test_midi_drop_unchanged()


func _rig() -> Dictionary:
	var root := Control.new()
	root.size = Vector2(1200, 600)
	get_root().add_child(root)
	var arranger: Control = load(ARRANGER_SCENE).instantiate()
	var editor: Node = load(EDITOR_SCRIPT).new()
	editor.arranger = arranger
	get_root().get_node("Sonara").editor = editor
	root.add_child(arranger)
	await process_frame
	var project: Object = load("res://data/Project.gd").new()
	project.tempo = 120.0
	var track: Object = project.create_instrument_track("A").track
	editor.project = project
	editor.project_activated.emit(project)
	await process_frame
	await process_frame
	var timeline: Control = arranger.timeline
	return {"root": root, "editor": editor, "project": project, "track": track,
		"row": timeline.timeline_tracks[0]}


func _cleanup(ctx: Dictionary) -> void:
	ctx.root.free()
	ctx.editor.free()
	await process_frame


func _asset(file: String) -> Object:
	var asset = load("res://browser/Asset.gd").new()
	asset.name = file
	asset.path = "/tmp/" + file
	asset.type = asset.TYPE.Midi if file.ends_with(".mid") else asset.TYPE.Audio
	return asset


func _decode_ready(project: Object, clip: Object) -> void:
	# Pretend the engine answered the clip's decode request
	project._record_clip_request(clip.id, "req_" + clip.id)
	project._on_audiofile_decode_ready(["req_" + clip.id, "key", 2, int(DURATION_S * SAMPLE_RATE), SAMPLE_RATE, DURATION_S])


func _drop(ctx: Dictionary, file: String, x: float) -> Object:
	var before: Array = ctx.track.clip_instances.duplicate()
	ctx.row._drop_data(Vector2(x, 10.0), _asset(file))
	for inst in ctx.track.clip_instances:
		if not before.has(inst):
			return inst
	return null


func _expected(project: Object) -> int:
	return int(DURATION_S * 120.0 / 60.0 * float(project.ppq))


func _test_late_decode_corrects_instance() -> void:
	var ctx := await _rig()
	var project: Object = ctx.project
	var other = ctx.track.create_clip_instance(project.create_clip("Existing", 0), 100000, 3840)
	var inst := _drop(ctx, "loop.wav", 0.0)
	_assert(inst != null, "drop creates an instance")
	_assert(inst.duration_ticks == project.ppq * 4, "starts at the placeholder length")
	_decode_ready(project, inst.clip)
	var expected := _expected(project)
	_assert(inst.clip.content_length_ticks == expected, "clip at file length (%d)" % inst.clip.content_length_ticks)
	_assert(inst.duration_ticks == expected, "instance corrected to file length (%d vs %d)" % [inst.duration_ticks, expected])
	_assert(inst.loop_length_ticks == expected, "loop length follows")
	_assert(other.duration_ticks == 3840, "unrelated existing instance untouched")
	await _cleanup(ctx)


func _test_undo_redo_keeps_corrected_length() -> void:
	var ctx := await _rig()
	var inst := _drop(ctx, "loop.wav", 0.0)
	_decode_ready(ctx.project, inst.clip)
	var expected := _expected(ctx.project)
	var history = ctx.editor.history
	_assert(history.undo_count() == 1, "the drop is one history entry, correction adds none (%d)" % history.undo_count())
	history.undo()
	_assert(not ctx.track.clip_instances.has(inst), "undo removes the instance")
	history.redo()
	_assert(ctx.track.clip_instances.has(inst) and inst.duration_ticks == expected,
		"redo restores the corrected length (%d)" % inst.duration_ticks)
	await _cleanup(ctx)


func _test_known_duration_used_immediately() -> void:
	var ctx := await _rig()
	var project: Object = ctx.project
	# Simulate already-known metadata: the clip is created, then the drop reads it
	var asset := _asset("known.wav")
	var clip = project.create_clip_from_asset(asset, Color.WHITE, 0)
	clip.set_audio_metadata(SAMPLE_RATE, 2, int(DURATION_S * SAMPLE_RATE), DURATION_S)
	_assert(clip.content_length_for_tempo(120.0, project.ppq) == _expected(project), "metadata gives file length")
	# Same path the drop takes when metadata is present
	clip.update_content_length_from_metadata(project.tempo, project.ppq)
	var inst = ctx.track.create_clip_instance(clip, 0, clip.content_length_ticks)
	_assert(inst.duration_ticks == _expected(project), "instance created at file length")
	await _cleanup(ctx)


func _test_midi_drop_unchanged() -> void:
	var ctx := await _rig()
	var inst := _drop(ctx, "tune.mid", 0.0)
	_assert(inst != null and inst.duration_ticks == ctx.project.ppq * 4, "MIDI drop keeps its default length")
	_assert(ctx.project._placeholder_commands.is_empty(), "MIDI drop is not tracked")
	await _cleanup(ctx)
