# test_mixer_channel_drop.gd
# Headless tests for mixer strip drag targets (MixerChannelDropTarget): dropping onto a Group header
# nests, dropping elsewhere on a group strip inserts beside it, dropping in a fold-out inserts at the
# hovered index, dropping on the root pane un-nests or reorders, and buses reorder in the right pane. Also checks that nested strip headers
# end on the same row as their parent's header.
# Run: godot --headless --path Godot -s tests/test_mixer_channel_drop.gd -- --test
#
# Mixer and the drop classes reference autoloads, so they are loaded with load() instead of named.
extends TestBase

var _project_script: GDScript
var _mixer: Object
var _drop_target: GDScript
var _channel_drag: GDScript
var _project: Object


func suite_name() -> String:
	return "Mixer channel drop tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_drop_target = load("res://mixer/MixerChannelDropTarget.gd")
	_channel_drag = load("res://mixer/MixerChannelDrag.gd")
	await _test_drop_on_group_strip_nests()
	await _test_drop_in_foldout_inserts_at_index()
	await _test_drop_on_root_pane_unnests()
	await _test_root_strips_reorder_on_drop()
	await _test_buses_reorder_on_drop()
	await _test_nested_header_rows_line_up()


## Fresh project + Mixer: Group with children A and B, plus a root strip C.
func _setup() -> Dictionary:
	if _mixer:
		_mixer.free()
	_project = _project_script.new()
	_mixer = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	_mixer.size = Vector2(1400, 600)
	root.add_child(_mixer)
	_mixer._on_project_opened(_project)
	var group: Dictionary = _project.create_group_track("Group")
	var a: Dictionary = _project.create_instrument_track("A")
	var b: Dictionary = _project.create_instrument_track("B")
	var c: Dictionary = _project.create_instrument_track("C")
	_project.place_track(a.track, group.track.id, null)
	_project.place_track(b.track, group.track.id, a.track)
	# The root C strip is spawned after A/B left the root; keep it after Group.
	await process_frame
	await process_frame
	return {"group": group.channel, "a": a.channel, "b": b.channel, "c": c.channel}


func _strip(ch: Object) -> Object:
	return _mixer.find_mixer_channel_ui_for_channel(ch)


func _drag(ch: Object) -> Object:
	return _channel_drag.new(_strip(ch), ch, null)


func _test_drop_on_group_strip_nests() -> void:
	var chs: Dictionary = await _setup()
	var group_strip: Object = _strip(chs.group)
	_assert(group_strip != null and _strip(chs.c) != null, "group and root strips exist")
	# Group strip body (below the header) is not a nest target: it inserts beside the group.
	var column: Rect2 = group_strip.get_strip_column_rect()
	var body_target: Object = _drop_target.resolve(_mixer, _drag(chs.c), Vector2(column.get_center().x, column.end.y - 4))
	_assert(body_target.kind == _drop_target.Kind.REORDER, "group strip body reorders: %d" % body_target.kind)

	# The fold-out's parent-colored bar nests too.
	var bar_rect: Rect2 = group_strip.children_slide.parent_header.get_global_rect()
	var bar_target: Object = _drop_target.resolve(_mixer, _drag(chs.c), bar_rect.get_center())
	_assert(bar_target.kind == _drop_target.Kind.NEST and bar_target.parent == chs.group, "fold-out bar nests")

	var header_rect: Rect2 = group_strip.header.get_global_rect()
	var target: Object = _drop_target.resolve(_mixer, _drag(chs.c), header_rect.get_center())
	_assert(target.kind == _drop_target.Kind.NEST, "group header resolves to nest: %d" % target.kind)
	_assert(target.parent == chs.group, "nest parent is the group")
	_assert(target.after_sibling == chs.b, "nest appends after the last child")
	_assert(target.indicator_rect == header_rect, "glow outlines the group header")

	_assert(target.commit(_mixer, _drag(chs.c)), "commit nests")
	_assert(chs.group.child_channel_ids == [chs.a.id, chs.b.id, chs.c.id], "C appended: %s" % str(chs.group.child_channel_ids))


