# test_clip_transpose.gd
# Headless tests for the clip context menu's Transpose -1 Oct / +1 Oct entries: they rewrite
# the selected MIDI clips' note pitches (destructively, clamped to 0-127) as one undo step,
# transpose a shared clip once, and are disabled for audio clips.
#
# ClipContextMenu references autoloads (Sonara, AudioEngineOSC), so it is loaded at run time
# rather than named as a global class.
#
# Run: godot --headless --path Godot -s tests/test_clip_transpose.gd -- --test
extends TestBase

const CLIP_AUDIO := 0  # Clip.ClipType.AUDIO
const CLIP_MIDI := 1   # Clip.ClipType.MIDI

var _instance_script: GDScript
var _clip_script: GDScript
var _history_util: GDScript
var _recorded: Array = []


func suite_name() -> String:
	return "Clip transpose"


func run_tests() -> void:
	_instance_script = load("res://data/ClipInstance.gd")
	_clip_script = load("res://data/Clip.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	await _test_menu_entries()
	await _test_octave_up_is_one_undo_step()
	await _test_octave_down_two_clips()
	await _test_shared_clip_transposes_once()
	await _test_pitches_clamp_to_range()


## A clip holding one note per pitch (tick 480 apart so nothing overlaps).
func _make_clip(clip_type: int, pitches: Array = []) -> Object:
	var clip = _clip_script.new("c")
	clip.type = clip_type
	clip.mark_synced_to_engine()
	var note_id := 1
	for pitch in pitches:
		var note := MidiNoteData.new()
		note.id = note_id
		note.note = pitch
		note.start_tick = (note_id - 1) * 480
		note.duration_ticks = 240
		clip.midi_notes.append(note)
		note_id += 1
	return clip


func _make_instance(clip) -> RefCounted:
	var inst = _instance_script.new("i_%d" % randi(), clip.id)
	inst.clip = clip
	return inst


func _pitches(clip) -> Array:
	var out: Array = []
	for note in clip.midi_notes:
		out.append(note.note)
	return out


## `bind_to_instances` wants Array[ClipInstance]; build one without naming the global class.
func _bind(menu: Object, instances: Array) -> void:
	var typed := Array([], TYPE_OBJECT, &"RefCounted", _instance_script)
	for inst in instances:
		typed.append(inst)
	menu.bind_to_instances(typed)


func _open_menu() -> Object:
	var scene: PackedScene = load("res://arranger/timeline/ClipContextMenu.tscn")
	var menu = scene.instantiate()
	root.add_child(menu)
	await process_frame
	return menu


## Click a transpose entry (through its wired signal), capturing the recorded undo step into
## `_recorded`. `semitones` picks the button the way a user would: +1 Oct or -1 Oct.
func _press(menu: Object, semitones: int) -> void:
	_recorded.clear()
	_history_util.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	if semitones > 0:
		menu.transpose_up.pressed.emit()
	else:
		menu.transpose_down.pressed.emit()
	_history_util.test_recorder = Callable()


func _test_menu_entries() -> void:
	var menu := await _open_menu()

	var midi = _make_instance(_make_clip(CLIP_MIDI, [60]))
	_bind(menu, [midi])
	_assert(not menu.transpose_up.disabled, "transpose up is enabled for a MIDI clip")
	_assert(not menu.transpose_down.disabled, "transpose down is enabled for a MIDI clip")

	var audio = _make_instance(_make_clip(CLIP_AUDIO))
	_bind(menu, [audio])
	_assert(menu.transpose_up.disabled and menu.transpose_down.disabled,
		"transpose is disabled for an audio clip")

	_bind(menu, [midi, audio])
	_assert(menu.transpose_up.disabled and menu.transpose_down.disabled,
		"transpose is disabled when the selection mixes clip types")

	_bind(menu, [])
	_assert(menu.transpose_up.disabled and menu.transpose_down.disabled,
		"transpose is disabled with an empty selection")

	menu.free()


func _test_octave_up_is_one_undo_step() -> void:
	var menu := await _open_menu()
	var clip := _make_clip(CLIP_MIDI, [60, 64])
	var inst := _make_instance(clip)
	_bind(menu, [inst])

	_press(menu, 12)

	_assert(_pitches(clip) == [72, 76], "the notes move up an octave, got %s" % [_pitches(clip)])
	_assert(_recorded.size() == 1, "the transpose is one undo step, got %d" % _recorded.size())
	if _recorded.size() == 1:
		_recorded[0].undo()
		_assert(_pitches(clip) == [60, 64], "undo restores the original pitches")
		_recorded[0].do()
		_assert(_pitches(clip) == [72, 76], "redo transposes again")
	menu.free()


func _test_octave_down_two_clips() -> void:
	var menu := await _open_menu()
	var low := _make_clip(CLIP_MIDI, [60])
	var high := _make_clip(CLIP_MIDI, [72])
	_bind(menu, [_make_instance(low), _make_instance(high)])

	_press(menu, -12)

	_assert(_pitches(low) == [48] and _pitches(high) == [60],
		"both clips' notes move down an octave")
	_assert(_recorded.size() == 1, "two clips transpose as one undo step")
	if _recorded.size() == 1:
		_recorded[0].undo()
		_assert(_pitches(low) == [60] and _pitches(high) == [72],
			"one undo restores both clips")
	menu.free()


func _test_shared_clip_transposes_once() -> void:
	var menu := await _open_menu()
	var clip := _make_clip(CLIP_MIDI, [60])
	_bind(menu, [_make_instance(clip), _make_instance(clip)])

	_press(menu, 12)
	_assert(_pitches(clip) == [72], "a clip shared by two selected instances moves once")
	menu.free()


func _test_pitches_clamp_to_range() -> void:
	var menu := await _open_menu()
	var clip := _make_clip(CLIP_MIDI, [120, 5, 100])
	_bind(menu, [_make_instance(clip)])

	_press(menu, 12)
	_assert(_pitches(clip) == [127, 17, 112],
		"up an octave stops at 127, got %s" % [_pitches(clip)])

	_press(menu, -12)
	_assert(_pitches(clip) == [115, 5, 100],
		"down an octave stops at 0, got %s" % [_pitches(clip)])
	menu.free()
