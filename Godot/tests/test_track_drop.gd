# test_track_drop.gd
# Headless tests for arranger track drag targets (TrackDropTarget): the middle of a folder header
# nests at the end, the gap above a child inserts into the folder with an indented line, the left
# gutter un-nests, dropping in place is a no-op, and nothing moves until commit.
# Run: godot --headless --path Godot -s tests/test_track_drop.gd -- --test
#
# TrackList and the project reference autoloads, so they are loaded with load() instead of named.
extends TestBase

var _project_script: GDScript
var _drop_target: GDScript
var _track_drag: GDScript
var _list: Control
var _project: Object


func suite_name() -> String:
	return "Track drop tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_drop_target = load("res://arranger/tracklist/TrackDropTarget.gd")
	_track_drag = load("res://arranger/tracklist/TrackDrag.gd")
	await _test_folder_header_nests()
	await _test_insert_into_folder_with_indented_line()
	await _test_left_gutter_unnests()
	await _test_drop_in_place_is_noop()


## Fresh project + TrackList: Folder holding A and B, then a root track C.
func _setup() -> Dictionary:
	if _list:
		_list.free()
	_project = _project_script.new()
	var folder: Object = _project.create_folder_track("Folder").track
	var a: Object = _project.create_instrument_track("A").track
	var b: Object = _project.create_instrument_track("B").track
	var c: Object = _project.create_instrument_track("C").track
	_project.place_track(a, folder.id, null)
	_project.place_track(b, folder.id, a)
	_project.place_track(c, -1, folder)
	for t in [folder, a, b, c]:
		t.height = 60
	_list = (load("res://arranger/tracklist/TrackList.tscn") as PackedScene).instantiate()
	_list.size = Vector2(320, 800)
	root.add_child(_list)
	_list._on_project_activated(_project)
	await process_frame
	await process_frame
	return {"folder": folder, "a": a, "b": b, "c": c}


func _item(track: Object) -> Control:
	return _list._find_track_item(track)


func _drag(track: Object) -> Object:
	return _track_drag.new(_item(track), track, null)


func _child_names(folder: Object) -> Array:
	var names: Array = []
	for t in _project.get_track_children(folder):
		names.append(t.name)
	return names


func _test_folder_header_nests() -> void:
	var t := await _setup()
	var rect: Rect2 = _item(t.folder).get_global_rect()
	_assert(rect.size.y > 0, "folder header laid out")
	var target: Object = _drop_target.resolve(_list, _drag(t.c), rect.get_center())
	_assert(target.kind == _drop_target.Kind.NEST, "middle of folder header nests: %d" % target.kind)
	_assert(target.parent_id == t.folder.id and target.after_sibling == t.b, "nest appends after B")
	_assert(target.indicator_rect == rect, "glow outlines the folder header")
	_assert(t.c.parent_track_id == -1, "resolving moves nothing")
	_assert(target.commit(), "commit nests")
	_assert(_child_names(t.folder) == ["A", "B", "C"], "C appended: %s" % str(_child_names(t.folder)))

	# The top edge of the folder header inserts before it instead.
	var top: Object = _drop_target.resolve(_list, _drag(t.a), Vector2(rect.get_center().x, rect.position.y + 2))
	_assert(top.kind == _drop_target.Kind.INSERT and top.parent_id == -1, "folder header top edge inserts at root")


func _test_insert_into_folder_with_indented_line() -> void:
	var t := await _setup()
	var a_rect: Rect2 = _item(t.a).get_global_rect()
	var point := Vector2(a_rect.position.x + 200, a_rect.position.y + 4)
	var target: Object = _drop_target.resolve(_list, _drag(t.c), point)
	_assert(target.kind == _drop_target.Kind.INSERT, "upper half of A inserts: %d" % target.kind)
	_assert(target.parent_id == t.folder.id and target.after_sibling == null, "first child of the folder")
	var line: Rect2 = target.indicator_rect
	_assert(absf(line.get_center().y - a_rect.position.y) <= 2.0, "line at A's top edge: %f vs %f" % [line.get_center().y, a_rect.position.y])
	var indent: float = _list.get_global_rect().position.x + _list.folder_indent_pixels
	_assert(absf(line.position.x - indent) <= 0.5, "line indented one level")
	_assert(_child_names(t.folder) == ["A", "B"], "resolving moves nothing")
	_assert(target.commit(), "commit inserts")
	_assert(_child_names(t.folder) == ["C", "A", "B"], "C first in folder: %s" % str(_child_names(t.folder)))


func _test_left_gutter_unnests() -> void:
	var t := await _setup()
	var b_rect: Rect2 = _item(t.b).get_global_rect()
	# Lower half of B (last child), pointer in the left gutter: after the folder at root.
	var point := Vector2(_list.get_global_rect().position.x + 2, b_rect.end.y - 4)
	var target: Object = _drop_target.resolve(_list, _drag(t.a), point)
	_assert(target.kind == _drop_target.Kind.INSERT and target.parent_id == -1, "gutter un-nests to root")
	_assert(target.after_sibling == t.folder, "lands after the folder")
	_assert(absf(target.indicator_rect.get_center().y - b_rect.end.y) <= 2.0, "line under the folder's last row")
	_assert(absf(target.indicator_rect.position.x - _list.get_global_rect().position.x) <= 0.5, "root line not indented")
	_assert(target.commit(), "commit un-nests")
	_assert(t.a.parent_track_id == -1 and _child_names(t.folder) == ["B"], "A left the folder")


func _test_drop_in_place_is_noop() -> void:
	var t := await _setup()
	var b_rect: Rect2 = _item(t.b).get_global_rect()
	# Upper half of B, indented: after A inside the folder, where A already is.
	var target: Object = _drop_target.resolve(_list, _drag(t.a), Vector2(b_rect.position.x + 200, b_rect.position.y + 4))
	_assert(target.is_valid() and target.parent_id == t.folder.id, "A's own slot resolves")
	_assert(not target.commit(), "dropping in place changes nothing")
	var outside := _list.get_global_rect().end + Vector2(10, 10)
	_assert(not _drop_target.resolve(_list, _drag(t.a), outside).is_valid(), "outside the list resolves to nothing")
