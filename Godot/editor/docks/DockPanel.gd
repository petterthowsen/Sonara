# Title-bar chrome around a dockable editor panel (Inspector, Browser, AI Chat).
class_name DockPanel extends VBoxContainer

const TITLE_HEIGHT := 22.0

## Stable id used in layout config (`inspector`, `browser`, `assistant`).
var panel_id: String = ""

var _title_bar: PanelContainer
var _title_label: Label
var _content: Control


## Wrap `content` with a draggable title bar labeled `title`.
func setup(id: String, title: String, content: Control) -> void:
	panel_id = id
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	custom_minimum_size = Vector2(0, 80)
	add_theme_constant_override("separation", 0)
	_build_title(title)
	_set_content(content)


## Display title shown on the drag handle.
func get_title() -> String:
	return _title_label.text if _title_label else panel_id


## The wrapped editor control, or null before setup.
func get_content() -> Control:
	return _content


## Side dock that currently owns this panel, or null when hidden.
func get_parent_dock() -> SideDock:
	var node: Node = get_parent()
	while node:
		if node is SideDock:
			return node
		node = node.get_parent()
	return null


## Create the title-bar control that initiates panel drags.
func _build_title(title: String) -> void:
	_title_bar = PanelContainer.new()
	_title_bar.name = "TitleBar"
	_title_bar.custom_minimum_size = Vector2(0, TITLE_HEIGHT)
	_title_bar.theme_type_variation = "DarkPanel"
	_title_bar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_title_bar.set_drag_forwarding(_get_drag_data, Callable(), Callable())
	_title_label = Label.new()
	_title_label.text = title
	_title_label.clip_text = true
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_font_size_override("font_size", 12)
	_title_bar.add_child(_title_label)
	add_child(_title_bar)


## Reparent `content` below the title bar and make it fill remaining space.
func _set_content(content: Control) -> void:
	if content.get_parent():
		content.get_parent().remove_child(content)
	_content = content
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(content)
	content.set("layout_mode", 2)


## Begin a dock-panel drag from the title bar.
func _get_drag_data(_at_position: Vector2) -> Variant:
	var drag := DockDrag.new()
	drag.panel = self
	modulate.a = 0.45
	var preview := _make_preview()
	preview.tree_exiting.connect(_on_drag_preview_exiting)
	set_drag_preview(preview)
	return drag


## Floating title chip shown under the cursor while dragging.
func _make_preview() -> Control:
	var preview := PanelContainer.new()
	preview.theme_type_variation = "DarkPanel"
	preview.custom_minimum_size = Vector2(140, TITLE_HEIGHT)
	var label := Label.new()
	label.text = get_title()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview.add_child(label)
	return preview


## Restore full opacity when the drag preview leaves the tree (drop or cancel).
func _on_drag_preview_exiting() -> void:
	modulate.a = 1.0
