# SettingRow.gd
# Reusable editor row for a single setting.
# Dynamically creates the appropriate editor widget based on Setting.type.
# Emits value_changed when the user edits the value.
# Emits request_browse when a path editor needs a FileDialog.
class_name SettingRow extends HBoxContainer


enum Type { BOOL, INT, FLOAT, STRING, CHOICE, CHOICE_MULTI, PATH, PATH_ARRAY, SECRET, TEXT }

signal value_changed(key: String, value)
## Emitted when a Path / PATH_ARRAY browse button is pressed.
signal request_browse(path: String, is_directory: bool)

var setting


@onready var name_label: Label = $NameLabel
@onready var editor_container: HBoxContainer = $EditorContainer

var _settings = null
var _editor_widget: Control = null
var _ignore_signals := false
var _path_array_rows: Array = []
var _pending_browse_line_edit: LineEdit = null


func _ready() -> void:
	_settings = get_node_or_null("/root/Settings")


func bind(p_setting) -> void:
	"""Bind this row to a Setting definition and build the editor."""
	setting = p_setting
	_refresh_ui()


## Stop emitting so teardown (focus_exited, etc.) cannot write stale values.
func detach() -> void:
	_ignore_signals = true
	clear_pending_browse()


## Drop a canceled FileDialog target without changing the row's current text.
func clear_pending_browse() -> void:
	_pending_browse_line_edit = null


func set_value_no_signal(value) -> void:
	"""Set the editor's value without emitting value_changed."""
	if not _editor_widget:
		return
	_ignore_signals = true
	_apply_value_to_widget(value)
	_ignore_signals = false


func get_current_value():
	match setting.type:
		Type.BOOL:
			return (_editor_widget as CheckBox).button_pressed
		Type.INT:
			return int((_editor_widget as SpinBox).value)
		Type.FLOAT:
			return float((_editor_widget as SpinBox).value)
		Type.STRING, Type.SECRET:
			return (_editor_widget as LineEdit).text
		Type.TEXT:
			return (_editor_widget as TextEdit).text
		Type.CHOICE:
			var ob = _editor_widget as OptionButton
			return ob.get_item_text(ob.selected)
		Type.CHOICE_MULTI:
			return _read_choice_multi()
		Type.PATH:
			return (_editor_widget as LineEdit).text
		Type.PATH_ARRAY:
			return _read_path_array()
	return null


func _refresh_ui() -> void:
	assert(setting != null, "SettingRow: setting is null")

	name_label.text = setting.label
	name_label.tooltip_text = setting.description

	for child in editor_container.get_children():
		editor_container.remove_child(child)
		child.queue_free()
	_editor_widget = null

	var start_value = setting.default
	if _settings:
		start_value = _settings.call("get_value", setting.key)
	elif Sonara:
		start_value = Sonara.get_config(setting.key, setting.default)

	match setting.type:
		Type.BOOL:
			var cb = CheckBox.new()
			cb.toggled.connect(_on_edited)
			editor_container.add_child(cb)
			_editor_widget = cb
			cb.button_pressed = bool(start_value)

		Type.INT, Type.FLOAT:
			var sb = SpinBox.new()
			sb.min_value = setting.min_val
			sb.max_value = setting.max_val
			if setting.step > 0:
				sb.step = setting.step
			if setting.type == Type.INT:
				sb.rounded = true
			sb.value_changed.connect(_on_edited)
			editor_container.add_child(sb)
			_editor_widget = sb
			sb.set_value_no_signal(float(start_value))

		Type.STRING, Type.SECRET:
			var le = LineEdit.new()
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.secret = setting.type == Type.SECRET
			if setting.type == Type.SECRET:
				le.placeholder_text = "sk-or-..."
			le.text_changed.connect(_on_edited)
			editor_container.add_child(le)
			_editor_widget = le
			le.text = str(start_value)

		Type.TEXT:
			var te = TextEdit.new()
			te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			te.custom_minimum_size = Vector2(0, 140)
			te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			te.text = str(start_value)
			te.text_changed.connect(_on_edited)
			editor_container.add_child(te)
			_editor_widget = te

		Type.CHOICE:
			var ob = OptionButton.new()
			for i in range(setting.options.size()):
				ob.add_item(str(setting.options[i]), i)
			ob.item_selected.connect(_on_edited)
			editor_container.add_child(ob)
			_editor_widget = ob
			_apply_choice_value(start_value)

		Type.CHOICE_MULTI:
			var vbox = VBoxContainer.new()
			for i in range(setting.options.size()):
				var cb = CheckBox.new()
				cb.text = str(setting.options[i])
				cb.toggled.connect(_on_choice_multi_toggled.bind(i))
				vbox.add_child(cb)
			editor_container.add_child(vbox)
			_editor_widget = vbox
			_apply_choice_multi_value(start_value)

		Type.PATH:
			var hbox = HBoxContainer.new()
			hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var le = LineEdit.new()
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_changed.connect(_on_edited)
			hbox.add_child(le)

			var btn = Button.new()
			btn.text = "Browse"
			btn.pressed.connect(_on_path_browse)
			hbox.add_child(btn)

			editor_container.add_child(hbox)
			_editor_widget = le
			le.text = str(start_value)

		Type.PATH_ARRAY:
			var vbox = VBoxContainer.new()
			vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_path_array_rows = []
			var arr = start_value if start_value is Array else []
			for p in arr:
				_add_path_row(str(p), vbox)
			var add_btn = Button.new()
			add_btn.text = "Add Path"
			add_btn.pressed.connect(_on_path_array_add.bind(vbox))
			vbox.add_child(add_btn)
			editor_container.add_child(vbox)
			_editor_widget = vbox


