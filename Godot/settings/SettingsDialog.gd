# SettingsDialog.gd
# Native, draggable settings window with a category tree on the left and setting editors on the right.
# Manages a single shared FileDialog for path settings.
class_name SettingsDialog extends Window


var tree: Tree
var content_container: VBoxContainer
var search_edit: LineEdit
var search_debounce: Timer
var ok_button: Button
var cancel_button: Button
var apply_button: Button
var defaults_button: Button
var file_dialog: FileDialog

var _settings = null
var _setting_rows: Array[SettingRow] = []
var _sub_headers: Array[Control] = []
var _setting_row_scene: PackedScene = preload("res://settings/SettingRow.tscn")
var _active_browse_row: SettingRow = null
var _snapshot: Dictionary = {}
var _dirty := false
var _active_search_query := ""
var _category_before_search := ""


func _ready() -> void:
	tree = $MarginContainer/VBoxContainer/HSplitContainer/LeftPanel/Tree
	content_container = $MarginContainer/VBoxContainer/HSplitContainer/RightPanel/ScrollContainer/ContentMargin/Content
	search_edit = $MarginContainer/VBoxContainer/SearchEdit
	search_debounce = $MarginContainer/VBoxContainer/SearchDebounce
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
	search_edit.text_changed.connect(_on_search_text_changed)
	search_edit.text_submitted.connect(_on_search_submitted)
	search_edit.gui_input.connect(_on_search_gui_input)
	search_debounce.timeout.connect(_apply_search)


func popup_centered_size(popup_size: Vector2 = Vector2(900, 600)) -> void:
	_begin_session()
	popup_centered(popup_size)
	search_edit.grab_focus()


## Snapshot current config and rebuild rows so each open starts from disk/memory state.
func _begin_session() -> void:
	_snapshot = _capture_snapshot()
	_dirty = false
	_enable_save_buttons(false)
	search_debounce.stop()
	search_edit.text = ""
	_active_search_query = ""
	_refresh_rows()


## Copy setting values so Cancel can restore without sharing live array references.
func _capture_snapshot() -> Dictionary:
	var snap: Dictionary = {}
	for key in _settings.call("get_all_keys"):
		var val = _settings.call("get_value", key)
		if val is Array:
			snap[key] = (val as Array).duplicate()
		elif val is Dictionary:
			snap[key] = (val as Dictionary).duplicate(true)
		else:
			snap[key] = val
	return snap


func _restore_snapshot() -> void:
	for key in _snapshot.keys():
		var old_val = _snapshot[key]
		if old_val is Array:
			old_val = (old_val as Array).duplicate()
		elif old_val is Dictionary:
			old_val = (old_val as Dictionary).duplicate(true)
		_settings.set_value(key, old_val)
	_refresh_rows()


func _populate_rows(category: String) -> void:
	_clear_content()

	var sub_categories = _settings.call("get_sub_categories", category)
	var all_settings = _settings.call("get_settings_for_category", category)
	var first := true
	for sub in sub_categories:
		var group_settings: Array = []
		for s in all_settings:
			if s.sub_category == sub:
				group_settings.append(s)
		if group_settings.is_empty():
			continue
		if sub != "":
			_add_sub_header(sub, first)
			first = false
		for s in group_settings:
			_add_row(s)


## Build the search results view: one header per "Category" / "Category › Sub-category"
## group, in the order each group first appears in the ranked results.
func _build_search_rows(results: Array) -> void:
	_clear_content()
	if results.is_empty():
		_show_no_results_label(_active_search_query)
		return
	var groups: Array = []
	var index_by_title: Dictionary = {}
	for s in results:
		var group_title = s.category if s.sub_category.is_empty() else "%s › %s" % [s.category, s.sub_category]
		if not index_by_title.has(group_title):
			index_by_title[group_title] = groups.size()
			groups.append({"title": group_title, "settings": []})
		groups[index_by_title[group_title]].settings.append(s)
	var first := true
	for group in groups:
		_add_sub_header(group.title, first)
		first = false
		for s in group.settings:
			_add_row(s)


func _show_no_results_label(query: String) -> void:
	var label = Label.new()
	label.text = "No settings match \"%s\"" % query
	label.modulate = Color(1, 1, 1, 0.6)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content_container.add_child(label)
	_sub_headers.append(label)


func _clear_content() -> void:
	for row in _setting_rows:
		row.detach()
		content_container.remove_child(row)
		row.queue_free()
	_setting_rows.clear()
	for header in _sub_headers:
		content_container.remove_child(header)
		header.queue_free()
	_sub_headers.clear()