func _test_drop_in_foldout_inserts_at_index() -> void:
	var chs: Dictionary = await _setup()
	var a_strip: Object = _strip(chs.a)
	_assert(a_strip != null and a_strip.get_parent().get("nest_parent") != null, "A is nested in the fold-out")
	# Left half of A: insert before A, not nest under A.
	var a_rect: Rect2 = a_strip.get_strip_column_rect()
	var point: Vector2 = Vector2(a_rect.position.x + 2, a_rect.get_center().y)
	var target: Object = _drop_target.resolve(_mixer, _drag(chs.c), point)
	_assert(target.kind == _drop_target.Kind.INSERT, "nested strip resolves to insert: %d" % target.kind)
	_assert(target.parent == chs.group and target.after_sibling == null, "insert first under the group")
	_assert(absf(target.indicator_rect.get_center().x - a_rect.position.x) <= 2.0, "line sits at A's left edge")

	# Right half of A: insert between A and B.
	point = Vector2(a_rect.end.x - 2, a_rect.get_center().y)
	target = _drop_target.resolve(_mixer, _drag(chs.c), point)
	_assert(target.after_sibling == chs.a, "right half of A inserts after A")
	_assert(target.commit(_mixer, _drag(chs.c)), "commit inserts")
	_assert(chs.group.child_channel_ids == [chs.a.id, chs.c.id, chs.b.id], "C between A and B: %s" % str(chs.group.child_channel_ids))
	_assert(chs.c.parent_channel_id == chs.group.id, "C nested")

	# Reorder a child inside the fold-out by dragging: B before A.
	await process_frame
	a_rect = _strip(chs.a).get_strip_column_rect()
	target = _drop_target.resolve(_mixer, _drag(chs.b), Vector2(a_rect.position.x + 2, a_rect.get_center().y))
	_assert(target.kind == _drop_target.Kind.INSERT and target.after_sibling == null, "B resolves to first")
	_assert(target.commit(_mixer, _drag(chs.b)), "reorder commits")
	_assert(chs.group.child_channel_ids == [chs.b.id, chs.a.id, chs.c.id], "B moved first: %s" % str(chs.group.child_channel_ids))


func _test_drop_on_root_pane_unnests() -> void:
	var chs: Dictionary = await _setup()
	var c_rect: Rect2 = _strip(chs.c).get_strip_column_rect()
	# Left half of the root C strip: un-nest A to sit just before C.
	var point: Vector2 = Vector2(c_rect.position.x + 2, c_rect.get_center().y)
	var target: Object = _drop_target.resolve(_mixer, _drag(chs.a), point)
	_assert(target.kind == _drop_target.Kind.UNNEST, "root strip resolves to un-nest: %d" % target.kind)
	_assert(target.after_sibling == chs.group, "un-nest after the group strip")

	var group_rect: Rect2 = _strip(chs.group).get_global_rect()

	_assert(target.commit(_mixer, _drag(chs.a)), "un-nest commits")
	await process_frame
	_assert(chs.a.parent_channel_id == -1, "A un-nested")
	_assert(chs.group.child_channel_ids == [chs.b.id], "group keeps B only")
	var a_strip: Object = _strip(chs.a)
	_assert(a_strip != null and a_strip.get_parent() == _mixer.left_channels, "A strip is in the root pane")
	_assert(a_strip.get_index() == _strip(chs.c).get_index() - 1, "A placed right before C")
	_assert(group_rect.size.x > 0, "layout ran")


