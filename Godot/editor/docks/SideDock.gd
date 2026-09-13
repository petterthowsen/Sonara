# Left or right side dock: stacks DockPanels in a vertical split with overlay drop targets.
class_name SideDock extends Control

## Minimum width while this dock holds at least one panel.
@export var occupied_min_width: float = 200.0

## Width reserved for an empty dock so its drop target never collapses away.
@export var empty_min_width: float = 32.0

const _AVAILABLE := Color(0.45, 0.62, 0.95, 0.22)
const _HOVER := Color(0.55, 0.75, 1.0, 0.38)

var _split: VSplitContainer
var _overlay: _DropOverlay
var _hover_index: int = -1


## Build chrome, wrap any scene children as dock panels, then size the empty state.
func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	_build()
	_adopt_existing_children()
	_sync_empty_state()


## DockPanels currently stacked in this dock, top to bottom.
func get_panels() -> Array[DockPanel]:
	var panels: Array[DockPanel] = []
	if _split == null:
		return panels
	for child in _split.get_children():
		if child is DockPanel:
			panels.append(child)
	return panels


## Remove panels from the split without freeing them.
func take_panels() -> Array[DockPanel]:
	var panels := get_panels()
	for panel in panels:
		_split.remove_child(panel)
	_sync_empty_state()
	return panels


## Wrap a raw editor control (or keep an existing DockPanel) and insert it.
func add_content(content: Control, index: int = -1) -> DockPanel:
	var panel := content as DockPanel
	if panel == null:
		panel = _wrap(content)
	insert_panel(panel, index)
	return panel


## Detach `panel` from this dock without freeing it.
func remove_panel(panel: DockPanel) -> void:
	if _split and panel.get_parent() == _split:
		_split.remove_child(panel)
		_sync_empty_state()


## Place `panel` at `index` (-1 appends). No-op if it is already there.
func insert_panel(panel: DockPanel, index: int = -1) -> void:
	if panel.get_parent() == _split:
		var current := panel.get_index()
		var target := index
		if target < 0 or target > _split.get_child_count():
			target = _split.get_child_count()
		if current < target:
			target -= 1
		if current == target:
			return
		_split.move_child(panel, target)
		_sync_empty_state()
		return
	if panel.get_parent():
		panel.get_parent().remove_child(panel)
	var count := _split.get_child_count()
	if index < 0 or index > count:
		index = count
	_split.add_child(panel)
	_split.move_child(panel, index)
	_sync_empty_state()


## Current VSplit offsets, empty when this dock has fewer than two panels.
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


## Insert index for a position in dock-local coordinates.
func insert_index_at(local_pos: Vector2) -> int:
	var panels := get_panels()
	if panels.is_empty():
		return 0
	for i in range(panels.size()):
		var rect := _panel_local_rect(panels[i])
		if local_pos.y < rect.position.y + rect.size.y * 0.5:
			return i
	return panels.size()


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


## Enable the splitter only with two-plus panels; keep empty docks at drop-target width.
func _sync_empty_state() -> void:
	var count := 0 if _split == null else _split.get_child_count()
	_split.dragging_enabled = count >= 2
	custom_minimum_size.x = empty_min_width if count == 0 else occupied_min_width
	queue_redraw()
	if _overlay:
		_overlay.queue_redraw()


## Panel rect in this dock's local coordinates.
func _panel_local_rect(panel: DockPanel) -> Rect2:
	var global_rect := panel.get_global_rect()
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


## Remember which insert slot the pointer is over so the overlay can highlight it.
func _set_hover_index(index: int) -> void:
	if _hover_index == index:
		return
	_hover_index = index
	_overlay.queue_redraw()


## Clear insert-slot hover highlighting.
func _clear_hover() -> void:
	_set_hover_index(-1)


## Draw insert regions on the overlay; size is fixed, only color changes.
func _draw_overlay() -> void:
	if not get_viewport().gui_is_dragging():
		return
	if not get_viewport().gui_get_drag_data() is DockDrag:
		return
	var panels := get_panels()
	if panels.is_empty():
		var color := _HOVER if _hover_index == 0 else _AVAILABLE
		_overlay.draw_rect(Rect2(Vector2.ZERO, size), color)
		return
	var count := panels.size()
	for i in range(count + 1):
		var rect := _highlight_rect(i, panels)
		var color := _HOVER if _hover_index == i else _AVAILABLE
		_overlay.draw_rect(rect, color)


## Highlight band for insert index `index` given the current stacked panels.
func _highlight_rect(index: int, panels: Array[DockPanel]) -> Rect2:
	var width := size.x
	if index <= 0:
		var first := _panel_local_rect(panels[0])
		return Rect2(0, 0, width, maxf(first.position.y + first.size.y * 0.5, 8.0))
	if index >= panels.size():
		var last := _panel_local_rect(panels[panels.size() - 1])
		var last_mid := last.position.y + last.size.y * 0.5
		return Rect2(0, last_mid, width, size.y - last_mid)
	var prev := _panel_local_rect(panels[index - 1])
	var next_panel := _panel_local_rect(panels[index])
	var band_top := prev.position.y + prev.size.y * 0.5
	var band_bottom := next_panel.position.y + next_panel.size.y * 0.5
	return Rect2(0, band_top, width, band_bottom - band_top)


## Overlay that hit-tests insert slots without affecting dock layout size.
class _DropOverlay extends Control:
	var dock: SideDock

	## Enable hit-testing only while a dock panel is being dragged.
	func _notification(what: int) -> void:
		if what == NOTIFICATION_DRAG_BEGIN:
			var data: Variant = get_viewport().gui_get_drag_data()
			var is_dock := data is DockDrag
			visible = is_dock
			mouse_filter = MOUSE_FILTER_STOP if is_dock else MOUSE_FILTER_IGNORE
			queue_redraw()
		elif what == NOTIFICATION_DRAG_END:
			visible = false
			mouse_filter = MOUSE_FILTER_IGNORE
			if dock:
				dock._clear_hover()
			queue_redraw()

	## Accept dock-panel drags and update the hovered insert slot.
	func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
		if not data is DockDrag or dock == null:
			return false
		dock._set_hover_index(dock.insert_index_at(at_position))
		return true

	## Place the dragged panel into the insert slot under the pointer.
	func _drop_data(at_position: Vector2, data: Variant) -> void:
		if not data is DockDrag or dock == null:
			return
		var drag := data as DockDrag
		if drag.panel == null:
			return
		var host := dock._find_host()
		if host:
			host.place_panel(drag.panel, dock, dock.insert_index_at(at_position))
		dock._clear_hover()

	## Delegate drawing so highlight rects stay in SideDock.
	func _draw() -> void:
		if dock:
			dock._draw_overlay()