func _add_sub_header(header_title: String, is_first: bool) -> void:
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 0 if is_first else 18)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	var label = Label.new()
	label.text = header_title
	label.theme_type_variation = &"HeaderSmall"
	vbox.add_child(label)
	vbox.add_child(HSeparator.new())
	margin.add_child(vbox)
	content_container.add_child(margin)
	_sub_headers.append(margin)


func _add_row(s) -> void:
	var row = _setting_row_scene.instantiate()
	row.value_changed.connect(_on_row_value_changed)
	row.request_browse.connect(_on_row_request_browse.bind(row))
	content_container.add_child(row)
	row.bind(s)
	_setting_rows.append(row)


func _refresh_rows() -> void:
	if not _active_search_query.is_empty():
		_apply_search()
		return
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
	_flush_visible_rows()
	if not search_edit.text.is_empty():
		search_debounce.stop()
		search_edit.text = ""
		_active_search_query = ""
	_populate_rows(item.get_text(0))


func _on_search_text_changed(_new_text: String) -> void:
	search_debounce.start()


func _on_search_submitted(_text: String) -> void:
	if not _setting_rows.is_empty():
		_setting_rows[0].grab_editor_focus()


func _on_search_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.is_echo() and event.keycode == KEY_ESCAPE:
		if not search_edit.text.is_empty():
			search_debounce.stop()
			search_edit.text = ""
			_apply_search()
			search_edit.accept_event()


## Rebuild the content area from the current search box text, or the selected category
## if the search box is empty. Re-run by _refresh_rows whenever settings change underneath
## an active search (e.g. Restore Defaults), so the search view doesn't silently go stale.
func _apply_search() -> void:
	_flush_visible_rows()
	var q := search_edit.text.strip_edges()
	if q.is_empty():
		_active_search_query = ""
		_restore_category_selection()
		return
	if _active_search_query.is_empty():
		var selected = tree.get_selected()
		if selected:
			_category_before_search = selected.get_text(0)
	_active_search_query = q
	tree.deselect_all()
	var results = _settings.call("search", q)
	_build_search_rows(results)


## Re-select the category that was active before search started (deselect_all() while
## searching drops the tree's selection, so it has to be restored explicitly on clear).
func _restore_category_selection() -> void:
	var category := _category_before_search
	if category.is_empty():
		var categories = _settings.call("get_categories")
		category = categories[0] if not categories.is_empty() else ""
	var root_item = tree.get_root()
	if root_item:
		var item = root_item.get_first_child()
		while item:
			if item.get_text(0) == category:
				tree.set_selected(item, 0)
				break
			item = item.get_next()
	if not category.is_empty():
		_populate_rows(category)


func _on_row_value_changed(key: String, _value) -> void:
	_dirty = true
	_enable_save_buttons(true)


func _on_row_request_browse(path: String, is_directory: bool, row: SettingRow) -> void:
	_active_browse_row = row
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	if is_directory:
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		if not path.is_empty():
			file_dialog.current_dir = path
	else:
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		file_dialog.current_path = path if not path.is_empty() else ""
	file_dialog.show()


func _on_file_selected(path: String) -> void:
	if _active_browse_row:
		_active_browse_row.set_pending_path(path)
	_active_browse_row = null


func _on_dir_selected(path: String) -> void:
	_on_file_selected(path)


func _on_file_dialog_canceled() -> void:
	if _active_browse_row:
		_active_browse_row.clear_pending_browse()
	_active_browse_row = null


## Commit every visible editor into Settings before save or category switch.
func _flush_visible_rows() -> void:
	if not _settings:
		return
	for row in _setting_rows:
		if row == null or row.setting == null:
			continue
		_settings.call("set_value", row.setting.key, row.get_current_value())


func _on_ok_pressed() -> void:
	_flush_visible_rows()
	_settings.call("save")
	_snapshot = _capture_snapshot()
	_dirty = false
	_enable_save_buttons(false)
	hide()


func _on_cancel_pressed() -> void:
	if _dirty:
		_restore_snapshot()
	_dirty = false
	_enable_save_buttons(false)
	hide()


func _on_apply_pressed() -> void:
	_flush_visible_rows()
	_settings.call("save")
	_snapshot = _capture_snapshot()
	_dirty = false
	_enable_save_buttons(false)


func _on_defaults_pressed() -> void:
	_settings.call("reset_to_defaults")
	_dirty = true
	_enable_save_buttons(true)
	_refresh_rows()
