# TrackDropTarget.gd
# Where a track header drag lands under the pointer: nest into a folder/group (middle of its header),
# or insert at a position and nesting level (pointer Y picks the gap, X picks the level). Nothing
# moves while dragging; the drop handlers and the drop indicator both resolve through here.
class_name TrackDropTarget extends RefCounted

enum Kind { NONE, INSERT, NEST }

## Fraction of a folder header's height, at its top and bottom, that inserts instead of nesting.
const NEST_EDGE := 0.25

## Width of the left gutter (past an item's indent) that pulls a drop out one folder level.
const UNNEST_GUTTER := 20.0

var kind: Kind = Kind.NONE

## Parent track id for the dragged roots (-1 = root level).
var parent_id: int = -1

## Sibling the first dragged root sits after (null = first).
var after_sibling: Track = null

## Global rect to draw: the folder header for NEST, a thin line at the target level otherwise.
var indicator_rect: Rect2 = Rect2()

var _list: TrackList = null
var _project: Project = null
var _roots: Array[Track] = []


## True when a drop here would do something.
func is_valid() -> bool:
	return kind != Kind.NONE


## True when the indicator outlines a folder header rather than drawing an insert line.
func is_nest() -> bool:
	return kind == Kind.NEST


## Resolve the target for `drag` at global `mouse` inside `list`.
static func resolve(list: TrackList, drag: TrackDrag, mouse: Vector2) -> TrackDropTarget:
	var target := TrackDropTarget.new()
	if list == null or drag == null or list.current_project == null or drag.tracks.is_empty():
		return target
	if not DragDrop.is_point_visible(list, mouse):
		return target
	target._list = list
	target._project = list.current_project
	target._roots = drag.tracks
	target._resolve(mouse)
	return target


## Apply this target through history. Returns true when the layout changed.
func commit(_drag: TrackDrag = null) -> bool:
	if not is_valid():
		return false
	var before := TrackReorderCommand.capture_layout(_project)
	_project.begin_track_layout_batch()
	var after := after_sibling
	for root in _roots:
		_project.place_track(root, parent_id, after)
		after = root
	_project.end_track_layout_batch()
	var after_layout := TrackReorderCommand.capture_layout(_project)
	if TrackReorderCommand.layouts_equal(before, after_layout):
		return false
	HistoryUtil.record(TrackReorderCommand.new(_project, before, after_layout))
	# Dropping into a collapsed folder unfolds it, so the moved tracks stay visible.
	var parent := _project.get_track_by_id(parent_id) if parent_id >= 0 else null
	if parent and not parent.is_folder_expanded:
		parent.is_folder_expanded = true
	return true


func _resolve(mouse: Vector2) -> void:
	var subtree := _dragged_subtree_ids()
	var remaining: Array[TrackItem] = []
	for child in _list.get_children():
		if child is TrackItem:
			var item := child as TrackItem
			if item.track and item.visible and not subtree.has(item.track.id):
				remaining.append(item)
	if remaining.is_empty():
		return

	var hovered: TrackItem = null
	var insert_before := true
	for item in remaining:
		var rect := item.get_global_rect()
		if mouse.y < rect.position.y + rect.size.y * 0.5:
			hovered = item
			insert_before = true
			break
		if mouse.y < rect.end.y:
			hovered = item
			insert_before = false
			break
	if hovered == null:
		hovered = remaining.back()
		insert_before = false

	# Middle of a folder/group header: append inside it.
	var hovered_rect := hovered.get_global_rect()
	if hovered.track.can_contain_tracks() and hovered_rect.has_point(mouse):
		var edge := hovered_rect.size.y * NEST_EDGE
		if mouse.y > hovered_rect.position.y + edge and mouse.y < hovered_rect.end.y - edge:
			if _try_set(Kind.NEST, hovered.track.id, _last_child_except_roots(hovered.track)):
				indicator_rect = hovered_rect
				return

	var local_x := mouse.x - _list.get_global_rect().position.x
	var placement: Dictionary
	var skip := _dragged_root_ids()
	if insert_before:
		placement = _placement_before(hovered.track, _desired_level_before(hovered.track, local_x), skip)
	else:
		var nest_into_parent := (
			hovered.track.can_contain_tracks()
			and mouse.x >= hovered_rect.get_center().x
		)
		placement = _placement_after(
			hovered.track,
			_desired_level_after(hovered.track, local_x, nest_into_parent),
			skip
		)
	if _try_set(Kind.INSERT, int(placement["parent_id"]), placement.get("after_sibling")):
		indicator_rect = _insert_line_rect()


## Take `p_kind` when every dragged root may move under `p_parent_id`.
func _try_set(p_kind: Kind, p_parent_id: int, p_after: Track) -> bool:
	for root in _roots:
		if not _project.can_place_track(root, p_parent_id):
			return false
	kind = p_kind
	parent_id = p_parent_id
	after_sibling = p_after
	return true


