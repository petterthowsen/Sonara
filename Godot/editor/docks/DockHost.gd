# Owns the left/right side docks, panel placement, and persisted layout.
class_name DockHost extends HSplitContainer

const CONFIG_KEY := "ui/docks"
const _DEFAULT_LEFT: Array[String] = ["inspector"]
const _DEFAULT_RIGHT: Array[String] = ["browser", "assistant"]

const _NODE_IDS := {
	"Inspector": "inspector",
	"BrowserPanel": "browser",
	"AssistantPanel": "assistant",
}

const _TITLES := {
	"inspector": "Inspector",
	"browser": "Browser",
	"assistant": "AI Chat",
}

@onready var left_dock: SideDock = $LeftCenterSplit/LeftDock
@onready var right_dock: SideDock = $RightDock
@onready var _center_split: HSplitContainer = $LeftCenterSplit

var _panels: Dictionary = {}
var _hidden: Node
var _save_queued: bool = false


## Map a scene node name to a stable dock panel id.
static func id_for_node(node: Node) -> String:
	if _NODE_IDS.has(node.name):
		return _NODE_IDS[node.name]
	return node.name.to_snake_case()


## Human-readable title for a panel id.
static func title_for_id(id: String) -> String:
	if _TITLES.has(id):
		return _TITLES[id]
	return id.capitalize()


## Index scene panels, restore layout from config, and persist splitter drags.
func _ready() -> void:
	_hidden = Node.new()
	_hidden.name = "HiddenDockPanels"
	# A plain Node is ignored by SplitContainer layout, and hidden panels stay in the tree.
	add_child(_hidden)
	_index_panels()
	_apply_saved_layout()
	drag_ended.connect(_on_outer_dragged)
	if _center_split:
		_center_split.drag_ended.connect(_on_inner_dragged)


## Move `panel` onto `target` at `insert_index` and persist the new layout.
func place_panel(panel: DockPanel, target: SideDock, insert_index: int) -> void:
	if panel == null or target == null:
		return
	target.insert_panel(panel, insert_index)
	_normalize_docks()
	_save_layout()


## Apply a drop target from `SideDock.drop_target_at` and persist the new layout.
func drop_panel(panel: DockPanel, dock: SideDock, drop_target: Dictionary) -> void:
	if panel == null or dock == null:
		return
	dock.apply_drop(panel, drop_target)
	_normalize_docks()
	_save_layout()


## Show or hide a registered panel without changing the other panels.
func set_panel_visible(id: String, is_shown: bool) -> void:
	var panel := _panels.get(id) as DockPanel
	if panel == null:
		return
	if is_shown:
		_show_panel(panel)
	else:
		_hide_panel(panel)
	_save_layout()


## Toggle a panel between its last dock slot and the hidden pool.
func toggle_panel_visible(id: String) -> void:
	var panel := _panels.get(id) as DockPanel
	if panel == null:
		return
	set_panel_visible(id, panel.get_parent_dock() == null)


## Registered panel ids in stable menu order (known panels first).
func get_panel_ids() -> Array[String]:
	var ids: Array[String] = []
	for id in _TITLES:
		if _panels.has(id):
			ids.append(id)
	for id in _panels:
		if not ids.has(id):
			ids.append(id)
	return ids


## True when the panel is currently stacked in a side dock.
func is_panel_visible(id: String) -> bool:
	var panel := _panels.get(id) as DockPanel
	return panel != null and panel.get_parent_dock() != null


## Persist split offsets after a user drags a splitter.
func queue_save_layout() -> void:
	if _save_queued:
		return
	_save_queued = true
	_flush_save.call_deferred()


## Rebuild the panel-id map from both docks and the hidden pool.
func _index_panels() -> void:
	_panels.clear()
	for panel in left_dock.get_panels():
		_panels[panel.panel_id] = panel
	for panel in right_dock.get_panels():
		_panels[panel.panel_id] = panel
	if _hidden:
		for child in _hidden.get_children():
			if child is DockPanel:
				_panels[child.panel_id] = child


