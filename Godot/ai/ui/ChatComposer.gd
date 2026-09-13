## Multiline input, file attach, send.
class_name ChatComposer extends VBoxContainer


signal send_requested(text: String, parts: Array)


@onready var _chips: HBoxContainer = $Chips
@onready var _edit: TextEdit = $Edit
@onready var _attach_img: Button = $Row/AttachImage
@onready var _attach_aud: Button = $Row/AttachAudio
@onready var _send: Button = $Row/Send
@onready var _dialog: FileDialog = $FileDialog

var _parts: Array = []
var _busy: bool = false


## Disable send and attachments while a turn is running.
func set_busy(busy: bool) -> void:
	_busy = busy
	_send.disabled = busy
	_edit.editable = not busy
	_attach_img.disabled = busy
	_attach_aud.disabled = busy


## Focus the prompt field.
func grab_composer_focus() -> void:
	_edit.grab_focus()


## Send on Enter; Shift+Enter inserts a newline.
func _on_edit_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER and not event.shift_pressed:
			_emit_send()
			_edit.accept_event()


## Emit `send_requested` when there is text or attached media.
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


## Open a native file dialog for an image attachment.
func _pick_image() -> void:
	_dialog.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp ; Images"])
	_dialog.title = "Attach image"
	_dialog.set_meta("kind", "image")
	_dialog.popup_centered_ratio(0.5)


## Open a native file dialog for an audio attachment.
func _pick_audio() -> void:
	_dialog.filters = PackedStringArray(["*.wav,*.mp3 ; Audio"])
	_dialog.title = "Attach audio"
	_dialog.set_meta("kind", "audio")
	_dialog.popup_centered_ratio(0.5)


## Encode the picked file and add it as a content part chip.
func _on_file_selected(path: String) -> void:
	var kind := str(_dialog.get_meta("kind", "image"))
	if kind == "image":
		var uri := MediaEncode.image_file_to_data_uri(path)
		if uri.is_empty():
			return
		_parts.append(ChatTypes.ORContentPart.image_url(uri))
	else:
		var payload := MediaEncode.audio_file_to_payload(path)
		if str(payload.get("data", "")).is_empty():
			return
		_parts.append(ChatTypes.ORContentPart.input_audio(str(payload.data), str(payload.format)))
	_refresh_chips()


## Rebuild removable chips for the pending attachments.
func _refresh_chips() -> void:
	for child in _chips.get_children():
		child.queue_free()
	for i in range(_parts.size()):
		var part: ChatTypes.ORContentPart = _parts[i]
		var chip := Button.new()
		chip.text = "image" if part.kind == "image_url" else "audio"
		var idx := i
		chip.pressed.connect(func():
			if idx >= 0 and idx < _parts.size():
				_parts.remove_at(idx)
				_refresh_chips()
		)
		_chips.add_child(chip)
