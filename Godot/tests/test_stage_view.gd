# Stage view (spec 051 T-022, T-023; REQ-021, REQ-023, REQ-024): shallow checks that the view
# lists the stage sources, follows pan mode changes, edits the room and the selected sources
# through the models with undo, shows automated positions, and syncs its selection. Dragging
# itself is a live check; the edit maths is covered by test_stage_edit.gd.
extends TestBase

var _project_script: GDScript
var _scene: PackedScene
var _recorded: Array = []
## Channels hold their project weakly: keep every project alive for the whole run.
var _keep: Array = []


func suite_name() -> String:
	return "Stage view"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_scene = load("res://stage/StageView.tscn")
	_assert(_scene != null, "setup: StageView.tscn loads")
	if _scene == null:
		return
	var history: GDScript = load("res://history/HistoryUtil.gd")
	history.set("test_recorder", func(cmd: Object) -> void: _recorded.append(cmd))
	await _test_items()
	await _test_selection()
	await _test_source_panel()
	await _test_room_edit()
	_test_automated_state()
	await _test_hosted_in_frame()
	history.set("test_recorder", Callable())


## A view on a fresh project with `names.size()` stage sources.
func _view_with(names: Array) -> Dictionary:
	var project: Object = _project_script.new()
	_keep.append(project)
	var view: Control = _scene.instantiate()
	root.add_child(view)
	var channels: Array = []
	for n in names:
		var track: Dictionary = project.create_instrument_track(n)
		track.channel.set_pan_mode(track.channel.PanMode.STAGE)
		channels.append(track.channel)
	view.set_project(project)
	return {"view": view, "project": project, "channels": channels}


## An Array[Channel] without naming the class (the test script compiles before the autoloads).
func _typed(channels: Array) -> Array:
	var out := Array([], TYPE_OBJECT, &"RefCounted", load("res://data/Channel.gd"))
	out.assign(channels)
	return out


func _test_items() -> void:
	var s := _view_with(["Violins", "Violas", "Cellos"])
	await process_frame
	var view: Control = s.view
	var names: Array = view.get_items().map(func(c: Object) -> String: return c.name)
	_assert(names == ["Violins", "Violas", "Cellos"], "three stage sources give three items with their names")
	var plain: Dictionary = s.project.create_instrument_track("Drums")
	await process_frame
	_assert(view.get_items().size() == 3, "a channel in another pan mode is no item")
	s.channels[1].set_pan_mode(s.channels[1].PanMode.STEREO_BALANCE)
	_assert(view.get_items().size() == 2 and not view.get_items().has(s.channels[1]), "a source leaving Stage loses its item")
	plain.channel.set_pan_mode(plain.channel.PanMode.STAGE)
	_assert(view.get_items().size() == 3, "a channel entering Stage gains one")
	view.queue_free()


func _test_selection() -> void:
	var s := _view_with(["A", "B"])
	await process_frame
	var view: Control = s.view
	var plain: Dictionary = s.project.create_instrument_track("Plain")
	var emitted: Array = []
	view.selection_changed.connect(func(c: Array) -> void: emitted.append(c.size()))
	view.select_from_user(_typed([s.channels[1]]))
	_assert(view.get_selection() == [s.channels[1]] and emitted == [1], "selecting in the view reports the channel")
	var mapped: Dictionary = load("res://editor/SelectionSync.gd").channels_for_stage_selection(s.project, _typed(s.channels))
	_assert(mapped.channels == s.channels and mapped.focused == s.channels[1], "stage selection maps to channels, focus on the last")
	view.set_selection_silent(_typed([s.channels[0], plain.channel]))
	_assert(view.get_selection() == [s.channels[0]], "an incoming selection keeps only stage sources")
	_assert(emitted == [1], "an incoming selection is not reported back")
	view.set_selection_silent(_typed([]))
	_assert(view.get_selection().is_empty(), "an empty incoming selection clears it")
	view.queue_free()


