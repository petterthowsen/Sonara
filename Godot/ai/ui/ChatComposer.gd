# ChatComposer.gd
# Multiline input, file attach, send.
class_name ChatComposer extends VBoxContainer


signal send_requested(text: String, parts: Array)


var _edit: TextEdit
var _send: Button
var _attach_img: Button
var _attach_aud: Button
var _chips: HBoxContainer
var _dialog: FileDialog
var _parts: Array = []
var _busy: bool = false


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_chips = HBoxContainer.new()
	_chips.add_theme_constant_override("separation", 6)
	add_child(_chips)
	_edit = TextEdit.new()
	_edit.custom_minimum_size = Vector2(0, 72)
	_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_edit.placeholder_text = "Ask Sonara…"
	_edit.gui_input.connect(_on_edit_input)
	add_child(_edit)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_attach_img = Button.new()
	_attach_img.text = "Image"
	_attach_img.pressed.connect(_pick_image)
	row.add_child(_attach_img)
	_attach_aud = Button.new()
	_attach_aud.text = "Audio"
	_attach_aud.pressed.connect(_pick_audio)
	row.add_child(_attach_aud)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_send = Button.new()
	_send.text = "Send"
	_send.pressed.connect(_emit_send)
	row.add_child(_send)
	add_child(row)
	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.use_native_dialog = true
	_dialog.file_selected.connect(_on_file_selected)
	add_child(_dialog)


func set_busy(busy: bool) -> void:
	_busy = busy
	_send.disabled = busy
	_edit.editable = not busy
	_attach_img.disabled = busy
	_attach_aud.disabled = busy


func grab_composer_focus() -> void:
	_edit.grab_focus()


func _on_edit_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER and not event.shift_pressed:
			_emit_send()
			_edit.accept_event()


func _emit_send() -> void:
	if _busy:
		return
	var text := _edit.text.strip_edges()
	if text.is_empty() and _parts.is_empty():
		return
	var outgoing: Array = _parts.duplicate()
	_parts.clear()
	_refresh_chips()
	_edit.text = ""
	send_requested.emit(text, outgoing)


func _pick_image() -> void:
	_dialog.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp ; Images"])
	_dialog.title = "Attach image"
	_dialog.set_meta("kind", "image")
	_dialog.popup_centered_ratio(0.5)


func _pick_audio() -> void:
	_dialog.filters = PackedStringArray(["*.wav,*.mp3 ; Audio"])
	_dialog.title = "Attach audio"
	_dialog.set_meta("kind", "audio")
	_dialog.popup_centered_ratio(0.5)


func _on_file_selected(path: String) -> void:
	var kind := str(_dialog.get_meta("kind", "image"))
	if kind == "image":
		var uri := MediaEncode.image_file_to_data_uri(path)
		if uri.is_empty():
			return
		_parts.append(ChatTypes.ContentPart.image_url(uri))
	else:
		var payload := MediaEncode.audio_file_to_payload(path)
		if str(payload.get("data", "")).is_empty():
			return
		_parts.append(ChatTypes.ContentPart.input_audio(str(payload.data), str(payload.format)))
	_refresh_chips()


func _refresh_chips() -> void:
	for child in _chips.get_children():
		child.queue_free()
	for i in range(_parts.size()):
		var part: ChatTypes.ContentPart = _parts[i]
		var chip := Button.new()
		chip.text = "image" if part.kind == "image_url" else "audio"
		var idx := i
		chip.pressed.connect(func():
			if idx >= 0 and idx < _parts.size():
				_parts.remove_at(idx)
				_refresh_chips()
		)
		_chips.add_child(chip)
