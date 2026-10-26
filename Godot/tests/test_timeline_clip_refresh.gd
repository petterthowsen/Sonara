# test_timeline_clip_refresh.gd
# Headless tests that the arranger's note renderer follows clip actions: a merged clip draws its
# notes, and a clip an instance is retargeted to (Make Unique, undo) redraws when its notes change.
#
# Run: godot --headless --path Godot -s tests/test_timeline_clip_refresh.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
const EDITOR_SCRIPT := "res://editor/Editor.gd"


func suite_name() -> String:
	return "Timeline clip refresh"


func run_tests() -> void:
	get_root().size = Vector2i(1200, 600)
	var root := Control.new()
	root.size = Vector2(1200, 600)
	get_root().add_child(root)
	var arranger: Control = load(ARRANGER_SCENE).instantiate()
	var editor: Node = load(EDITOR_SCRIPT).new()
	editor.arranger = arranger
	get_root().get_node("Sonara").editor = editor
	root.add_child(arranger)
	arranger.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame

	var project: Object = load("res://data/Project.gd").new()
	var track: Object = project.create_instrument_track("T").track
	var a := _add_clip(project, track, 0)
	var b := _add_clip(project, track, 3840)
	editor.project = project
	editor.project_activated.emit(project)
	for i in 4:
		await process_frame

	var merged: Array = load("res://history/ClipMergeActions.gd").merge(project, [a, b])
	for i in 4:
		await process_frame
	var r := _renderer(arranger, merged[0])
	_assert(r != null, "merged instance has a view")
	if r != null:
		_assert(r.clip_instance == merged[0], "renderer shows the merged instance")
		_assert(r._window.y > r._window.x, "merged clip has a draw window (got %s)" % r._window)
		var draws := [0]
		r.draw.connect(func(): draws[0] += 1)
		merged[0].clip.add_midi_note(project.allocate_note_id(), 64, 0.8, 0, 100)
		await process_frame
		await process_frame
		_assert(draws[0] > 0, "editing the merged clip redraws it")

	var c := _add_clip(project, track, 8000)
	for i in 3:
		await process_frame
	var rc := _renderer(arranger, c)
	var fresh: Object = project.create_clip("Fresh")
	project.add_clip(fresh)
	c.set_clip(fresh)
	for i in 3:
		await process_frame
	var draws2 := [0]
	rc.draw.connect(func(): draws2[0] += 1)
	fresh.add_midi_note(project.allocate_note_id(), 64, 0.8, 0, 100)
	await process_frame
	await process_frame
	_assert(draws2[0] > 0, "a retargeted instance redraws when its new clip changes")

	root.free()
	editor.free()
	await process_frame


func _add_clip(project: Object, track: Object, start: int) -> Object:
	var clip: Object = project.create_clip("C")
	project.add_clip(clip)
	for i in 4:
		clip.add_midi_note(project.allocate_note_id(), 60 + i, 0.8, i * 960, 480)
	return track.create_clip_instance(clip, start, 3840)


func _renderer(arranger: Object, inst: Object) -> Control:
	for row in arranger.timeline.timeline_tracks:
		for clip_ui in row.clip_instances:
			if clip_ui.clip_instance == inst:
				return clip_ui.clip_renderer
	return null
