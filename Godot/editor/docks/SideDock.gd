# Left or right side dock: stacks DockPanels and DockTabs groups in a vertical split with overlay drop targets.
# An empty dock is hidden, and reappears as a thin drop strip while a panel is being dragged.
class_name SideDock extends Control

## Where a dragged panel lands relative to the item under the pointer.
enum Zone { NONE, BEFORE, CENTER, AFTER, APPEND }

## Minimum width while this dock holds at least one panel.
@export var occupied_min_width: float = 200.0

## Width of an empty dock while it is shown as a drop strip during a panel drag.
@export var empty_min_width: float = 40.0

const _AVAILABLE := Color(0.45, 0.62, 0.95, 0.12)
const _HOVER := Color(0.55, 0.75, 1.0, 0.32)
const _HOVER_EDGE := Color(0.65, 0.82, 1.0, 0.9)
const _SLOT_LINE := Color(0.65, 0.82, 1.0, 0.45)
## Upper bound for the body's before/after bands so tall panels keep a large tab-into center.
const _EDGE_BAND_MAX := 64.0
## Thin stack-above band at the top edge of each item, above its title bar or tab strip.
const _SLOT_BAND := 8.0

var _split: VSplitContainer
var _overlay: _DropOverlay
var _hover: Dictionary = {}
var _panel_drag_active: bool = false
var _empty_layout: bool = false
var _occupied_size_flags: int = 0
var _item_count: int = 0
## Parent split offsets saved while empty, so the thin strip doesn't overwrite the user's width.
var _stashed_offsets: PackedInt32Array = PackedInt32Array()


## Build chrome, wrap any scene children as dock panels, then size the empty state.
func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	_occupied_size_flags = size_flags_horizontal
	custom_minimum_size.x = occupied_min_width
	_build()
	_adopt_existing_children()
	_sync_empty_state()


## Show empty docks as drop strips for the duration of a panel drag.
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		_panel_drag_active = get_viewport().gui_get_drag_data() is DockDrag
		if _panel_drag_active:
			_sync_empty_state()
	elif what == NOTIFICATION_DRAG_END:
		if _panel_drag_active:
			_panel_drag_active = false
			_clear_hover()
			_sync_empty_state()


## Top-level stack entries: DockPanels and DockTabs, top to bottom.
func get_items() -> Array[Control]:
	var items: Array[Control] = []
	if _split == null:
		return items
	for child in _split.get_children():
		if child is DockPanel or child is DockTabs:
			items.append(child)
	return items


## Every DockPanel in this dock, top to bottom, tab groups flattened in tab order.
func get_panels() -> Array[DockPanel]:
	var panels: Array[DockPanel] = []
	for item in get_items():
		if item is DockTabs:
			panels.append_array((item as DockTabs).get_panels())
		else:
			panels.append(item)
	return panels


## Serializable stack: a panel id per lone panel, `{tabs, current}` per tab group.
func get_layout() -> Array:
	var entries: Array = []
	for item in get_items():
		if item is DockTabs:
			var tabs := item as DockTabs
			var ids: Array = []
			for panel in tabs.get_panels():
				ids.append(panel.panel_id)
			entries.append({"tabs": ids, "current": tabs.current_tab})
		else:
			entries.append((item as DockPanel).panel_id)
	return entries


## Remove every panel without freeing it; tab groups are dissolved.
func take_panels() -> Array[DockPanel]:
	var panels := get_panels()
	for panel in panels:
		_detach(panel)
	normalize()
	return panels


## Wrap a raw editor control (or keep an existing DockPanel) and insert it.
func add_content(content: Control, index: int = -1) -> DockPanel:
	var panel := content as DockPanel
	if panel == null:
		panel = _wrap(content)
	insert_panel(panel, index)
	return panel


## Detach `panel` from this dock (stack or tab group) without freeing it.
func remove_panel(panel: DockPanel) -> void:
	if panel.get_parent_dock() != self:
		return
	_detach(panel)
	normalize()


## Place `panel` as a lone stack item at `index` (-1 appends).
func insert_panel(panel: DockPanel, index: int = -1) -> void:
	if panel.get_parent() == _split:
		var current := panel.get_index()
		var target := index
		if target < 0 or target > _split.get_child_count():
			target = _split.get_child_count()
		if current < target:
			target -= 1
		if current != target:
			_split.move_child(panel, target)
		return
	_detach(panel)
	var count := _split.get_child_count()
	if index < 0 or index > count:
		index = count
	_split.add_child(panel)
	_split.move_child(panel, index)
	normalize()


