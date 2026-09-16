# Picks a named map out of the user's library and assigns a copy of it to a
# channel (REQ-010).
#
# Maps are grouped by category and show their author, so a library with several
# kits stays readable. Confirming emits `map_chosen` with a copy; the caller is
# what actually assigns it, so the assignment stays one undoable step.
class_name NoteMapBrowserDialog extends Window

## The user picked `map` (already a copy, safe to assign).
signal map_chosen(map: NoteMap)

var _tree: Tree
var _load_button: Button
var _empty_label: Label
var _maps: Array[NoteMap] = []


func _ready() -> void:
	title = "Load Note Map"
	size = Vector2i(420, 480)
	min_size = Vector2i(300, 280)
	exclusive = false
	transient = false
	close_requested.connect(hide)
	_build_ui()
	hide()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	_empty_label = Label.new()
	_empty_label.text = "The note map library is empty. Save a map to add one."
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.modulate = Color(1, 1, 1, 0.6)
	_empty_label.visible = false
	vbox.add_child(_empty_label)

	_tree = Tree.new()
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_title(0, "Map")
	_tree.set_column_title(1, "Author")
	_tree.column_titles_visible = true
	_tree.set_column_expand_ratio(0, 2)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_activated.connect(_on_confirm)
	vbox.add_child(_tree)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 4)
	vbox.add_child(buttons)

	_load_button = Button.new()
	_load_button.text = "Load"
	_load_button.disabled = true
	_load_button.pressed.connect(_on_confirm)
	buttons.add_child(_load_button)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(hide)
	buttons.add_child(cancel)


## Re-read the library and show the dialog.
func open() -> void:
	refresh()
	popup_centered()


func refresh() -> void:
	_maps = NoteMapLibrary.list()
	_tree.clear()
	var root := _tree.create_item()
	_load_button.disabled = true
	_empty_label.visible = _maps.is_empty()

	# One branch per category, in the order list() already sorted them.
	var category_items := {}
	for i in _maps.size():
		var map := _maps[i]
		var category := map.category if not map.category.strip_edges().is_empty() else "Uncategorized"
		if not category_items.has(category):
			var branch := _tree.create_item(root)
			branch.set_text(0, category)
			branch.set_selectable(0, false)
			branch.set_selectable(1, false)
			category_items[category] = branch
		var item := _tree.create_item(category_items[category])
		item.set_text(0, map.map_name)
		item.set_text(1, map.author)
		item.set_tooltip_text(0, "%d entries" % map.entries.size())
		# The index into _maps, so selection doesn't depend on names being unique.
		item.set_metadata(0, i)


func _on_item_selected() -> void:
	_load_button.disabled = _selected_map() == null


func _selected_map() -> NoteMap:
	var item := _tree.get_selected()
	if item == null:
		return null
	var index: Variant = item.get_metadata(0)
	if not (index is int) or index < 0 or index >= _maps.size():
		return null
	return _maps[index]


func _on_confirm() -> void:
	var map := _selected_map()
	if map == null:
		return
	# A copy, so later edits on the channel never reach the library (REQ-026).
	map_chosen.emit(map.duplicate_map())
	hide()
