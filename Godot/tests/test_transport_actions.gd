# test_transport_actions.gd
# Headless tests for the transport stop cycle, the loop region on Project (create, toggle, drag
# clamp, save/load) and the Space action pair in the hotkey registry.
#
# Project references autoloads by bare name, so it is loaded with load() in run_tests().
# Run: godot --headless --path Godot -s tests/test_transport_actions.gd -- --test
extends TestBase

const BEAT := 960

var Hotkeys


func suite_name() -> String:
	return "Transport actions tests"


func run_tests() -> void:
	Hotkeys = root.get_node("Hotkeys")
	_test_stop_cycle_with_markers()
	_test_stop_cycle_without_markers()
	_test_nearest_marker_tie()
	_test_loop_region()
	_test_loop_edge_clamp()
	_test_loop_round_trip()
	_test_loop_selected_region_and_toggle()
	_test_loop_follows_selection()
	_test_follow_flag_round_trip()
	_test_space_pair_is_not_a_conflict()


func _test_stop_cycle_with_markers() -> void:
	var markers := [1920, 7680]
	var step := TransportCycle.next_step(9000, 5000, markers)
	_assert(step == {"start": 5000, "playhead": 5000}, "press 1: playhead goes to the start position")
	step = TransportCycle.next_step(5000, 5000, markers)
	_assert(step == {"start": 7680, "playhead": 7680}, "press 2: start goes to the nearest Marker start")
	step = TransportCycle.next_step(7680, 7680, markers)
	_assert(step == {"start": 0, "playhead": 0}, "press 3: start goes to bar 0")
	step = TransportCycle.next_step(0, 0, markers)
	_assert(step == {"start": 1920, "playhead": 1920}, "press 4: the cycle wraps to the nearest Marker again")
	step = TransportCycle.next_step(0, 0, [0, 1920])
	_assert(step == {"start": 0, "playhead": 0}, "a Marker at bar 0 ends the cycle there")
	step = TransportCycle.next_step(0, 0, [])
	_assert(step == {"start": 0, "playhead": 0}, "no Markers and already at the origin: nothing changes")
	step = TransportCycle.next_step(0, 1920, markers)
	_assert(step == {"start": 1920, "playhead": 1920}, "playhead away from start returns first even at a Marker start")


func _test_stop_cycle_without_markers() -> void:
	var step := TransportCycle.next_step(5000, 5000, [])
	_assert(step == {"start": 0, "playhead": 0}, "no Markers: straight to bar 0")


func _test_nearest_marker_tie() -> void:
	_assert(TransportCycle.nearest_marker_start(1000, [1500, 500]) == 500, "an equal distance picks the earlier Marker")


func _project() -> Object:
	var project: Object = (load("res://data/Project.gd") as GDScript).new()
	project.ppq = BEAT
	return project


func _test_loop_region() -> void:
	var project := _project()
	var events: Array = []
	project.loop_changed.connect(func(on, s, e): events.append([on, s, e]))
	_assert(not project.has_loop_region(), "a new project has no loop region")
	_assert(not project.set_loop_enabled(true), "loop can't turn on without a region")
	project.set_loop_region(1920, 7680)
	_assert(project.loop_start_ticks == 1920 and project.loop_end_ticks == 7680, "region is stored")
	_assert(not project.loop_enabled, "setting a region leaves loop off")
	_assert(project.set_loop_enabled(true), "loop turns on with a region")
	project.set_loop_region(0, 960)
	_assert(project.loop_enabled and project.loop_end_ticks == 960, "changing the region keeps the on state")
	_assert(not project.set_loop_enabled(false), "loop turns off and keeps the region")
	_assert(project.has_loop_region(), "the region survives turning loop off")
	_assert(events.size() == 4, "each change emits loop_changed once: %d" % events.size())
	project.set_loop_region(960, 960)
	_assert(project.loop_end_ticks == 960 + BEAT, "a region is at least one beat long")


func _test_loop_edge_clamp() -> void:
	var project := _project()
	project.set_loop_region(1920, 7680)
	project.move_loop_edge(true, 100)
	_assert(project.loop_end_ticks == 1920 + BEAT, "end clamps to start + 1 beat")
	project.move_loop_edge(false, 99999)
	_assert(project.loop_start_ticks == project.loop_end_ticks - BEAT, "start clamps to end - 1 beat")
	project.move_loop_edge(false, -50)
	_assert(project.loop_start_ticks == 0, "start never goes below bar 0")


