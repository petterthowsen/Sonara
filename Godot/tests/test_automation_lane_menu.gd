# test_automation_lane_menu.gd
# Headless tests for the track-header automation dropdown (T-019, REQ-014): the "+ Add new"
# entry must emit add_lane_requested even when the track has no lanes yet (a negative
# PopupMenu item id gets auto-assigned by Godot, which used to swallow the click).
#
# Run: godot --headless --path Godot -s tests/test_automation_lane_menu.gd -- --test
extends TestBase

var _track_script: GDScript
var _lane_script: GDScript
var _menu_script: GDScript

var _requested: int = 0


func suite_name() -> String:
	return "Automation lane menu tests"


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_menu_script = load("res://arranger/tracklist/AutomationLaneMenu.gd")
	_test_add_new_with_no_lanes()
	_test_lane_toggle_and_add_new_together()


func _make_menu(track: Object) -> Object:
	var menu: Object = _menu_script.new()
	_requested = 0
	menu.add_lane_requested.connect(_on_add_lane_requested)
	menu.track = track
	menu._rebuild()
	return menu


func _on_add_lane_requested(_track) -> void:
	_requested += 1


func _test_add_new_with_no_lanes() -> void:
	var track := _make_menu_track()
	var menu := _make_menu(track)
	_assert(menu.get_item_count() == 1, "empty track shows only '+ Add new'")
	# The id Godot delivers for the item, looked up rather than assumed.
	var add_id: int = menu.get_item_id(menu.get_item_index(menu.ADD_NEW_ID))
	_assert(add_id == menu.ADD_NEW_ID, "'+ Add new' keeps its explicit id: %d" % add_id)
	menu._on_id_pressed(add_id)
	_assert(_requested == 1, "'+ Add new' emits add_lane_requested with no lanes: %d" % _requested)
	menu.free()


func _test_lane_toggle_and_add_new_together() -> void:
	var track := _make_menu_track()
	var lane: Object = _lane_script.new("lane0", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	var menu := _make_menu(track)
	_assert(menu.get_item_count() == 3, "lane checkbox + separator + '+ Add new'")
	menu._on_id_pressed(0)
	_assert(lane.visible == false, "lane id 0 toggles visibility")
	menu._on_id_pressed(menu.ADD_NEW_ID)
	_assert(_requested == 1, "'+ Add new' still emits alongside lane checkboxes: %d" % _requested)
	menu.free()


func _make_menu_track() -> Object:
	return _track_script.new(1)