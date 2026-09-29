# test_arranger_view_toggles.gd
# Headless tests for the arranger track list footer and header clicks:
# - the automation toggle hides every automation lane row (both columns) and the headers'
#   automation buttons; the routing toggle hides the headers' IO button; both persist.
# - a plain click on a header inside a multi-selection keeps the block on press (for dragging)
#   and selects only that track on release.
#
# Run: godot --headless --path Godot -s tests/test_arranger_view_toggles.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"
## Loaded lazily: Editor.gd references autoloads, which only resolve after the first frame.
const EDITOR_SCRIPT := "res://editor/Editor.gd"


func suite_name() -> String:
	return "Arranger view toggles and header selection"


func run_tests() -> void:
	await _test_automation_toggle()
	await _test_routing_toggle()
	_test_view_persists()
	await _test_click_in_multi_selection_selects_one_on_release()
	await _test_drag_keeps_multi_selection()


## Arranger with a project of two instrument tracks; track A has one automation lane.
func _make_fixture() -> Dictionary:
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
	var a: Object = project.create_instrument_track("A").track
	var b: Object = project.create_instrument_track("B").track
	var target: Object = load("res://data/AutomationTarget.gd").new()
	var lane: Object = load("res://data/AutomationLane.gd").new("lane0", target)
	a.add_automation_lane(lane)
	a.automation_expanded = true
	editor.project = project
	editor.project_activated.emit(project)
	await process_frame
	await process_frame
	return {"root": root, "arranger": arranger, "editor": editor, "project": project, "a": a, "b": b, "lane": lane}


func _free(f: Dictionary) -> void:
	f.root.free()
	f.editor.free()
	await process_frame


## Shown by its owner: visible, or only collapsed by the header's flow container for lack of room.
func _shown(button: Control) -> bool:
	var flow := button.get_parent() as CollapsingContainer
	return button.visible or (flow != null and flow.is_collapsed(button))


func _lane_rows(arranger: Control) -> int:
	var count := 0
	for rows in [arranger.track_list.get_children(), arranger.timeline.get_children()]:
		for child in rows:
			if child is Control and child.visible and child.get_script() and \
					child.get_script().resource_path.get_file() in ["AutomationLaneHeader.gd", "AutomationLaneRow.gd"]:
				count += 1
	return count


func _test_automation_toggle() -> void:
	var f := await _make_fixture()
	var arranger: Control = f.arranger
	var item: Control = arranger.track_list._find_track_item(f.a)
	_assert(_lane_rows(arranger) == 2, "lane shows a header and a timeline row (%d)" % _lane_rows(arranger))
	_assert(_shown(item.automation_menu_button), "automation menu button starts shown")

	arranger.automation_view_toggle.button_pressed = false
	await process_frame
	_assert(not f.project.get_arranger_view("automation"), "toggle writes the project view state")
	_assert(_lane_rows(arranger) == 0, "automation off hides lane rows in both columns (%d)" % _lane_rows(arranger))
	_assert(not _shown(item.automation_menu_button), "automation off hides the lane menu button")
	_assert(not _shown(item.automation_toggle), "automation off hides the disclosure button")
	_assert(f.a.automation_expanded, "per-track disclosure state is kept")

	arranger.automation_view_toggle.button_pressed = true
	await process_frame
	_assert(_lane_rows(arranger) == 2, "automation on brings the lane rows back (%d)" % _lane_rows(arranger))
	_assert(_shown(item.automation_menu_button), "automation on shows the lane menu button")
	await _free(f)


func _test_routing_toggle() -> void:
	var f := await _make_fixture()
	var arranger: Control = f.arranger
	var item: Control = arranger.track_list._find_track_item(f.b)
	_assert(_shown(item.io_button), "routing button starts shown")
	arranger.routing_view_toggle.button_pressed = false
	await process_frame
	_assert(not _shown(item.io_button), "routing off hides the IO button")
	arranger.routing_view_toggle.button_pressed = true
	await process_frame
	_assert(_shown(item.io_button), "routing on shows the IO button")
	await _free(f)


func _test_view_persists() -> void:
	var project_script: GDScript = load("res://data/Project.gd")
	var project: Object = project_script.new()
	_assert(project.arranger_view == {"automation": true, "routing": true}, "new project shows everything")
	project.set_arranger_view("automation", false)
	var loaded: Object = project_script.from_json(project.to_json())
	_assert(not loaded.get_arranger_view("automation"), "hidden automation survives reload")
	_assert(loaded.get_arranger_view("routing"), "shown routing survives reload")
	var data: Dictionary = project.to_json()
	data.erase("arranger_view")
	_assert(project_script.from_json(data).get_arranger_view("automation"), "old projects load with automation shown")


func _test_click_in_multi_selection_selects_one_on_release() -> void:
	var f := await _make_fixture()
	var list: Control = f.arranger.track_list
	var item_b: Control = list._find_track_item(f.b)
	list._select_track(f.a, false, false)
	list._select_track(f.b, true, false)
	_assert(list.selected_tracks.size() == 2, "two tracks selected")

	item_b.select_requested.emit(f.b, false, false)
	_assert(list.selected_tracks.size() == 2, "press keeps the block so it can be dragged")
	item_b.select_released.emit(f.b)
	_assert(list.selected_tracks == [f.b], "release selects only the clicked track")
	_assert(list.active_track == f.b, "clicked track is active")
	await _free(f)


func _test_drag_keeps_multi_selection() -> void:
	var f := await _make_fixture()
	var list: Control = f.arranger.track_list
	var item_b: Control = list._find_track_item(f.b)
	list._select_track(f.a, false, false)
	list._select_track(f.b, true, false)
	item_b.select_requested.emit(f.b, false, false)
	var drag: Object = load("res://arranger/tracklist/TrackDrag.gd").new(item_b, f.b, Control.new(), list.get_tracks_for_drag(f.b))
	list.begin_track_drag(drag)
	item_b.select_released.emit(f.b)
	_assert(list.selected_tracks.size() == 2, "a drag keeps the multi-selection")
	drag.preview.free()
	await _free(f)
