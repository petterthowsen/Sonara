# test_clip_scale.gd
# Headless tests for the clip context menu's Scale Half / Scale Double entries: they scale note
# positions and lengths, the clip's content length and every instance's duration, offset and
# loop region, as one undo step, with a minimum note length and shared clips scaling once.
#
# Run: godot --headless --path Godot -s tests/test_clip_scale.gd -- --test
extends TestBase

var _instance_script: GDScript
var _clip_script: GDScript
var _history_util: GDScript
var _recorded: Array = []


func suite_name() -> String:
	return "Clip scale"


func run_tests() -> void:
	_instance_script = load("res://data/ClipInstance.gd")
	_clip_script = load("res://data/Clip.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	await _test_menu_entries()
	await _test_double_and_undo()
	await _test_half_rounding_and_minimum()
	await _test_instance_loop_and_offset()
	await _test_shared_clip_scales_once()
	await _test_double_clamps_to_next_clip()
	await _test_shared_clip_across_tracks_clamps()
	await _test_half_trims_note_overlaps()
	await _test_project_wide_scales_unselected_instances()


func _make_clip(notes: Array, length: int = 3840) -> Object:
	var clip = _clip_script.new("c")
	clip.type = 1
	clip.mark_synced_to_engine()
	clip.content_length_ticks = length
	var id := 1
	for n in notes:
		var note := MidiNoteData.new()
		note.id = id
		note.note = 60
		note.start_tick = n[0]
		note.duration_ticks = n[1]
		clip.midi_notes.append(note)
		id += 1
	return clip


func _make_instance(clip, duration: int = 3840) -> RefCounted:
	var inst = _instance_script.new("i_%d" % randi(), clip.id)
	inst.clip = clip
	inst.duration_ticks = duration
	return inst


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


func _press(button: Button) -> void:
	_recorded.clear()
	_history_util.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	button.pressed.emit()
	_history_util.test_recorder = Callable()


func _notes(clip) -> Array:
	var out: Array = []
	for n in clip.midi_notes:
		out.append([n.start_tick, n.duration_ticks])
	return out


func _test_menu_entries() -> void:
	var menu := await _open_menu()
	_assert(menu.scale_half.text == "Scale Half" and menu.scale_double.text == "Scale Double",
		"the row has Scale Half and Scale Double")
	_assert(menu.scale_half.get_parent() == menu.scale_double.get_parent()
		and menu.scale_half.get_index() < menu.scale_double.get_index(),
		"Scale Half is left of Scale Double on one row")
	var midi = _make_instance(_make_clip([[0, 480]]))
	_bind(menu, [midi])
	_assert(not menu.scale_half.disabled and not menu.scale_double.disabled, "enabled for MIDI")
	var audio_clip = _make_clip([])
	audio_clip.type = 0
	_bind(menu, [_make_instance(audio_clip)])
	_assert(menu.scale_half.disabled and menu.scale_double.disabled, "disabled for audio")
	menu.free()


func _test_double_and_undo() -> void:
	var menu := await _open_menu()
	var clip := _make_clip([[0, 480], [960, 240]])
	var inst := _make_instance(clip)
	_bind(menu, [inst])
	_press(menu.scale_double)
	_assert(_notes(clip) == [[0, 960], [1920, 480]], "notes double, got %s" % [_notes(clip)])
	_assert(clip.content_length_ticks == 7680, "content length doubles, got %d" % clip.content_length_ticks)
	_assert(inst.duration_ticks == 7680, "instance duration doubles, got %d" % inst.duration_ticks)
	_assert(_recorded.size() == 1, "one undo step, got %d" % _recorded.size())
	if _recorded.size() == 1:
		_recorded[0].undo()
		_assert(_notes(clip) == [[0, 480], [960, 240]], "undo restores notes, got %s" % [_notes(clip)])
		_assert(clip.content_length_ticks == 3840 and inst.duration_ticks == 3840,
			"undo restores clip and instance length")
		_recorded[0].do()
		_assert(_notes(clip) == [[0, 960], [1920, 480]] and inst.duration_ticks == 7680,
			"redo scales again")
	menu.free()


func _test_half_rounding_and_minimum() -> void:
	var menu := await _open_menu()
	var clip := _make_clip([[0, 1], [3, 5], [960, 480]], 3841)
	_bind(menu, [_make_instance(clip, 3841)])
	_press(menu.scale_half)
	for n in clip.midi_notes:
		_assert(n.duration_ticks >= 1, "no note shorter than 1 tick")
	_assert(_notes(clip)[2] == [480, 240], "regular note halves, got %s" % [_notes(clip)[2]])
	_assert(clip.content_length_ticks == 1920 or clip.content_length_ticks == 1921,
		"odd content length rounds, got %d" % clip.content_length_ticks)
	menu.free()


func _test_instance_loop_and_offset() -> void:
	var menu := await _open_menu()
	var clip := _make_clip([[0, 480]])
	var inst := _make_instance(clip, 1920)
	inst.start_ticks = 960
	inst.clip_offset = 480
	inst.loop_enabled = true
	inst.loop_start_ticks = 480
	inst.loop_length_ticks = 960
	_bind(menu, [inst])
	_press(menu.scale_half)
	_assert(inst.start_ticks == 960, "start position stays")
	_assert(inst.duration_ticks == 960 and inst.clip_offset == 240, "duration and offset halve")
	_assert(inst.loop_enabled and inst.loop_start_ticks == 240 and inst.loop_length_ticks == 480,
		"loop region halves")
	_recorded[0].undo()
	_assert(inst.duration_ticks == 1920 and inst.clip_offset == 480
		and inst.loop_start_ticks == 480 and inst.loop_length_ticks == 960, "undo restores instance")
	menu.free()


func _test_shared_clip_scales_once() -> void:
	var menu := await _open_menu()
	var clip := _make_clip([[0, 480]])
	var a := _make_instance(clip)
	var b := _make_instance(clip, 1920)
	_bind(menu, [a, b])
	_press(menu.scale_double)
	_assert(_notes(clip) == [[0, 960]], "shared clip scaled once, got %s" % [_notes(clip)])
	_assert(a.duration_ticks == 7680 and b.duration_ticks == 3840, "each instance scales")
	menu.free()


func _track_with(instances: Array) -> Object:
	var track = load("res://data/Track.gd").new(900 + randi() % 1000)
	for inst in instances:
		track.clip_instances.append(inst)
		inst.track = track
	return track


func _test_double_clamps_to_next_clip() -> void:
	var menu := await _open_menu()
	var clip := _make_clip([[0, 480]], 1920)
	var other := _make_clip([[0, 480]], 1920)
	var a := _make_instance(clip, 1920)
	a.start_ticks = 0
	var b := _make_instance(other, 1920)
	b.start_ticks = 2880
	_track_with([a, b])
	_bind(menu, [a])
	_press(menu.scale_double)
	_assert(a.duration_ticks == 2880, "doubled instance ends at the next clip, got %d" % a.duration_ticks)
	_assert(clip.content_length_ticks == 3840 and _notes(clip) == [[0, 960]], "clip content still doubles")
	_assert(b.duration_ticks == 1920 and b.start_ticks == 2880, "neighbour is untouched")
	_assert(_recorded.size() == 1, "clamping is part of the single undo step")
	_recorded[0].undo()
	_assert(a.duration_ticks == 1920 and clip.content_length_ticks == 1920
		and _notes(clip) == [[0, 480]], "undo restores instance, length and notes")
	_recorded[0].do()
	_assert(a.duration_ticks == 2880, "redo keeps the clamp")
	menu.free()


func _test_shared_clip_across_tracks_clamps() -> void:
	var menu := await _open_menu()
	var clip := _make_clip([[0, 480]], 1920)
	var other := _make_clip([[0, 480]], 1920)
	var a := _make_instance(clip, 1920)
	var shared := _make_instance(clip, 1920)
	shared.start_ticks = 960
	var blocker := _make_instance(other, 960)
	blocker.start_ticks = 3000
	_track_with([a])
	_track_with([shared, blocker])
	_bind(menu, [a, shared])
	_press(menu.scale_double)
	_assert(a.duration_ticks == 3840, "free instance doubles fully, got %d" % a.duration_ticks)
	_assert(shared.duration_ticks == 2040, "other track's instance is clamped to its neighbour, got %d" % shared.duration_ticks)
	_recorded[0].undo()
	_assert(a.duration_ticks == 1920 and shared.duration_ticks == 1920, "undo restores both tracks")
	menu.free()


func _test_half_trims_note_overlaps() -> void:
	var menu := await _open_menu()
	var clip := _make_clip([[0, 1], [1, 4]], 960)
	_bind(menu, [_make_instance(clip, 960)])
	_press(menu.scale_half)
	var n: Array = _notes(clip)
	_assert(n[0][0] + n[0][1] <= n[1][0] or n[0][0] == n[1][0], "same-pitch notes do not overlap, got %s" % [n])
	menu.free()


## Scaling one selected instance also scales and clamps the clip's unselected instances on
## other tracks (the project-wide pass, fed with a track list as the menu feeds the project's).
func _test_project_wide_scales_unselected_instances() -> void:
	var menu := await _open_menu()
	var clip := _make_clip([[0, 480]], 1920)
	var other := _make_clip([[0, 480]], 1920)
	var selected := _make_instance(clip, 1920)
	var hidden_free := _make_instance(clip, 1920)
	var hidden_blocked := _make_instance(clip, 1920)
	hidden_blocked.start_ticks = 960
	var blocker := _make_instance(other, 960)
	blocker.start_ticks = 3000
	var t1 = _track_with([selected])
	var t2 = _track_with([hidden_free])
	var t3 = _track_with([hidden_blocked, blocker])
	_bind(menu, [selected])
	_recorded.clear()
	_history_util.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	menu.scale_selected(2.0, [t1, t2, t3])
	_history_util.test_recorder = Callable()
	_assert(selected.duration_ticks == 3840 and hidden_free.duration_ticks == 3840,
		"unselected instance on another track doubles")
	_assert(hidden_blocked.duration_ticks == 2040,
		"unselected instance is clamped at its neighbour, got %d" % hidden_blocked.duration_ticks)
	_assert(blocker.duration_ticks == 960, "the unrelated clip is untouched")
	_assert(_recorded.size() == 1, "one undo step")
	_recorded[0].undo()
	_assert(selected.duration_ticks == 1920 and hidden_free.duration_ticks == 1920
		and hidden_blocked.duration_ticks == 1920 and clip.content_length_ticks == 1920,
		"undo restores every instance")
	menu.free()