## Create one editable path row and keep it above the Add Path button.
func _add_path_row(initial_text: String, parent_vbox: VBoxContainer) -> void:
	var hbox = HBoxContainer.new()

	var le = LineEdit.new()
	le.text = initial_text
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text_submitted.connect(_on_path_array_text_committed)
	le.focus_exited.connect(_on_path_array_text_committed)
	hbox.add_child(le)

	var browse_btn = Button.new()
	browse_btn.text = "Browse"
	browse_btn.pressed.connect(_on_path_array_browse.bind(le))
	hbox.add_child(browse_btn)

	var remove_btn = Button.new()
	remove_btn.text = "-"
	remove_btn.custom_minimum_size = Vector2(24, 0)
	remove_btn.pressed.connect(_on_path_array_remove.bind(hbox, parent_vbox))
	hbox.add_child(remove_btn)

	parent_vbox.add_child(hbox, true)
	parent_vbox.move_child(hbox, parent_vbox.get_child_count() - 2)
	_path_array_rows.append(hbox)


func _apply_value_to_widget(value) -> void:
	match setting.type:
		Type.BOOL:
			(_editor_widget as CheckBox).button_pressed = bool(value)
		Type.INT:
			(_editor_widget as SpinBox).value = int(value)
		Type.FLOAT:
			(_editor_widget as SpinBox).value = float(value)
		Type.STRING, Type.SECRET:
			(_editor_widget as LineEdit).text = str(value)
		Type.TEXT:
			(_editor_widget as TextEdit).text = str(value)
		Type.PATH:
			(_editor_widget as LineEdit).text = str(value)
		Type.PATH_ARRAY:
			_apply_path_array_value(value)
		Type.CHOICE:
			_apply_choice_value(value)
		Type.CHOICE_MULTI:
			_apply_choice_multi_value(value)


func _read_choice_multi() -> Array:
	var result: Array = []
	if not _editor_widget is VBoxContainer:
		return result
	var vbox = _editor_widget as VBoxContainer
	for i in range(vbox.get_child_count()):
		var cb = vbox.get_child(i) as CheckBox
		if cb and cb.button_pressed:
			result.append(setting.options[i])
	return result


func _apply_choice_multi_value(value) -> void:
	if not _editor_widget is VBoxContainer:
		return
	var vbox = _editor_widget as VBoxContainer
	for i in range(vbox.get_child_count()):
		var cb = vbox.get_child(i) as CheckBox
		if cb and i < setting.options.size():
			cb.button_pressed = (value as Array).has(setting.options[i])


func _apply_choice_value(value) -> void:
	if not _editor_widget is OptionButton:
		return
	var ob = _editor_widget as OptionButton
	for i in range(setting.options.size()):
		if str(setting.options[i]) == str(value):
			ob.selected = i
			return


func _read_path_array() -> Array:
	var result: Array = []
	if not _editor_widget is VBoxContainer:
		return result
	for row in _path_array_rows:
		var le = row.get_child(0) as LineEdit
		if le:
			var t = le.text.strip_edges()
			if not t.is_empty():
				result.append(t)
	return result


func _apply_path_array_value(value) -> void:
	if not _editor_widget is VBoxContainer:
		return
	_ignore_signals = true
	var vbox = _editor_widget as VBoxContainer
	for row in _path_array_rows:
		vbox.remove_child(row)
		row.queue_free()
	_path_array_rows.clear()

	var arr = value if value is Array else []
	for p in arr:
		_add_path_row(str(p), vbox)
	_ignore_signals = false


## Write the current editor value through Settings so listeners see the change.
func _write_value(value) -> void:
	if _settings:
		_settings.call("set_value", setting.key, value)
	else:
		Sonara.set_config(setting.key, value)
	value_changed.emit(setting.key, value)


func _on_edited(_value = null) -> void:
	if _ignore_signals:
		return
	_write_value(get_current_value())


func _on_choice_multi_toggled(_toggled: bool, _index: int) -> void:
	if _ignore_signals:
		return
	_write_value(_read_choice_multi())


func _on_path_browse() -> void:
	var current = setting.default
	if _settings:
		current = _settings.call("get_value", setting.key)
	elif Sonara:
		current = Sonara.get_config(setting.key, setting.default)
	request_browse.emit(str(current), false)


## Open a directory picker for the given path-array row.
func _on_path_array_browse(line_edit: LineEdit) -> void:
	_pending_browse_line_edit = line_edit
	request_browse.emit(line_edit.text, true)


func _on_path_array_add(parent_vbox: VBoxContainer) -> void:
	_add_path_row("", parent_vbox)
	_emit_path_array_changed()


func _on_path_array_remove(row: Control, parent_vbox: VBoxContainer) -> void:
	parent_vbox.remove_child(row)
	_path_array_rows.erase(row)
	row.queue_free()
	_emit_path_array_changed()


## Commit typed path-array text when the field is submitted or loses focus.
func _on_path_array_text_committed(_unused = null) -> void:
	if _ignore_signals:
		return
	_emit_path_array_changed()


func _emit_path_array_changed() -> void:
	_write_value(_read_path_array())


## Apply a FileDialog result to the active Path or PATH_ARRAY editor.
func set_pending_path(path: String) -> void:
	if setting.type == Type.PATH:
		(_editor_widget as LineEdit).text = path
		_write_value(path)
	elif setting.type == Type.PATH_ARRAY:
		if _pending_browse_line_edit:
			_pending_browse_line_edit.text = path
		_pending_browse_line_edit = null
		_emit_path_array_changed()
