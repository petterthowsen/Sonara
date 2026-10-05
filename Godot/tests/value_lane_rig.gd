# Shared setup for the value lane tests: the real ClipEditor scene bound to one clip.
# Not a test itself (run_all.sh only picks up test_*.gd). Everything is untyped on purpose:
# naming the editor classes here would compile them before the autoloads exist.
extends RefCounted

var tree: SceneTree
var editor: Control
var midi_editor
var clip
var instance
var project
var track
var history: Array = []


func _init(p_tree: SceneTree) -> void:
	tree = p_tree


## Build the editor with notes at `ticks` (one 240-tick note each, pitch 60 + index unless
## `pitches` is given) and the given velocities / releases.
func build(ticks: Array, velocities: Array, releases: Array = [], pitches: Array = []) -> void:
	var project_script: GDScript = load("res://data/Project.gd")
	project = project_script.new()
	var pair: Dictionary = project.create_instrument_track("Synth")
	track = pair.track
	clip = project.create_clip("Riff")
	project.add_clip(clip)
	instance = track.create_clip_instance(clip, 0, 7680)
	clip.mark_synced_to_engine()
	for i in ticks.size():
		var pitch: int = pitches[i] if i < pitches.size() else 60 + i
		var n = clip.add_midi_note(clip.allocate_note_id(), pitch, velocities[i], ticks[i], 240)
		if i < releases.size():
			n.release = releases[i]

	var scene: PackedScene = load("res://clip_editor/ClipEditor.tscn")
	editor = scene.instantiate()
	editor.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(editor)
	editor.size = Vector2(1100, 600)
	await tree.process_frame
	editor.bound_clip_instance = instance
	midi_editor = editor.midi_editor
	midi_editor.bind_to_clip_instance(instance)
	editor.value_pane.visible = true
	for _i in 3:
		await tree.process_frame
	var history_sink := history
	load("res://history/HistoryUtil.gd").test_recorder = func(cmd): history_sink.append(cmd)


func lane(index := 0):
	return editor.value_pane.lanes[index]


func area(index := 0):
	return lane(index).stem_area


func note(i: int):
	return clip.midi_notes[i]


## Stem x (in the stem area's coordinates) of note `i`.
func stem_x_of(i: int, index := 0) -> float:
	var a = area(index)
	for stem in midi_editor.value_stems():
		if stem["note_data"] == note(i):
			return a.stem_x(stem)
	return NAN


func mouse(pos: Vector2, pressed: bool, mods := {}, double := false) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	e.double_click = double
	e.ctrl_pressed = mods.get("ctrl", false)
	e.alt_pressed = mods.get("alt", false)
	e.shift_pressed = mods.get("shift", false)
	return e


func motion(pos: Vector2, mods := {}) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.ctrl_pressed = mods.get("ctrl", false)
	e.alt_pressed = mods.get("alt", false)
	e.shift_pressed = mods.get("shift", false)
	return e


## Press, drag through `points`, release at the last one. Returns nothing; read the notes.
func drag(a, start: Vector2, points: Array, mods := {}) -> void:
	a._gui_input(mouse(start, true, mods))
	for p in points:
		a._gui_input(motion(p, mods))
	var end: Vector2 = points[points.size() - 1] if not points.is_empty() else start
	a._gui_input(mouse(end, false, mods))


func osc_updates() -> int:
	var osc: Node = tree.root.get_node("AudioEngineOSC")
	return osc._pending_sends.filter(func(s): return str(s).contains("update_note")).size()


func clear_osc() -> void:
	tree.root.get_node("AudioEngineOSC")._pending_sends.clear()


func select(indices: Array) -> void:
	var visuals: Array[VisualNote] = []
	for vn in midi_editor.note_editor.get_all_visual_notes():
		for i in indices:
			if vn.midi_note_data == note(i):
				visuals.append(vn)
	midi_editor.note_editor.selection_manager.select_all(visuals)


func cleanup() -> void:
	load("res://history/HistoryUtil.gd").test_recorder = Callable()
	editor.queue_free()
	await tree.process_frame