## Append `panels` as one tab group with `current` selected; a single panel is stacked alone.
func append_tab_group(panels: Array[DockPanel], current: int = 0) -> void:
	if panels.is_empty():
		return
	insert_panel(panels[0], -1)
	var anchor: Control = panels[0]
	for i in range(1, panels.size()):
		_tab_into(anchor, panels[i], -1)
		anchor = panels[0].get_parent_tabs()
	var tabs := panels[0].get_parent_tabs()
	if tabs:
		tabs.current_tab = clampi(current, 0, tabs.get_tab_count() - 1)


## Move `panel` to `target` (from drop_target_at). Tab groups left with one panel dissolve.
func apply_drop(panel: DockPanel, target: Dictionary) -> void:
	var zone: int = target.get("zone", Zone.NONE)
	var item: Control = target.get("item")
	match zone:
		Zone.APPEND:
			insert_panel(panel, -1)
		Zone.BEFORE, Zone.AFTER:
			if item == panel:
				return
			_detach(panel)
			insert_panel(panel, item.get_index() + (1 if zone == Zone.AFTER else 0))
		Zone.CENTER:
			_tab_into(item, panel, target.get("tab", -1))
	normalize()


## Replace one-panel tab groups with their panel and drop empty ones.
func normalize() -> void:
	if _split == null:
		return
	for item in get_items():
		if not item is DockTabs:
			continue
		var tabs := item as DockTabs
		var panels := tabs.get_panels()
		if panels.size() >= 2:
			tabs.refresh_titles()
			continue
		var offsets := _split.split_offsets
		var index := tabs.get_index()
		if panels.size() == 1:
			var panel := panels[0]
			_detach(panel)
			_split.add_child(panel)
			_split.move_child(panel, index)
		_split.remove_child(tabs)
		tabs.queue_free()
		if offsets.size() == _split.split_offsets.size():
			_split.split_offsets = offsets
	_sync_empty_state()


## Current VSplit offsets, empty when this dock has fewer than two items.
func get_split_offsets() -> Array:
	if _split == null or _split.get_child_count() < 2:
		return []
	var values: Array = []
	for value in _split.split_offsets:
		values.append(int(value))
	return values


## Restore previously saved split offsets after panels have been inserted.
func apply_split_offsets(offsets: Array) -> void:
	if _split == null or offsets.is_empty() or _split.get_child_count() < 2:
		return
	var packed := PackedInt32Array()
	for value in offsets:
		packed.append(int(value))
	_split.split_offsets = packed


## Parent split offsets as they are while this dock is occupied.
func get_parent_split_offsets() -> PackedInt32Array:
	if _empty_layout:
		return _stashed_offsets
	var split := get_parent() as SplitContainer
	return split.split_offsets if split else PackedInt32Array()


## Set parent split offsets; while empty they are stashed until a panel arrives.
func set_parent_split_offsets(offsets: PackedInt32Array) -> void:
	if offsets.is_empty():
		return
	if _empty_layout:
		_stashed_offsets = offsets
		return
	var split := get_parent() as SplitContainer
	if split:
		split.split_offsets = offsets


## Drop target under `local_pos`: `{zone, item, tab}`. `tab` is the insert tab index for CENTER.
## Per item, top to bottom: a thin stack-above slot, the header (title bar or tab strip) which tabs,
## then the body: top band stacks above, middle tabs, bottom band stacks below.
func drop_target_at(local_pos: Vector2) -> Dictionary:
	var items := get_items()
	if items.is_empty():
		return {"zone": Zone.APPEND, "item": null, "tab": -1}
	var global_pos := local_pos + global_position
	for i in range(items.size()):
		var item := items[i]
		var rect := _local_rect(item)
		if local_pos.y > rect.end.y and i < items.size() - 1:
			continue
		if local_pos.y < rect.position.y + _SLOT_BAND:
			return {"zone": Zone.BEFORE, "item": item, "tab": -1}
		var body_top := _header_bottom(item)
		if local_pos.y < body_top:
			var tab := -1
			if item is DockTabs:
				tab = (item as DockTabs).tab_index_at_global(global_pos)
			return {"zone": Zone.CENTER, "item": item, "tab": tab}
		var edge := minf((rect.end.y - body_top) * 0.25, _EDGE_BAND_MAX)
		var zone := Zone.CENTER
		if local_pos.y > rect.end.y - edge:
			zone = Zone.AFTER
		elif local_pos.y < body_top + edge:
			zone = Zone.BEFORE
		return {"zone": zone, "item": item, "tab": -1}
	return {"zone": Zone.NONE, "item": null, "tab": -1}


