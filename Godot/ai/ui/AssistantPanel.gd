# AssistantPanel.gd
# Right-dock chat: conversation header, transcript, composer.
class_name AssistantPanel extends PanelContainer


var _header_list: ConversationList
var _new_btn: Button
var _delete_btn: Button
var _model_lbl: Label
var _cancel_btn: Button
var _empty: Label
var _transcript: ChatTranscript
var _composer: ChatComposer
var _rebuilding: bool = false


func _ready() -> void:
	theme_type_variation = "PrimaryPanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(280, 0)
	_build()
	var assistant := _assistant()
	if assistant:
		if not assistant.conversation_changed.is_connected(_on_conversation_changed):
			assistant.conversation_changed.connect(_on_conversation_changed)
		if not assistant.turn_started.is_connected(_on_turn_started):
			assistant.turn_started.connect(_on_turn_started)
		if not assistant.text_delta.is_connected(_on_text_delta):
			assistant.text_delta.connect(_on_text_delta)
		if not assistant.reasoning_delta.is_connected(_on_reasoning_delta):
			assistant.reasoning_delta.connect(_on_reasoning_delta)
		if not assistant.tool_started.is_connected(_on_tool_started):
			assistant.tool_started.connect(_on_tool_started)
		if not assistant.tool_finished.is_connected(_on_tool_finished):
			assistant.tool_finished.connect(_on_tool_finished)
		if not assistant.turn_finished.is_connected(_on_turn_finished):
			assistant.turn_finished.connect(_on_turn_finished)
		if not assistant.turn_failed.is_connected(_on_turn_failed):
			assistant.turn_failed.connect(_on_turn_failed)
	_refresh()


## Autoload node, or null before it is registered.
func _assistant() -> Node:
	return get_node_or_null("/root/Assistant")


func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	_header_list = ConversationList.new()
	_header_list.conversation_chosen.connect(_on_conversation_chosen)
	header.add_child(_header_list)
	_new_btn = Button.new()
	_new_btn.text = "New"
	_new_btn.pressed.connect(_on_new)
	header.add_child(_new_btn)
	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.pressed.connect(_on_delete)
	header.add_child(_delete_btn)
	root.add_child(header)
	var meta := HBoxContainer.new()
	_model_lbl = Label.new()
	_model_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_lbl.clip_text = true
	_model_lbl.add_theme_font_size_override("font_size", 11)
	meta.add_child(_model_lbl)
	_cancel_btn = Button.new()
	_cancel_btn.text = "Cancel"
	_cancel_btn.visible = false
	_cancel_btn.pressed.connect(_on_cancel)
	meta.add_child(_cancel_btn)
	root.add_child(meta)
	_empty = Label.new()
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.text = "Set an OpenRouter API key in Settings → AI"
	_empty.visible = false
	root.add_child(_empty)
	_transcript = ChatTranscript.new()
	root.add_child(_transcript)
	_composer = ChatComposer.new()
	_composer.send_requested.connect(_on_send)
	root.add_child(_composer)


func _refresh() -> void:
	var assistant := _assistant()
	if assistant == null:
		return
	_rebuilding = true
	_model_lbl.text = assistant.get_model_label()
	var has_key: bool = assistant.has_api_key()
	_empty.visible = not has_key
	_composer.visible = has_key
	_transcript.visible = has_key
	var conv: Conversation = assistant.get_conversation()
	var active: String = conv.id if conv else ""
	_header_list.rebuild(assistant.list_conversations(), active)
	if has_key:
		_transcript.rebuild(conv)
	_set_busy(assistant.is_busy())
	_rebuilding = false


func _on_conversation_changed() -> void:
	if _rebuilding:
		return
	var assistant := _assistant()
	if assistant and assistant.is_busy():
		_header_list.rebuild(assistant.list_conversations(), assistant.store.get_active_id())
		_model_lbl.text = assistant.get_model_label()
		return
	_refresh()


func _on_conversation_chosen(id: String) -> void:
	var assistant := _assistant()
	if assistant:
		assistant.open_conversation(id)


func _on_new() -> void:
	var assistant := _assistant()
	if assistant:
		assistant.new_conversation()


func _on_delete() -> void:
	var assistant := _assistant()
	if assistant == null:
		return
	var conv: Conversation = assistant.get_conversation()
	if conv:
		assistant.delete_conversation(conv.id)


func _on_cancel() -> void:
	var assistant := _assistant()
	if assistant:
		assistant.cancel()


func _on_send(text: String, parts: Array) -> void:
	var assistant := _assistant()
	if assistant:
		assistant.send_user(text, parts)


func _on_turn_started() -> void:
	_set_busy(true)
	_transcript.begin_assistant_turn()


func _on_text_delta(text: String) -> void:
	_transcript.append_text(text)


func _on_reasoning_delta(text: String) -> void:
	_transcript.append_reasoning(text)


func _on_tool_started(tool_name: String, args: Dictionary) -> void:
	_transcript.add_tool_call(tool_name, args)


func _on_tool_finished(tool_name: String, result: Dictionary) -> void:
	_transcript.add_tool_result(tool_name, result)


func _on_turn_finished() -> void:
	_set_busy(false)
	_refresh()


func _on_turn_failed(error: ChatTypes.ChatError) -> void:
	_set_busy(false)
	_transcript.add_tool_result("error", {"ok": false, "error": error.message})
	_refresh()


func _set_busy(busy: bool) -> void:
	_cancel_btn.visible = busy
	_composer.set_busy(busy)
	_new_btn.disabled = busy
	_delete_btn.disabled = busy
	_header_list.disabled = busy
