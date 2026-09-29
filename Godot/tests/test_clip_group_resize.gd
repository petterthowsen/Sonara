# test_clip_group_resize.gd
# Headless tests for resizing several arranger clips at once: grabbing an edge of a clip that is
# part of a multi-selection moves the same edge of every selected clip by the same snapped delta,
# each clamped to its own neighbours, and the whole gesture is one undo step.
#
# Run: godot --headless --path Godot -s tests/test_clip_group_resize.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"


func suite_name() -> String:
	return "Clip group resize"


func run_tests() -> void:
	await _test_right_edge_resizes_selection()
	await _test_left_edge_resizes_selection()
	await _test_unselected_clip_resizes_alone()


## Arranger with tracks A and B, a 960-tick clip on each at `starts`, plus a blocker on A.
func _make_fixture(starts: Array = [0, 1920]) -> Dictionary:
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
	var a: Object = project.create_instrument_track("A").track
	var b: Object = project.create_instrument_track("B").track
	editor.project = project
	editor.project_activated.emit(project)
	await process_frame
	var ca: Object = _clip_on(a, starts[0])
	var cb: Object = _clip_on(b, starts[1])
	# Blocks track A's clip from growing past tick 1440.
	var blocker: Object = _clip_on(a, 1440)
	await process_frame
	await process_frame
	return {"root": root, "arranger": arranger, "editor": editor, "a": ca, "b": cb, "blocker": blocker,
		"manager": arranger.timeline.clip_selection_manager}


func _clip_on(track: Object, start: int) -> Object:
	var inst: Object = load("res://data/ClipInstance.gd").new()
	inst.clip = load("res://data/Clip.gd").new()
	inst.start_ticks = start
	inst.duration_ticks = 960
	track.add_clip_instance(inst)
	return inst


func _free(f: Dictionary) -> void:
	f.root.free()
	f.editor.free()
	await process_frame


## Drive a resize gesture the way TimelineClip._gui_input does, moving the edge `delta` ticks.
func _resize(grabbed: Control, edge: String, delta: int) -> void:
	grabbed.is_resizing = true
	grabbed._resize_group = grabbed._find_resize_group()
	for clip_ui in grabbed._resize_group:
		clip_ui._begin_resize(edge)
	var snapped: int = grabbed._snapped_resize_delta(delta, true)
	for clip_ui in grabbed._resize_group:
		clip_ui._resize_by(snapped, 1)
	grabbed.is_resizing = false
	grabbed._finish_resize()


func _select(f: Dictionary, instances: Array) -> void:
	# A typed Array[ClipInstance] without naming the class here (it would compile before autoloads).
	var typed: Array = f.manager.get_selected_instances().duplicate()
	typed.assign(instances)
	f.manager.select_instances(typed)


func _test_right_edge_resizes_selection() -> void:
	var f := await _make_fixture()
	_select(f, [f.a, f.b])
	var ui_b: Control = f.manager.get_clip_ui(f.b)
	_assert(ui_b != null, "clip UI found for the selected instance")
	var undo_before: int = f.editor.history.undo_count()

	_resize(ui_b, "right", 960)
	_assert(f.b.duration_ticks == 1920, "grabbed clip grows (%d)" % f.b.duration_ticks)
	_assert(f.a.duration_ticks == 1440, "other clip grows until its neighbour (%d)" % f.a.duration_ticks)
	_assert(f.a.start_ticks == 0 and f.b.start_ticks == 1920, "right-edge resize keeps starts")
	_assert(f.editor.history.undo_count() == undo_before + 1, "one undo step for the group")

	f.editor.history.undo()
	_assert(f.a.duration_ticks == 960 and f.b.duration_ticks == 960, "undo restores both clips")
	await _free(f)


func _test_left_edge_resizes_selection() -> void:
	var f := await _make_fixture([480, 2400])
	_select(f, [f.a, f.b])
	_resize(f.manager.get_clip_ui(f.a), "left", -240)
	_assert(f.a.start_ticks == 240 and f.a.duration_ticks == 1200, "grabbed clip extends left (%d, %d)" % [f.a.start_ticks, f.a.duration_ticks])
	_assert(f.b.start_ticks == 2160 and f.b.duration_ticks == 1200, "other clip extends by the same delta (%d, %d)" % [f.b.start_ticks, f.b.duration_ticks])
	await _free(f)


func _test_unselected_clip_resizes_alone() -> void:
	var f := await _make_fixture()
	_select(f, [f.a, f.blocker])
	_resize(f.manager.get_clip_ui(f.b), "right", 480)
	_assert(f.b.duration_ticks == 1440, "grabbed clip outside the selection resizes (%d)" % f.b.duration_ticks)
	_assert(f.a.duration_ticks == 960, "selected clips stay put")
	await _free(f)
