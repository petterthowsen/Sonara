# Tab group inside a side dock: DockPanels share one slot, tabs act as their drag handles.
class_name DockTabs extends TabContainer


## Fill the dock slot and route tab drags through DockDrag instead of built-in rearranging.
func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	custom_minimum_size = Vector2(0, 80)
	drag_to_rearrange_enabled = false
	# Replaces TabContainer's own forwarding so one payload type drives every dock drop target.
	get_tab_bar().set_drag_forwarding(_get_tab_drag_data, Callable(), Callable())
	tab_changed.connect(_on_tab_changed)


## DockPanels in tab order.
func get_panels() -> Array[DockPanel]:
	var panels: Array[DockPanel] = []
	for child in get_children():
		if child is DockPanel:
			panels.append(child)
	return panels


## Add `panel` as a tab at `index` (-1 appends) and select it.
func add_panel(panel: DockPanel, index: int = -1) -> void:
	if panel.get_parent() == self:
		var target := index
		if target < 0 or target >= get_child_count():
			target = get_child_count() - 1
		move_child(panel, target)
	else:
		if panel.get_parent():
			panel.get_parent().remove_child(panel)
		panel.visible = true
		add_child(panel)
		if index >= 0 and index < get_child_count() - 1:
			move_child(panel, index)
	panel.set_title_visible(false)
	refresh_titles()
	current_tab = panel.get_index()


## Insert tab index under `global_pos` (tab count past the last tab), or -1 off the tab strip.
func tab_index_at_global(global_pos: Vector2) -> int:
	if not get_tab_strip_global_rect().has_point(global_pos):
		return -1
	var bar := get_tab_bar()
	var index := bar.get_tab_idx_at_point(global_pos - bar.global_position)
	return get_tab_count() if index < 0 else index


## Global rect of the tab strip.
func get_tab_strip_global_rect() -> Rect2:
	var bar_rect := get_tab_bar().get_global_rect()
	return Rect2(global_position.x, bar_rect.position.y, size.x, bar_rect.size.y)


## Tab labels come from panel titles, not node names.
func refresh_titles() -> void:
	for i in range(get_tab_count()):
		var panel := get_tab_control(i) as DockPanel
		if panel:
			set_tab_title(i, panel.get_title())


## Start a panel drag from its tab.
func _get_tab_drag_data(at_position: Vector2) -> Variant:
	var index := get_tab_bar().get_tab_idx_at_point(at_position)
	if index < 0:
		return null
	var panel := get_tab_control(index) as DockPanel
	return panel.create_drag() if panel else null


## Persist which tab is selected.
func _on_tab_changed(_tab: int) -> void:
	var node: Node = get_parent()
	while node and not node is DockHost:
		node = node.get_parent()
	if node:
		(node as DockHost).queue_save_layout()