## Reparent panels to match `ui/docks` config, or write the default layout.
func _apply_saved_layout() -> void:
	var saved: Variant = Sonara.get_config(CONFIG_KEY, {})
	if not saved is Dictionary or saved.is_empty():
		_save_layout()
		return
	var data: Dictionary = saved
	var by_id: Dictionary = {}
	for panel in left_dock.take_panels():
		by_id[panel.panel_id] = panel
	for panel in right_dock.take_panels():
		by_id[panel.panel_id] = panel
	for child in _hidden.get_children():
		if child is DockPanel:
			by_id[child.panel_id] = child
			_hidden.remove_child(child)
	_place_entries(data.get("left", _DEFAULT_LEFT), left_dock, by_id)
	_place_entries(data.get("right", _DEFAULT_RIGHT), right_dock, by_id)
	for id in by_id:
		var leftover: DockPanel = by_id[id]
		if leftover.get_parent() == null:
			_hide_panel(leftover)
	left_dock.apply_split_offsets(data.get("left_splits", []))
	right_dock.apply_split_offsets(data.get("right_splits", []))
	right_dock.set_parent_split_offsets(_to_packed(data.get("outer_offsets", [])))
	left_dock.set_parent_split_offsets(_to_packed(data.get("inner_offsets", [])))
	_index_panels()


## Stack each saved entry into `dock` in order: an id string, or `{tabs, current}` for a tab group.
## Unknown ids are skipped.
func _place_entries(entries: Variant, dock: SideDock, by_id: Dictionary) -> void:
	if not entries is Array:
		return
	for entry in entries:
		if entry is Dictionary:
			var group: Array[DockPanel] = []
			for id in entry.get("tabs", []):
				var tabbed: DockPanel = by_id.get(str(id))
				if tabbed and tabbed.get_parent() == null:
					group.append(tabbed)
			dock.append_tab_group(group, int(entry.get("current", 0)))
			continue
		var panel: DockPanel = by_id.get(str(entry))
		if panel and panel.get_parent() == null:
			dock.insert_panel(panel, -1)


## Reveal a hidden panel on the right dock (appended below existing panels).
func _show_panel(panel: DockPanel) -> void:
	if panel.get_parent_dock():
		panel.visible = true
		return
	if panel.get_parent():
		panel.get_parent().remove_child(panel)
	right_dock.insert_panel(panel, -1)


## Remove a panel from its dock and park it in the hidden pool.
func _hide_panel(panel: DockPanel) -> void:
	var dock := panel.get_parent_dock()
	if dock:
		dock.remove_panel(panel)
	elif panel.get_parent():
		panel.get_parent().remove_child(panel)
	_hidden.add_child(panel)
	panel.visible = false
	_normalize_docks()


## Dissolve tab groups left with one panel in either dock (e.g. after a cross-dock move).
func _normalize_docks() -> void:
	left_dock.normalize()
	right_dock.normalize()


## Write dock occupancy and split offsets to Sonara config.
func _save_layout() -> void:
	var data := {
		"left": left_dock.get_layout(),
		"right": right_dock.get_layout(),
		"left_splits": left_dock.get_split_offsets(),
		"right_splits": right_dock.get_split_offsets(),
		"outer_offsets": Array(right_dock.get_parent_split_offsets()),
		"inner_offsets": Array(left_dock.get_parent_split_offsets()),
	}
	Sonara.set_config(CONFIG_KEY, data)
	Sonara.save_config()


## Saved int array as split offsets; empty when missing or malformed.
func _to_packed(offsets: Variant) -> PackedInt32Array:
	var packed := PackedInt32Array()
	if offsets is Array:
		for value in offsets:
			packed.append(int(value))
	return packed


## Persist the left/right dock width after the outer splitter is released.
func _on_outer_dragged() -> void:
	queue_save_layout()


## Persist the left-dock vs center width after the inner splitter is released.
func _on_inner_dragged() -> void:
	queue_save_layout()


## Coalesce splitter-drag saves onto the next idle frame.
func _flush_save() -> void:
	_save_queued = false
	_save_layout()