## Bottom of an item's header (title bar or tab strip) in dock-local y.
func _header_bottom(item: Control) -> float:
	var header := Rect2()
	if item is DockTabs:
		header = (item as DockTabs).get_tab_strip_global_rect()
	else:
		header = (item as DockPanel).get_title_global_rect()
	if header.size.y <= 0.0:
		return _local_rect(item).position.y
	return header.end.y - global_position.y


## True when dropping `panel` on `target` would leave the layout unchanged.
func is_noop_drop(panel: DockPanel, target: Dictionary) -> bool:
	var zone: int = target.get("zone", Zone.NONE)
	if zone == Zone.NONE:
		return true
	if zone == Zone.APPEND:
		return false
	return target.get("item") == panel


## Create the vertical split and the layout-neutral drop overlay.
func _build() -> void:
	_split = VSplitContainer.new()
	_split.name = "Split"
	_split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_split.dragging_enabled = false
	_split.drag_ended.connect(_on_split_dragged)
	add_child(_split)
	_overlay = _DropOverlay.new()
	_overlay.name = "DropOverlay"
	_overlay.dock = self
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	add_child(_overlay)


## Wrap Control children that were placed in the scene before chrome existed.
func _adopt_existing_children() -> void:
	var adopted: Array[Control] = []
	for child in get_children():
		if child == _split or child == _overlay:
			continue
		if child is Control:
			adopted.append(child)
	for content in adopted:
		add_content(content)


## Build a DockPanel around a raw editor control using its scene node name.
func _wrap(content: Control) -> DockPanel:
	var panel := DockPanel.new()
	panel.name = "%sDock" % content.name
	var id := DockHost.id_for_node(content)
	panel.setup(id, DockHost.title_for_id(id), content)
	return panel


## Pull `panel` out of whatever holds it and restore its stand-alone chrome.
func _detach(panel: DockPanel) -> void:
	if panel.get_parent():
		panel.get_parent().remove_child(panel)
	panel.set_title_visible(true)
	panel.visible = true


## Add `panel` as a tab of `item`, turning a lone panel into a new tab group in place.
func _tab_into(item: Control, panel: DockPanel, tab_index: int) -> void:
	if item is DockTabs:
		(item as DockTabs).add_panel(panel, tab_index)
		return
	var target := item as DockPanel
	if target == null or target == panel:
		return
	_detach(panel)
	var offsets := _split.split_offsets
	var index := target.get_index()
	var tabs := DockTabs.new()
	tabs.name = "Tabs"
	_split.add_child(tabs)
	_split.move_child(tabs, index)
	tabs.add_panel(target)
	tabs.add_panel(panel)
	if offsets.size() == _split.split_offsets.size():
		_split.split_offsets = offsets


## Hide when empty (except as a thin drop strip during a panel drag); keep the user's width stashed.
func _sync_empty_state() -> void:
	if _split == null:
		return
	var count := _split.get_child_count()
	_split.dragging_enabled = count >= 2
	if count != _item_count:
		# Stale offsets from a different stack squeeze new items; share the height evenly instead.
		_item_count = count
		var zeros := PackedInt32Array()
		zeros.resize(maxi(count - 1, 0))
		_split.split_offsets = zeros
	_set_empty_layout(count == 0)
	visible = count > 0 or _panel_drag_active
	_overlay.visible = _panel_drag_active
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP if _panel_drag_active else Control.MOUSE_FILTER_IGNORE
	_overlay.queue_redraw()


## Switch between the user-sized occupied layout and a non-expanding thin strip.
func _set_empty_layout(is_empty: bool) -> void:
	if is_empty == _empty_layout:
		return
	var split := get_parent() as SplitContainer
	if is_empty:
		if split:
			_stashed_offsets = split.split_offsets
			var zeros := PackedInt32Array()
			zeros.resize(_stashed_offsets.size())
			split.split_offsets = zeros
		size_flags_horizontal = Control.SIZE_FILL
		custom_minimum_size.x = empty_min_width
	else:
		size_flags_horizontal = _occupied_size_flags
		custom_minimum_size.x = occupied_min_width
		if split and not _stashed_offsets.is_empty():
			split.split_offsets = _stashed_offsets
	_empty_layout = is_empty