## Horizontal line below the rows the drop lands after, indented to the target nesting level.
func _insert_line_rect() -> Rect2:
	var list_rect := _list.get_global_rect()
	var anchor_ids: Dictionary = {}
	if after_sibling:
		_collect_subtree_ids(after_sibling, anchor_ids)
	elif parent_id >= 0:
		anchor_ids[parent_id] = true
	var y := -1.0
	var first_top := -1.0
	var next_top := -1.0
	for child in _list.get_children():
		var row_track: Track = null
		if child is TrackItem or child is AutomationLaneHeader:
			row_track = child.track
		if row_track == null or not child.visible:
			continue
		var rect := (child as Control).get_global_rect()
		if first_top < 0.0:
			first_top = rect.position.y
		if anchor_ids.has(row_track.id):
			y = rect.end.y
			next_top = -1.0
		elif y >= 0.0 and next_top < 0.0:
			next_top = rect.position.y
	if y >= 0.0 and next_top >= 0.0:
		# Center the line in the gap between rows.
		y = (y + next_top) * 0.5
	if y < 0.0 and after_sibling and parent_id >= 0:
		# The sibling is folded away: sit right under the parent.
		for child in _list.get_children():
			if (child is TrackItem or child is AutomationLaneHeader) and child.visible and child.track and child.track.id == parent_id:
				y = (child as Control).get_global_rect().end.y
	if y < 0.0:
		y = first_top if first_top >= 0.0 else list_rect.position.y
	var clip := DragDrop.visible_rect(_list)
	var half := DropIndicator.LINE_WIDTH * 0.5
	y = clampf(y, clip.position.y + half, clip.end.y - half)

	var level := 0
	var parent := _project.get_track_by_id(parent_id) if parent_id >= 0 else null
	if parent:
		level = parent.get_nesting_level(_project) + 1
	var indent := minf(float(level * _list.folder_indent_pixels), list_rect.size.x)
	var span := Rect2(list_rect.position.x + indent, list_rect.position.y, list_rect.size.x - indent, list_rect.size.y)
	return DropIndicator.line_rect(y, span, false)


## Last child of `parent` that isn't being dragged, or null.
func _last_child_except_roots(parent: Track) -> Track:
	var skip := _dragged_root_ids()
	var children := _project.get_track_children(parent)
	for i in range(children.size() - 1, -1, -1):
		if not skip.has(children[i].id):
			return children[i]
	return null


## Nesting level when inserting after `item`. Right half of a folder/group nests; a left gutter un-nests.
func _desired_level_after(item: Track, local_x: float, nest_into_parent: bool) -> int:
	var item_level := item.get_nesting_level(_project)
	if nest_into_parent and item.can_contain_tracks():
		return item_level + 1
	return _desired_level_from_x(item_level, local_x)


## Nesting level when inserting before `item`: same as `item`, or one level shallower in the left gutter.
func _desired_level_before(item: Track, local_x: float) -> int:
	return _desired_level_from_x(item.get_nesting_level(_project), local_x)


## Keep `item_level` unless the pointer is in the left gutter, which pulls out one folder level.
func _desired_level_from_x(item_level: int, local_x: float) -> int:
	if item_level <= 0:
		return 0
	var item_indent := float(item_level * _list.folder_indent_pixels)
	if local_x < item_indent + UNNEST_GUTTER:
		return item_level - 1
	return item_level


## Insert before `item`, un-nesting when the pointer is left of `item`'s indent.
func _placement_before(item: Track, desired_level: int, skip: Dictionary) -> Dictionary:
	var item_level := item.get_nesting_level(_project)
	var level := clampi(desired_level, 0, item_level)
	var cursor := item
	while cursor:
		var cursor_level := cursor.get_nesting_level(_project)
		if cursor_level <= level:
			return {
				"parent_id": cursor.parent_track_id,
				"after_sibling": _previous_sibling(cursor, skip),
			}
		if cursor.parent_track_id < 0:
			break
		cursor = _project.get_track_by_id(cursor.parent_track_id)
	return {
		"parent_id": item.parent_track_id,
		"after_sibling": _previous_sibling(item, skip),
	}


## Insert after `item`; indenting into a folder/group makes the dragged tracks its first children.
func _placement_after(item: Track, desired_level: int, skip: Dictionary) -> Dictionary:
	var item_level := item.get_nesting_level(_project)
	var max_level := item_level + (1 if item.can_contain_tracks() else 0)
	var level := clampi(desired_level, 0, max_level)
	if item.can_contain_tracks() and level > item_level:
		var nest_blocked := false
		for root in _roots:
			if _project.track_is_in_subtree(item.id, root):
				nest_blocked = true
				break
		if not nest_blocked:
			return {"parent_id": item.id, "after_sibling": null}

	var cursor := item
	while cursor:
		var cursor_level := cursor.get_nesting_level(_project)
		if cursor_level <= level:
			var after: Track = cursor
			if skip.has(cursor.id):
				after = _previous_sibling(cursor, skip)
			return {
				"parent_id": cursor.parent_track_id,
				"after_sibling": after,
			}
		if cursor.parent_track_id < 0:
			return {"parent_id": -1, "after_sibling": cursor}
		cursor = _project.get_track_by_id(cursor.parent_track_id)
	return {"parent_id": item.parent_track_id, "after_sibling": item}


## Sibling directly above `track` in the same folder, skipping dragged roots.
func _previous_sibling(track: Track, skip: Dictionary) -> Track:
	var siblings: Array[Track] = []
	for t in _project.tracks:
		if t.parent_track_id == track.parent_track_id:
			siblings.append(t)
	siblings.sort_custom(func(a, b): return a.order < b.order)
	var previous: Track = null
	for sibling in siblings:
		if sibling == track:
			break
		if not skip.has(sibling.id):
			previous = sibling
	return previous


## IDs of movable drag roots (not their descendants).
func _dragged_root_ids() -> Dictionary:
	var ids: Dictionary = {}
	for root in _roots:
		ids[root.id] = true
	return ids


## Every track that moves with the drag, including nested descendants.
func _dragged_subtree_ids() -> Dictionary:
	var ids: Dictionary = {}
	for root in _roots:
		_collect_subtree_ids(root, ids)
	return ids


## Recursively record `track` and its descendants into `ids`.
func _collect_subtree_ids(track: Track, ids: Dictionary) -> void:
	if track == null:
		return
	ids[track.id] = true
	if not track.can_contain_tracks():
		return
	for child in _project.get_track_children(track):
		_collect_subtree_ids(child, ids)