## Nested headers shrink by the fold-out bar so every header bottom sits on the same row, two levels deep.
func _test_nested_header_rows_line_up() -> void:
	var chs: Dictionary = await _setup()
	var inner: Dictionary = _project.create_group_track("Inner")
	var d: Dictionary = _project.create_instrument_track("D")
	_project.place_track(inner.track, _project.get_channel_paired_track(chs.group).id, null)
	_project.place_track(d.track, inner.track.id, null)
	for i in 3:
		await process_frame
	var group_strip: Object = _strip(chs.group)
	var a_strip: Object = _strip(chs.a)
	var d_strip: Object = _strip(d.channel)
	_assert(group_strip.children_slide.parent_header.size.y == group_strip.children_header_height, "fold-out bar uses children_header_height")
	var parent_bottom: float = group_strip.header.get_global_rect().end.y
	_assert(absf(a_strip.header.get_global_rect().end.y - parent_bottom) < 1.0,
		"nested header bottom lines up: %f vs %f" % [a_strip.header.get_global_rect().end.y, parent_bottom])
	_assert(d_strip != null and d_strip.header.size.y < a_strip.header.size.y, "second level header is shorter")
	_assert(absf(d_strip.header.get_global_rect().end.y - parent_bottom) < 1.0,
		"second level header lines up: %f vs %f" % [d_strip.header.get_global_rect().end.y, parent_bottom])


## Root strips move only on drop, to the gap under the pointer.
func _test_root_strips_reorder_on_drop() -> void:
	var chs: Dictionary = await _setup()
	var group_strip: Object = _strip(chs.group)
	var c_strip: Object = _strip(chs.c)
	_assert(c_strip.get_index() > group_strip.get_index(), "C starts after the group")
	var g_rect: Rect2 = group_strip.get_strip_column_rect()
	var target: Object = _drop_target.resolve(_mixer, _drag(chs.c), Vector2(g_rect.position.x + 2, g_rect.end.y - 4))
	_assert(target.kind == _drop_target.Kind.REORDER and target.after_sibling == null, "C resolves to first")
	_assert(absf(target.indicator_rect.get_center().x - group_strip.get_global_rect().position.x) <= 2.0, "line at the group's left edge")
	_assert(c_strip.get_index() > group_strip.get_index(), "resolving does not move anything")
	_assert(target.commit(_mixer, _drag(chs.c)), "reorder commits")
	_assert(c_strip.get_index() < group_strip.get_index(), "C moved before the group")
	_assert(chs.c.order < chs.group.order, "order persisted: %d vs %d" % [chs.c.order, chs.group.order])
	# Dropping back into its own slot is a no-op.
	await process_frame
	var c_rect: Rect2 = c_strip.get_strip_column_rect()
	target = _drop_target.resolve(_mixer, _drag(chs.c), Vector2(c_rect.position.x + 2, c_rect.end.y - 4))
	_assert(not target.commit(_mixer, _drag(chs.c)), "dropping in place changes nothing")


## Buses reorder among themselves in the right pane and never nest or leave it.
func _test_buses_reorder_on_drop() -> void:
	await _setup()
	var bus1: Object = _project.create_bus_channel("Bus 1")
	var bus2: Object = _project.create_bus_channel("Bus 2")
	await process_frame
	await process_frame
	var s1: Object = _strip(bus1)
	var s2: Object = _strip(bus2)
	_assert(s1 != null and s2 != null and s1.get_parent() == _mixer.right_channels, "bus strips in right pane")
	var r1: Rect2 = s1.get_strip_column_rect()
	var target: Object = _drop_target.resolve(_mixer, _drag(bus2), Vector2(r1.position.x + 2, r1.end.y - 4))
	_assert(target.kind == _drop_target.Kind.REORDER, "bus resolves to reorder: %d" % target.kind)
	_assert(target.commit(_mixer, _drag(bus2)), "bus reorder commits")
	_assert(s2.get_index() < s1.get_index(), "Bus 2 before Bus 1")
	var left: Rect2 = _mixer.left_pane.get_global_rect()
	var left_target: Object = _drop_target.resolve(_mixer, _drag(bus1), left.get_center())
	_assert(not left_target.is_valid(), "bus cannot drop into the left pane")
