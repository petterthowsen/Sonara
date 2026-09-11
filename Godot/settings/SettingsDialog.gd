# SettingsDialog.gd
# Native, draggable settings window with a category tree on the left and setting editors on the right.
# Manages a single shared FileDialog for path settings.
class_name SettingsDialog extends Window


var tree: Tree
var content_container: VBoxContainer
var ok_button: Button
var cancel_button: Button
var apply_button: Button
var defaults_button: Button
var file_dialog: FileDialog

var _settings = null
var _setting_rows: Array[SettingRow] = []
var _setting_row_scene: PackedScene = preload("res://settings/SettingRow.tscn")
var _active_browse_row: SettingRow = null
var _snapshot: Dictionary = {}
var _dirty := false


func _ready() -> void:
	tree = $MarginContainer/VBoxContainer/HSplitContainer/LeftPanel/Tree
	content_container = $MarginContainer/VBoxContainer/HSplitContainer/RightPanel/ScrollContainer/Content
	ok_button = $MarginContainer/VBoxContainer/BottomBar/OkButton
	cancel_button = $MarginContainer/VBoxContainer/BottomBar/CancelButton
	apply_button = $MarginContainer/VBoxContainer/BottomBar/ApplyButton
	defaults_button = $MarginContainer/VBoxContainer/BottomBar/DefaultsButton
	file_dialog = $FileDialog

	_settings = get_node_or_null("/root/Settings")
	if not _settings:
		push_error("[SettingsDialog] Settings autoload not found!")
		return
	_hide_tree_root()
	_populate_tree()
	_connect_signals()
	_snapshot = _capture_snapshot()
	_enable_save_buttons(false)


func _hide_tree_root() -> void:
	if tree:
		tree.hide_root = true


func _populate_tree() -> void:
	if not tree or not _settings:
		return
	tree.clear()
	var root = tree.create_item()
	var first_item: TreeItem = null
	var categories = _settings.call("get_categories")
	for category in categories:
		var item = tree.create_item(root)
		item.set_text(0, category)
		if first_item == null:
			first_item = item
	if first_item:
		tree.set_selected(first_item, 0)
		_populate_rows(first_item.get_text(0))


func _connect_signals() -> void:
	close_requested.connect(_on_cancel_pressed)
	tree.item_selected.connect(_on_tree_item_selected)
	ok_button.pressed.connect(_on_ok_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)
	apply_button.pressed.connect(_on_apply_pressed)
	defaults_button.pressed.connect(_on_defaults_pressed)
	file_dialog.file_selected.connect(_on_file_selected)
	file_dialog.dir_selected.connect(_on_dir_selected)
	file_dialog.canceled.connect(_on_file_dialog_canceled)


func popup_centered_size(size: Vector2 = Vector2(800, 500)) -> void:
	popup_centered(size)


func _capture_snapshot() -> Dictionary:
	var snap: Dictionary = {}
	for key in _settings.call("get_all_keys"):
		snap[key] = _settings.call("get_value", key)
	return snap


func _restore_snapshot() -> void:
	for key in _snapshot.keys():
		var old_val = _snapshot[key]
		Sonara.set_config(key, old_val)
		_settings.call("emit_signal", "setting_changed", key, old_val)
	_refresh_rows()


func _populate_rows(category: String) -> void:
	for row in _setting_rows:
		content_container.remove_child(row)
		row.queue_free()
	_setting_rows.clear()

	var settings = _settings.call("get_settings_for_category", category)
	for s in settings:
		var row = _setting_row_scene.instantiate()
		row.value_changed.connect(_on_row_value_changed)
		row.request_browse.connect(_on_row_request_browse.bind(row))
		content_container.add_child(row)
		row.bind(s)
		_setting_rows.append(row)


func _refresh_rows() -> void:
	var selected = tree.get_selected()
	if selected == null or selected.get_text(0) == "":
		return
	var category = selected.get_text(0)
	_populate_rows(category)


func _enable_save_buttons(enabled: bool) -> void:
	apply_button.disabled = not enabled
	ok_button.disabled = not enabled


func _on_tree_item_selected() -> void:
	var item = tree.get_selected()
	if item == null:
		return
	var category = item.get_text(0)
	_populate_rows(category)


func _on_row_value_changed(key: String, _value) -> void:
	_dirty = true
	_enable_save_buttons(true)


func _on_row_request_browse(path: String, is_directory: bool, row: SettingRow) -> void:
	_active_browse_row = row
	file_dialog.current_path = path if not path.is_empty() else ""
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.show()


func _on_file_selected(path: String) -> void:
	if _active_browse_row:
		_active_browse_row.set_pending_path(path)
	_active_browse_row = null


func _on_dir_selected(path: String) -> void:
	_on_file_selected(path)


func _on_file_dialog_canceled() -> void:
	_active_browse_row = null


func _on_ok_pressed() -> void:
	_settings.call("save")
	_dirty = false
	_enable_save_buttons(false)
	hide()


func _on_cancel_pressed() -> void:
	_restore_snapshot()
	_dirty = false
	_enable_save_buttons(false)
	hide()


func _on_apply_pressed() -> void:
	_settings.call("save")
	_dirty = false
	_enable_save_buttons(false)


func _on_defaults_pressed() -> void:
	_settings.call("reset_to_defaults")
	_dirty = true
	_enable_save_buttons(true)
	_refresh_rows()
