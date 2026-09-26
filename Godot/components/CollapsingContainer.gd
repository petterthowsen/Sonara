# CollapsingContainer.gd
# Base for containers that hide children that don't fit, instead of growing to fit them
# (CollapsingBoxContainer, CollapsingFlowContainer). Their minimum size ignores
# collapsible children, so they are sized from outside (parent expand flags, a
# SplitContainer, a user-resized track height...), and children are shown or hidden to
# match. Showing is deterministic: the hidden set is always a prefix of the hide order,
# so the layout never flickers.
#
# Per-child options, stored as metadata (settable in the inspector or via the helpers):
#   collapse_priority (int, default 0): lower hides first. Ties use `hide_order`.
#   collapse_pinned  (bool): never hidden; counts toward the container's minimum size.
# `min_visible_children` keeps the N children that would hide last (pinned ones count)
# as if they were pinned.
#
# Hiding uses `visible`. The container remembers which children it hid, so a child you
# hide yourself stays hidden. Limitation: setting `visible = false` on a child that is
# currently collapsed emits no signal, so the container will show it again when there
# is room. Remove it from the container or pin/unpin it instead if that matters.
#
# Subclasses implement _get_minimum_size() and _sort(), and call _set_collapsed().
@tool
@abstract
class_name CollapsingContainer extends Container

## Emitted when the set of collapsed children changes, e.g. to fill an overflow menu.
signal collapsed_changed(collapsed: Array[Control])

enum HideOrder { LAST_FIRST, FIRST_FIRST }

const META_PRIORITY := &"collapse_priority"
const META_PINNED := &"collapse_pinned"

@export var vertical: bool = false:
	set(value):
		vertical = value
		_relayout()
@export var hide_order: HideOrder = HideOrder.LAST_FIRST:
	set(value):
		hide_order = value
		_relayout()
## Never hide the last N children in hide order, e.g. the first 2 with LAST_FIRST.
## Pinned children count toward N. Kept children count toward the minimum size.
@export_range(0, 16, 1, "or_greater") var min_visible_children: int = 0:
	set(value):
		min_visible_children = maxi(0, value)
		_relayout()

# Children this container hid (Control -> true). Anything else hidden was hidden by its owner.
var _collapsed: Dictionary = {}
# Guards our own `visible` writes from _on_child_visibility_changed.
var _applying: bool = false
# Bound visibility_changed handlers per child (Control -> Callable), for disconnecting.
var _vis_handlers: Dictionary = {}


func _init() -> void:
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)


# ============================================================================
# PUBLIC API
# ============================================================================

static func set_child_priority(child: Control, priority: int) -> void:
	child.set_meta(META_PRIORITY, priority)
	_requeue_parent(child)


static func set_child_pinned(child: Control, pinned: bool) -> void:
	child.set_meta(META_PINNED, pinned)
	_requeue_parent(child)


func is_collapsed(child: Control) -> bool:
	return _collapsed.has(child)


func get_collapsed_children() -> Array[Control]:
	var out: Array[Control] = []
	for c in get_children():
		if _collapsed.has(c):
			out.append(c)
	return out


# ============================================================================
# CONTAINER
# ============================================================================

## Decide what is shown (via _set_collapsed) and lay it out.
@abstract func _sort() -> void


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_SORT_CHILDREN:
			_sort()
		NOTIFICATION_EDITOR_PRE_SAVE:
			# Don't save our runtime hiding into the scene file.
			_set_collapsed({})
		NOTIFICATION_EDITOR_POST_SAVE:
			queue_sort()


# ============================================================================
# HELPERS
# ============================================================================

# Children taking part in layout: visible ones plus the ones we hid.
func _candidates() -> Array[Control]:
	var out: Array[Control] = []
	for n in get_children():
		var c := n as Control
		if c == null or c.top_level:
			continue
		if c.visible or _collapsed.has(c):
			out.append(c)
	return out


# Children never hidden (Control -> true): pinned ones, plus enough of the last in
# hide order to reach min_visible_children. Independent of size, so the minimum is stable.
func _kept(candidates: Array[Control]) -> Dictionary:
	var kept := {}
	var rest: Array[Control] = []
	for c in candidates:
		if _is_pinned(c):
			kept[c] = true
		else:
			rest.append(c)
	var extra := mini(min_visible_children - kept.size(), rest.size())
	if extra > 0:
		_sort_by_hide_order(rest, candidates)
		for i in extra:
			kept[rest[rest.size() - 1 - i]] = true
	return kept


