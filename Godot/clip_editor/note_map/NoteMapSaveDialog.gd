# Stores a note map in the user's library under a name, category and author
# (REQ-009). Saving over an existing name asks first.
#
# This is the only thing that ever writes the library: editing a map assigned to a
# channel changes only the project's copy (REQ-026), and an Auto map reaches here
# through "Save as…" (REQ-027).
class_name NoteMapSaveDialog extends Window

## A map was written to the library under `saved_name`.
signal map_saved(saved_name: String)

var _name_edit: LineEdit
var _category_edit: LineEdit
var _author_edit: LineEdit
var _save_button: Button
var _status: Label
var _confirm: ConfirmationDialog

var _map: NoteMap = null
var _logger := Log.make("NoteMapSaveDialog")


func _ready() -> void:
	title = "Save Note Map"
	size = Vector2i(380, 220)
	min_size = Vector2i(300, 200)
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

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	vbox.add_child(grid)

	_name_edit = _add_field(grid, "Name")
	_name_edit.text_changed.connect(func(_t): _update_save_enabled())
	_category_edit = _add_field(grid, "Category")
	_author_edit = _add_field(grid, "Author")

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(1, 1, 1, 0.6)
	vbox.add_child(_status)

	vbox.add_child(Control.new())  # spacer
	vbox.get_child(-1).size_flags_vertical = Control.SIZE_EXPAND_FILL

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 4)
	vbox.add_child(buttons)

	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.pressed.connect(_on_save_pressed)
	buttons.add_child(_save_button)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(hide)
	buttons.add_child(cancel)

	_confirm = ConfirmationDialog.new()
	_confirm.exclusive = false
	_confirm.transient = false
	_confirm.confirmed.connect(func(): _write(true))
	add_child(_confirm)


func _add_field(grid: GridContainer, label_text: String) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(200, 0)
	grid.add_child(edit)
	return edit


## Show the dialog for `map`, pre-filling its current metadata.
func open_for(map: NoteMap) -> void:
	_map = map.duplicate_map() if map else NoteMap.new()
	_name_edit.text = _map.map_name
	_category_edit.text = _map.category
	_author_edit.text = _map.author
	_status.text = ""
	_update_save_enabled()
	popup_centered()
	_name_edit.grab_focus()
	_name_edit.select_all()


func _update_save_enabled() -> void:
	var name_value := _name_edit.text.strip_edges()
	_save_button.disabled = name_value.is_empty()
	if name_value.is_empty():
		_status.text = "A name is required."
	elif NoteMapLibrary.exists(name_value):
		_status.text = "'%s' already exists in the library." % name_value
	else:
		_status.text = ""


func _on_save_pressed() -> void:
	var name_value := _name_edit.text.strip_edges()
	if name_value.is_empty():
		return
	if NoteMapLibrary.exists(name_value):
		_confirm.dialog_text = "'%s' already exists in the library. Overwrite it?" % name_value
		_confirm.popup_centered()
		return
	_write(false)


func _write(overwrite: bool) -> void:
	if _map == null:
		return
	_map.map_name = _name_edit.text.strip_edges()
	_map.category = _category_edit.text.strip_edges()
	_map.author = _author_edit.text.strip_edges()
	if not NoteMapLibrary.save_map(_map, overwrite):
		_status.text = "Could not save '%s'." % _map.map_name
		_logger.warn("save refused for '%s'" % _map.map_name)
		return
	map_saved.emit(_map.map_name)
	hide()