func _test_source_panel() -> void:
	var s := _view_with(["A", "B"])
	await process_frame
	var view: Control = s.view
	var a: Object = s.channels[0]
	var b: Object = s.channels[1]
	view.select_from_user(_typed([a, b]))
	_recorded.clear()
	view.get_node("%HasRoom").button_pressed = true
	_assert(a.stage_has_room and b.stage_has_room, "Has room applies to every selected source")
	_assert(_recorded.size() == 1, "and is one undo step")
	_recorded.clear()
	view.get_node("%SumOption").select(1)
	view.get_node("%SumOption").item_selected.emit(1)
	_assert(a.stage_sum_mode == a.StageSumMode.MID, "the sum mode follows the dropdown")
	_recorded.clear()
	view.get_node("%SourceHeight").value = 4.0
	_assert(is_equal_approx(a.stage_z, 4.0) and is_equal_approx(b.stage_z, 4.0), "height applies to the selection")
	_recorded[0].undo()
	_assert(is_equal_approx(a.stage_z, a.stage_z) and not is_equal_approx(a.stage_z, 4.0), "height undoes")
	view.queue_free()


func _test_room_edit() -> void:
	var s := _view_with(["A"])
	await process_frame
	var view: Control = s.view
	var room: Object = s.project.stage
	var a: Object = s.channels[0]
	var width_before: float = room.width
	_recorded.clear()
	view.get_node("%Width").value = 12.0
	_assert(is_equal_approx(room.width, 12.0), "the width field edits the room")
	_assert(not _recorded.is_empty(), "a room edit is recorded")
	for cmd in _recorded:
		cmd.undo()
	_assert(is_equal_approx(room.width, width_before), "undo restores the room")
	_assert(is_equal_approx(view.get_node("%Width").value, width_before), "and the field")
	_recorded.clear()
	var preset_option: OptionButton = view.get_node("%PresetOption")
	var church := -1
	for i in preset_option.item_count:
		if preset_option.get_item_metadata(i) == "church":
			church = i
	preset_option.select(church)
	preset_option.item_selected.emit(church)
	_assert(room.preset == "church", "the preset dropdown applies a preset")
	room.set_decay_s(2.0)
	_assert(preset_option.get_item_text(church).contains("modified"), "an edit shows the preset as modified")
	# Shrinking the room pulls a source back inside; undo returns both.
	a.set_stage_position(Vector3(15.0, 30.0, 1.0))
	_recorded.clear()
	view.get_node("%Width").value = 6.0
	_assert(a.stage_x <= 6.0, "setup: the source was pulled into the smaller room")
	for cmd in _recorded:
		cmd.undo()
	_assert(is_equal_approx(a.stage_x, 15.0), "undo of a room edit returns the pulled-in source too")
	view.queue_free()


func _test_automated_state() -> void:
	var canvas: GDScript = load("res://stage/StageCanvas.gd")
	var lane_script: GDScript = load("res://data/AutomationLane.gd")
	var target_script: GDScript = load("res://data/AutomationTarget.gd")
	var project: Object = _project_script.new()
	_keep.append(project)
	project.stage.set_room_size(20.0, 30.0, 10.0)
	var track: Dictionary = project.create_instrument_track("Solo")
	track.channel.set_pan_mode(track.channel.PanMode.STAGE)
	track.channel.set_stage_position(Vector3(2.0, 10.0, 1.0))
	var lane: Object = lane_script.new("lane_x", target_script.stage("x"))
	lane.add_point(0, 0.0)
	lane.add_point(960, 1.0)
	track.track.add_automation_lane(lane)
	var half: Dictionary = canvas.automated_state(project, track.channel, 480)
	_assert(absf(half.x - 10.0) < 0.01 and half.y == 10.0, "x automation at the midpoint is half the room width (got %s)" % half.x)
	_assert(canvas.automated_state(project, track.channel, -1).x == 2.0, "stopped: the channel's own position")
	lane.set_bypassed(true)
	_assert(canvas.automated_state(project, track.channel, 480).x == 2.0, "a bypassed lane is ignored")


## View > Stage opens the view in a page frame, which calls show_view() / hide_view() on it.
func _test_hosted_in_frame() -> void:
	var manager: Node = root.get_node("DeviceWindowManager")
	var frame: Object = manager.open_stage()
	await process_frame
	_assert(frame != null and manager.is_stage_open(), "open_stage opens a frame")
	var page: Object = frame.get_custom_page() if frame else null
	_assert(page != null and page.get_script() == load("res://stage/StageView.gd"), "the frame hosts the Stage view")
	manager.toggle_stage()
	await process_frame
	_assert(not manager.is_stage_open(), "toggle_stage closes it again")