# Collapse every candidate not in `shown`.
func _collapse_all_but(candidates: Array[Control], shown: Array[Control]) -> void:
	var new_collapsed := {}
	for c in candidates:
		if not shown.has(c):
			new_collapsed[c] = true
	_set_collapsed(new_collapsed)


func _set_collapsed(new_collapsed: Dictionary) -> void:
	if new_collapsed.size() == _collapsed.size():
		var same := true
		for c in new_collapsed:
			if not _collapsed.has(c):
				same = false
				break
		if same:
			return
	_applying = true
	for c: Control in _collapsed:
		if is_instance_valid(c) and not new_collapsed.has(c):
			c.visible = true
	for c: Control in new_collapsed:
		c.visible = false
	_applying = false
	_collapsed = new_collapsed
	collapsed_changed.emit(get_collapsed_children())


# Earliest-to-hide first: lowest priority, then by position per hide_order.
func _sort_by_hide_order(list: Array[Control], order: Array[Control]) -> void:
	var last_first := hide_order == HideOrder.LAST_FIRST
	list.sort_custom(func(a: Control, b: Control) -> bool:
		var pa := _priority(a)
		var pb := _priority(b)
		if pa != pb:
			return pa < pb
		var ia := order.find(a)
		var ib := order.find(b)
		return ia > ib if last_first else ia < ib)


# Main-axis lengths (Control -> float) for `items` sharing `avail` (separations already
# taken out). Same rule as BoxContainer: expanders split the leftover space by stretch
# ratio, except one whose share is below its minimum, which is held at its minimum.
# Returns whether any child ended up expanding.
func _distribute(items: Array[Control], avail: float, lengths: Dictionary) -> bool:
	var mins := {}
	var fixed := 0.0
	var flex: Array[Control] = []
	for c in items:
		mins[c] = _main(c.get_combined_minimum_size())
		if _expands(c):
			flex.append(c)
		else:
			fixed += mins[c]
	var clamped := true
	while clamped and not flex.is_empty():
		clamped = false
		var pool := avail - fixed
		var ratio_total := 0.0
		for c in flex:
			ratio_total += c.size_flags_stretch_ratio
		for c in flex:
			var share: float = pool * c.size_flags_stretch_ratio / ratio_total if ratio_total > 0.0 else 0.0
			if share < mins[c]:
				flex.erase(c)
				fixed += mins[c]
				clamped = true
				break
			lengths[c] = share
	for c in items:
		if not lengths.has(c):
			lengths[c] = mins[c]
	return not flex.is_empty()


# Offset for `spare` main-axis space, for any BEGIN/CENTER/END alignment enum.
static func _align_offset(align: int, spare: float) -> float:
	match align:
		1:
			return floorf(maxf(0.0, spare) / 2.0)
		2:
			return maxf(0.0, spare)
	return 0.0


func _expands(c: Control) -> bool:
	var flags := c.size_flags_vertical if vertical else c.size_flags_horizontal
	return flags & SIZE_EXPAND != 0


func _main(v: Vector2) -> float:
	return v.y if vertical else v.x


func _cross(v: Vector2) -> float:
	return v.x if vertical else v.y


func _rect(main_ofs: float, cross_ofs: float, main_len: float, cross_len: float) -> Rect2:
	if vertical:
		return Rect2(cross_ofs, main_ofs, cross_len, main_len)
	return Rect2(main_ofs, cross_ofs, main_len, cross_len)


static func _priority(c: Control) -> int:
	return int(c.get_meta(META_PRIORITY, 0))


static func _is_pinned(c: Control) -> bool:
	return bool(c.get_meta(META_PINNED, false))


static func _requeue_parent(child: Control) -> void:
	var parent := child.get_parent() as CollapsingContainer
	if parent:
		parent._relayout()


func _relayout() -> void:
	update_minimum_size()
	queue_sort()


func _on_child_entered(node: Node) -> void:
	if node is Control and not _vis_handlers.has(node):
		var handler := _on_child_visibility_changed.bind(node)
		_vis_handlers[node] = handler
		node.visibility_changed.connect(handler)


func _on_child_exiting(node: Node) -> void:
	if _vis_handlers.has(node):
		node.visibility_changed.disconnect(_vis_handlers[node])
		_vis_handlers.erase(node)
	if _collapsed.has(node):
		# Hand it back visible, e.g. when reparented elsewhere.
		_collapsed.erase(node)
		_applying = true
		node.visible = true
		_applying = false


func _on_child_visibility_changed(child: Control) -> void:
	if _applying:
		return
	# The owner changed visibility itself, so it's no longer ours to manage.
	_collapsed.erase(child)
	_relayout()