## Item rect in this dock's local coordinates.
func _local_rect(item: Control) -> Rect2:
	var global_rect := item.get_global_rect()
	return Rect2(global_rect.position - global_position, global_rect.size)


## Persist stacked-panel split ratios after the user finishes dragging the VSplit.
func _on_split_dragged() -> void:
	var host := _find_host()
	if host:
		host.queue_save_layout()


## Walk ancestors to the DockHost that owns both side docks.
func _find_host() -> DockHost:
	var node: Node = self
	while node:
		if node is DockHost:
			return node
		node = node.get_parent()
	return null


## Remember the drop target under the pointer so the overlay can highlight it.
func _set_hover(target: Dictionary) -> void:
	if _hover == target:
		return
	_hover = target
	_overlay.queue_redraw()


## Clear drop-target highlighting.
func _clear_hover() -> void:
	_set_hover({})


## Tint the whole dock as available and outline the hovered drop region.
func _draw_overlay() -> void:
	if not _panel_drag_active:
		return
	_overlay.draw_rect(Rect2(Vector2.ZERO, size), _AVAILABLE)
	_draw_slot_lines()
	if _hover.is_empty():
		return
	var rect := _hover_rect()
	_overlay.draw_rect(rect, _HOVER)
	_overlay.draw_rect(rect.grow(-1.0), _HOVER_EDGE, false, 2.0)
	var marker := _tab_marker_rect()
	if marker.size.x > 0.0:
		_overlay.draw_rect(marker, _HOVER_EDGE)


## Faint lines where a panel can be stacked: dock top, between items, dock bottom.
func _draw_slot_lines() -> void:
	var items := get_items()
	if items.is_empty():
		return
	var ys: Array[float] = [1.0]
	for i in range(1, items.size()):
		var above := _local_rect(items[i - 1])
		ys.append((above.end.y + _local_rect(items[i]).position.y) * 0.5)
	ys.append(size.y - 1.0)
	for y in ys:
		_overlay.draw_line(Vector2(4.0, y), Vector2(size.x - 4.0, y), _SLOT_LINE, 2.0)


## Region the dragged panel would occupy for the hovered target.
func _hover_rect() -> Rect2:
	var zone: int = _hover.get("zone", Zone.NONE)
	var item: Control = _hover.get("item")
	if zone == Zone.APPEND or item == null:
		return Rect2(Vector2.ZERO, size)
	var rect := _local_rect(item)
	var half := rect.size.y * 0.5
	match zone:
		Zone.BEFORE:
			return Rect2(rect.position, Vector2(rect.size.x, half))
		Zone.AFTER:
			return Rect2(rect.position + Vector2(0, half), Vector2(rect.size.x, half))
	return rect


## Insertion caret between tabs when hovering a tab strip; zero-size otherwise.
func _tab_marker_rect() -> Rect2:
	var tabs := _hover.get("item") as DockTabs
	var tab: int = _hover.get("tab", -1)
	if tabs == null or tab < 0:
		return Rect2()
	var bar := tabs.get_tab_bar()
	var x := 0.0
	if tab < tabs.get_tab_count():
		x = bar.get_tab_rect(tab).position.x
	elif tabs.get_tab_count() > 0:
		x = bar.get_tab_rect(tabs.get_tab_count() - 1).end.x
	var strip := tabs.get_tab_strip_global_rect()
	return Rect2(bar.global_position.x + x - 1.0 - global_position.x, strip.position.y - global_position.y, 3.0, strip.size.y)


## Overlay that hit-tests drop targets without affecting dock layout size.
class _DropOverlay extends Control:
	var dock: SideDock

	## Accept dock-panel drags and update the hovered drop target.
	func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
		if not data is DockDrag or dock == null:
			return false
		var target := dock.drop_target_at(at_position)
		if dock.is_noop_drop((data as DockDrag).panel, target):
			dock._clear_hover()
			return false
		dock._set_hover(target)
		return true

	## Place the dragged panel at the drop target under the pointer.
	func _drop_data(at_position: Vector2, data: Variant) -> void:
		if not data is DockDrag or dock == null:
			return
		var drag := data as DockDrag
		if drag.panel == null:
			return
		var host := dock._find_host()
		if host:
			host.drop_panel(drag.panel, dock, dock.drop_target_at(at_position))
		dock._clear_hover()

	## Clear the highlight when the pointer leaves this dock mid-drag.
	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT and dock:
			dock._clear_hover()

	## Delegate drawing so highlight rects stay in SideDock.
	func _draw() -> void:
		if dock:
			dock._draw_overlay()
