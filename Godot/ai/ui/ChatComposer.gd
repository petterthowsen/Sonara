## Multiline input, file attach, send. A row of glowing badges shows the selection context
## (SelectionContext) that will be attached to the next message; click a badge to exclude it.
class_name ChatComposer extends VBoxContainer


signal send_requested(text: String, parts: Array, context: Array)


@onready var _chips: HBoxContainer = $Chips
@onready var _edit: TextEdit = $Edit
@onready var _attach_img: Button = $Row/AttachImage
@onready var _attach_aud: Button = $Row/AttachAudio
@onready var _send: Button = $Row/Send
@onready var _dialog: FileDialog = $FileDialog

var _parts: Array = []
var _busy: bool = false

var _context_row: HFlowContainer = null
var _context_items: Array = []
## SelectionContext item keys the user clicked off. A changed selection has a new key, so it shows again.
var _excluded: Dictionary = {}
var _editor_wired: bool = false
var _context_refresh_queued: bool = false


func _ready() -> void:
	_context_row = HFlowContainer.new()
	_context_row.name = "Context"
	_context_row.add_theme_constant_override("h_separation", 6)
	_context_row.add_theme_constant_override("v_separation", 6)
	_context_row.visible = false
	add_child(_context_row)
	move_child(_context_row, 0)
	_edit.focus_entered.connect(_queue_context_refresh)
	visibility_changed.connect(_queue_context_refresh)
	set_process(true)


## Wire editor selection signals once the editor exists.
func _process(_delta: float) -> void:
	if _wire_editor():
		set_process(false)


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
	_refresh_context()
	send_requested.emit(text, outgoing, get_active_context())


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


## Selection items that will be attached to the next message (excluded badges left out).
func get_active_context() -> Array:
	var out: Array = []
	for item in _context_items:
		if not _excluded.has(item.key):
			out.append(item)
	return out


## Connect to the editor's selection signals. True once wired (or when there is nothing to wire in tests).
func _wire_editor() -> bool:
	if _editor_wired:
		return true
	if Utils.is_test_mode():
		return true
	var sonara := get_node_or_null("/root/Sonara")
	if sonara == null or sonara.editor == null or not sonara.editor.is_node_ready():
		return false
	var ed: Editor = sonara.editor
	_editor_wired = true
	var refresh := _queue_context_refresh
	ed.clips_selected.connect(refresh.unbind(2))
	ed.track_focused.connect(refresh.unbind(1))
	ed.tracks_selected.connect(refresh.unbind(1))
	ed.channel_focused.connect(refresh.unbind(1))
	ed.view_changed.connect(refresh.unbind(1))
	ed.project_opened.connect(refresh.unbind(1))
	ed.project_closed.connect(refresh)
	ed.tempo_changed.connect(refresh.unbind(1))
	ed.time_signature_changed.connect(refresh.unbind(2))
	if ed.mixer:
		ed.mixer.selection_changed.connect(_queue_context_refresh.unbind(1))
	if ed.arranger and ed.arranger.timeline and ed.arranger.timeline.clip_selection_manager:
		ed.arranger.timeline.clip_selection_manager.range_changed.connect(_queue_context_refresh)
	_queue_context_refresh()
	return true


## Coalesce bursts of selection signals into one refresh at the end of the frame.
func _queue_context_refresh() -> void:
	if _context_refresh_queued:
		return
	_context_refresh_queued = true
	_refresh_context.call_deferred()


## Recollect the selection and rebuild the badge row.
func _refresh_context() -> void:
	_context_refresh_queued = false
	if _context_row == null:
		return
	var sonara := get_node_or_null("/root/Sonara")
	var ed: Editor = sonara.editor if sonara else null
	_context_items = SelectionContext.collect(ed)
	var live_keys: Dictionary = {}
	for item in _context_items:
		live_keys[item.key] = true
	for key in _excluded.keys():
		if not live_keys.has(key):
			_excluded.erase(key)
	for child in _context_row.get_children():
		child.queue_free()
	for item in _context_items:
		_context_row.add_child(_make_context_badge(item))
	_context_row.visible = not _context_items.is_empty()


func _make_context_badge(item: Dictionary) -> Badge:
	var badge := Badge.make(str(item.label), SelectionContext.color_for(item), SelectionContext.icon_for(item))
	var excluded := _excluded.has(item.key)
	badge.glow = not excluded
	badge.muted = excluded
	badge.clickable = true
	badge.tooltip_text = "%s\n\n%s" % [
		str(item.text),
		"Excluded from the next message. Click to include." if excluded else "Sent with the next message. Click to exclude.",
	]
	var key: String = item.key
	badge.pressed.connect(func():
		if _excluded.has(key):
			_excluded.erase(key)
		else:
			_excluded[key] = true
		_queue_context_refresh()
	)
	return badge
