# test_clip_insert_length.gd
# Headless test for the timeline double-click insert: a new MIDI clip is one bar long at the
# current time signature, shortened only when a following clip leaves less room.
#
# Run: godot --headless --path Godot -s tests/test_clip_insert_length.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"


func suite_name() -> String:
	return "Clip insert length"


func run_tests() -> void:
	await _test_insert_is_one_bar()
	await _test_insert_shortens_before_following_clip()
	await _test_insert_follows_time_signature()


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
	var track: Object = project.create_instrument_track("A").track
	editor.project = project
	editor.project_activated.emit(project)
	await process_frame
	await process_frame
	var timeline: Control = arranger.timeline
	return {"root": root, "arranger": arranger, "editor": editor, "project": project,
		"track": track, "timeline": timeline, "grid": timeline.grid_helper,
		"row": timeline.timeline_tracks[0]}


func _insert(ctx: Dictionary, ticks: int) -> Object:
	var gh: Object = ctx.grid
	var row: Object = ctx.row
	row._on_double_click(Vector2(gh.ticks_to_pixels(ticks), 10.0))
	var created: Array = []
	for inst in ctx.track.clip_instances:
		if inst != null and inst.start_ticks == ctx.grid.snap_ticks(ticks):
			created.append(inst)
	return null if created.is_empty() else created[-1]


func _test_insert_is_one_bar() -> void:
	var ctx := await _rig()
	var tpb: int = ctx.grid.get_ticks_per_bar()
	_assert(tpb == 3840, "4/4 bar is 3840 ticks (got %d)" % tpb)
	var inst := _insert(ctx, tpb)  # second bar
	_assert(inst != null, "double-click on an empty track creates a clip")
	_assert(inst.start_ticks == tpb, "clip starts at the snapped position (%d)" % inst.start_ticks)
	_assert(inst.duration_ticks == tpb, "new clip is one bar (%d, got %d)" % [tpb, inst.duration_ticks])
	_cleanup(ctx)


func _test_insert_shortens_before_following_clip() -> void:
	var ctx := await _rig()
	var tpb: int = ctx.grid.get_ticks_per_bar()
	# A following clip starts 1.5 bars after the insertion point.
	var block: Object = load("res://history/ClipActions.gd").create_clip(
		ctx.project, ctx.track, tpb + 1920, tpb, "Blocker")
	_assert(block != null, "blocker placed")
	var inst := _insert(ctx, tpb)
	_assert(inst != null, "insert between clips works")
	_assert(inst.duration_ticks == 1920, "clip shortened to the room before the next clip (got %d)" % inst.duration_ticks)
	_assert(inst.start_ticks + inst.duration_ticks == tpb + 1920, "clip ends where the following clip starts")
	_cleanup(ctx)


func _test_insert_follows_time_signature() -> void:
	var ctx := await _rig()
	ctx.project.time_signature_map.add_change(2, 7, 8)
	await process_frame
	var tpb: int = ctx.grid.get_ticks_per_bar()
	_assert(tpb == 3840, "4/4 bar is 3840 ticks (got %d)" % tpb)
	var inst := _insert(ctx, 3840)
	_assert(inst != null, "insert with a signature change works")
	_assert(inst.duration_ticks == 3360, "new clip is one 7/8 bar (got %d)" % inst.duration_ticks)
	_cleanup(ctx)


func _cleanup(ctx: Dictionary) -> void:
	ctx.root.free()
	ctx.editor.free()
	await process_frame
