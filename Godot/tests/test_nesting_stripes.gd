# test_nesting_stripes.gd
# Headless tests for the tracklist folder insets (NestingStripes): a nested TrackItem and its
# automation lane headers carry one stripe per enclosing folder, outermost first, and follow an
# enclosing folder being moved.
# Run: godot --headless --path Godot -s tests/test_nesting_stripes.gd -- --test
#
# TrackList and the project reference autoloads, so they are loaded with load() instead of named.
extends TestBase

## Mirrors NestingStripes.WIDTH (the class cannot be named here; see above).
const WIDTH := 12

var _list: Control
var _project: Object


func suite_name() -> String:
	return "Nesting stripes tests"


func run_tests() -> void:
	await _test_nested_rows_stripe_every_ancestor()
	await _test_moving_enclosing_folder_updates_descendants()


## Outer folder > Inner folder > A, with one automation lane on A.
func _setup() -> Dictionary:
	if _list:
		_list.free()
	_project = load("res://data/Project.gd").new()
	var outer: Object = _project.create_folder_track("Outer").track
	var inner: Object = _project.create_folder_track("Inner").track
	var a: Object = _project.create_instrument_track("A").track
	_project.place_track(inner, outer.id, null)
	_project.place_track(a, inner.id, null)
	var lane: Object = load("res://data/AutomationLane.gd").new("lane_1")
	a.add_automation_lane(lane)
	_list = (load("res://arranger/tracklist/TrackList.tscn") as PackedScene).instantiate()
	_list.size = Vector2(320, 800)
	root.add_child(_list)
	_list._on_project_activated(_project)
	await process_frame
	return {"outer": outer, "inner": inner, "a": a, "lane": lane}


func _item_inset(track: Object) -> int:
	return (_list._find_track_item(track).get_theme_stylebox("panel") as StyleBoxFlat).border_width_left


## Meter's left edge relative to its TrackItem.
func _meter_x(track: Object) -> float:
	var item: Control = _list._find_track_item(track)
	return item.volumeter.global_position.x - item.global_position.x


func _test_nested_rows_stripe_every_ancestor() -> void:
	var t := await _setup()
	var item: Control = _list._find_track_item(t.a)
	var header: Control = _list._lane_headers.get(t.lane)
	_assert(header != null, "lane header exists for A's lane")
	if header == null:
		return

	_assert(item._ancestors == [t.outer, t.inner], "track item stripes: outer then inner")
	_assert(_item_inset(t.a) == 2 * WIDTH, "track item reserves two stripes")
	_assert(header._ancestors == [t.outer, t.inner], "lane header stripes: outer then inner")
	var style := header.get_theme_stylebox("panel") as StyleBoxFlat
	_assert(style.border_width_left == 2 * WIDTH + 10,
		"lane header reserves two stripes plus its own band")
	_assert(_item_inset(t.outer) == 0, "top-level folder has no inset")

	# A folder's meter starts one stripe past its inset, so its own background fills the column
	# its children's stripe continues; a plain track's meter sits right after the stripes.
	_assert(_meter_x(t.outer) == WIDTH, "top-level folder meter sits after its own column")
	_assert(_meter_x(t.inner) == 2 * WIDTH, "nested folder meter sits after inset + own column")
	_assert(_meter_x(t.a) == 2 * WIDTH, "plain track meter sits right after its stripes")


func _test_moving_enclosing_folder_updates_descendants() -> void:
	var t := await _setup()
	var header: Control = _list._lane_headers.get(t.lane)
	# Only Inner's parent changes; A and its lane must still notice.
	_project.place_track(t.inner, -1, t.outer)
	await process_frame

	_assert(_list._find_track_item(t.a)._ancestors == [t.inner], "track item follows moved folder")
	_assert(_item_inset(t.a) == WIDTH, "track item inset shrinks to one stripe")
	_assert(header._ancestors == [t.inner], "lane header follows moved folder")
	var style := header.get_theme_stylebox("panel") as StyleBoxFlat
	_assert(style.border_width_left == WIDTH + 10, "lane header inset shrinks")