func _test_loop_round_trip() -> void:
	var project := _project()
	project.set_loop_region(1920, 7680)
	project.set_loop_enabled(true)
	var loaded: Object = (load("res://data/Project.gd") as GDScript).from_json(project.to_json())
	_assert(loaded.loop_enabled and loaded.loop_start_ticks == 1920 and loaded.loop_end_ticks == 7680,
			"loop region and state survive save and load")
	var data: Dictionary = project.to_json()
	data.erase("loop")
	loaded = (load("res://data/Project.gd") as GDScript).from_json(data)
	_assert(not loaded.loop_enabled and not loaded.has_loop_region(), "an older project loads with no loop")


func _test_space_pair_is_not_a_conflict() -> void:
	_assert("transport_pause" not in Hotkeys.find_conflicts("transport_play", "Space"), "Play and Pause share Space")
	_assert("transport_play" not in Hotkeys.find_conflicts("transport_pause", "Space"), "...in both directions")
	_assert("transport_play" in Hotkeys.find_conflicts("transport_loop_toggle", "Space"), "any other action on Space still conflicts")


func _editor(project: Object) -> Object:
	var editor: Object = (load("res://editor/Editor.gd") as GDScript).new()
	editor.project = project
	return editor


func _select(editor: Object, start: int, end: int, has_end := true) -> void:
	editor.test_time_range_override = {"has": true, "start": start, "end": end, "has_end": has_end}


func _test_loop_selected_region_and_toggle() -> void:
	var project := _project()
	var editor := _editor(project)
	editor.loop_selected_region()
	_assert(not project.has_loop_region() and not project.loop_enabled, "Loop Selected Region without a selection does nothing")
	_select(editor, 1920, 7680, false)
	editor.loop_selected_region()
	_assert(not project.has_loop_region(), "a range without an end is not a region")
	_select(editor, 1920, 7680)
	editor.loop_selected_region()
	_assert(project.loop_start_ticks == 1920 and project.loop_end_ticks == 7680 and project.loop_enabled,
			"Loop Selected Region sets the region and turns loop on")
	_select(editor, 0, 960)
	editor.loop_selected_region()
	_assert(project.loop_end_ticks == 960, "Loop Selected Region replaces an existing region")
	# The toggle keeps an existing region and only creates one when there is none.
	project.set_loop_enabled(false)
	_select(editor, 5000, 6000)
	editor.toggle_loop()
	_assert(project.loop_enabled and project.loop_start_ticks == 0 and project.loop_end_ticks == 960,
			"toggling on keeps the existing region")
	var fresh := _project()
	var fresh_editor := _editor(fresh)
	fresh_editor.toggle_loop()
	_assert(not fresh.loop_enabled, "toggle without region or selection stays off")
	_select(fresh_editor, 1920, 7680)
	fresh_editor.toggle_loop()
	_assert(fresh.loop_enabled and fresh.loop_end_ticks == 7680, "toggle creates the region from the selection")
	editor.free()
	fresh_editor.free()


func _test_loop_follows_selection() -> void:
	var project := _project()
	var editor := _editor(project)
	_select(editor, 1920, 7680)
	editor.sync_loop_to_selection()
	_assert(not project.has_loop_region(), "without the follow toggle the selection is ignored")
	project.set_loop_follows_selection(true)
	editor.sync_loop_to_selection()
	_assert(project.loop_start_ticks == 1920 and project.loop_end_ticks == 7680, "following copies the selection")
	_assert(not project.loop_enabled, "following never turns loop on")
	project.set_loop_enabled(true)
	_select(editor, 960, 1920)
	editor.sync_loop_to_selection()
	_assert(project.loop_end_ticks == 1920 and project.loop_enabled, "following keeps loop on while the region moves")
	project.set_loop_enabled(false)
	_select(editor, 0, 960)
	editor.sync_loop_to_selection()
	_assert(project.loop_end_ticks == 960 and not project.loop_enabled, "following keeps loop off")
	editor.test_time_range_override = {"has": false, "start": 0, "end": 0, "has_end": false}
	editor.sync_loop_to_selection()
	_assert(project.loop_end_ticks == 960, "clearing the selection keeps the last region")
	editor.free()


func _test_follow_flag_round_trip() -> void:
	var project := _project()
	project.set_loop_region(0, 960)
	project.set_loop_follows_selection(true)
	var loaded: Object = (load("res://data/Project.gd") as GDScript).from_json(project.to_json())
	_assert(loaded.loop_follows_selection, "the follow toggle survives save and load")
	var data: Dictionary = project.to_json()
	data["loop"].erase("follows_selection")
	loaded = (load("res://data/Project.gd") as GDScript).from_json(data)
	_assert(not loaded.loop_follows_selection, "older files load with follow off")
