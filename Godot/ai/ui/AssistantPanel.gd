## Right-dock chat: conversation header, transcript, composer.
class_name AssistantPanel extends PanelContainer


@onready var _header_list: ConversationList = $Content/Header/ConversationList
@onready var _new_btn: Button = $Content/Header/New
@onready var _delete_btn: Button = $Content/Header/Delete
@onready var _model_lbl: Label = $Content/Meta/ModelLabel
@onready var _meta: HBoxContainer = $Content/Meta
@onready var _cancel_btn: Button = $Content/Meta/Cancel
@onready var _empty: Label = $Content/Empty
@onready var _transcript: ChatTranscript = $Content/Transcript
@onready var _composer: ChatComposer = $Content/Composer

var _rebuilding: bool = false
var _prompt_btn: Button = null
var _prompt_window: Window = null
var _prompt_edit: TextEdit = null


## Bind to the Assistant autoload and paint the current conversation.
func _ready() -> void:
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
	_setup_prompt_button()
	_refresh()


## Autoload node, or null before it is registered.
func _assistant() -> Node:
	return get_node_or_null("/root/Assistant")


## Refresh header, transcript, and composer from the current Assistant state.
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
	if _prompt_btn:
		_prompt_btn.visible = has_key
	var conv: Conversation = assistant.get_conversation()
	var active: String = conv.id if conv else ""
	_header_list.rebuild(assistant.list_conversations(), active)
	if has_key:
		_transcript.rebuild(conv)
	_set_busy(assistant.is_busy())
	_rebuilding = false


## Lightweight header update while a turn is in flight.
func _on_conversation_changed() -> void:
	if _rebuilding:
		return
	var assistant := _assistant()
	if assistant and assistant.is_busy():
		_header_list.rebuild(assistant.list_conversations(), assistant.store.get_active_id())
		_model_lbl.text = assistant.get_model_label()
		return
	_refresh()


## Switch the active conversation from the header dropdown.
func _on_conversation_chosen(id: String) -> void:
	var assistant := _assistant()
	if assistant:
		assistant.open_conversation(id)


## Start a new empty conversation.
func _on_new() -> void:
	var assistant := _assistant()
	if assistant:
		assistant.new_conversation()


## Delete the conversation currently shown in the header.
func _on_delete() -> void:
	var assistant := _assistant()
	if assistant == null:
		return
	var conv: Conversation = assistant.get_conversation()
	if conv:
		assistant.delete_conversation(conv.id)


## Header control: show the last system prompt sent to the model.
func _setup_prompt_button() -> void:
	_prompt_btn = Button.new()
	_prompt_btn.text = "Prompt"
	_prompt_btn.tooltip_text = "View the last rendered system prompt"
	_prompt_btn.pressed.connect(_on_show_system_prompt)
	_meta.add_child(_prompt_btn)
	_meta.move_child(_prompt_btn, _cancel_btn.get_index())


func _ensure_prompt_window() -> void:
	if _prompt_window:
		return
	_prompt_window = Window.new()
	_prompt_window.title = "System prompt"
	_prompt_window.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	_prompt_window.size = Vector2i(640, 480)
	_prompt_window.min_size = Vector2i(320, 200)
	_prompt_window.close_requested.connect(_prompt_window.hide)
	_prompt_window.wrap_controls = true
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_prompt_window.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(vbox)
	_prompt_edit = TextEdit.new()
	_prompt_edit.editable = false
	_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_prompt_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_prompt_edit)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(_prompt_window.hide)
	vbox.add_child(close)
	add_child(_prompt_window)


func _on_show_system_prompt() -> void:
	_ensure_prompt_window()
	var text := ""
	var assistant := _assistant()
	if assistant:
		text = assistant.get_last_rendered_system_prompt()
	if text.is_empty():
		text = "No message sent yet. The expanded system prompt is shown here after your first request."
	_prompt_edit.text = text
	_prompt_window.popup_centered()


## Abort the in-flight Assistant turn.
func _on_cancel() -> void:
	var assistant := _assistant()
	if assistant:
		assistant.cancel()


## Forward composer text and attachments to Assistant.
func _on_send(text: String, parts: Array) -> void:
	var assistant := _assistant()
	if assistant:
		assistant.send_user(text, parts)


## Lock the composer and start a streaming assistant bubble.
func _on_turn_started() -> void:
	_set_busy(true)
	_transcript.begin_assistant_turn()


## Append streamed assistant text to the current bubble.
func _on_text_delta(text: String) -> void:
	_transcript.append_text(text)


## Append streamed reasoning into the thinking block.
func _on_reasoning_delta(text: String) -> void:
	_transcript.append_reasoning(text)


## Show a tool-call block as soon as the model requests it.
func _on_tool_started(tool_name: String, args: Dictionary) -> void:
	_transcript.add_tool_call(tool_name, args)


## Show the tool result under the matching call.
func _on_tool_finished(tool_name: String, result: Dictionary) -> void:
	_transcript.add_tool_result(tool_name, result)


## Unlock the UI after a successful turn and reload persisted messages.
func _on_turn_finished() -> void:
	_set_busy(false)
	_refresh()


## Surface a turn error in the transcript, then reload.
func _on_turn_failed(error: ChatTypes.ORChatError) -> void:
	_set_busy(false)
	_transcript.add_tool_result("error", {"ok": false, "error": error.message})
	_refresh()


## Disable conversation switching and the composer while a turn is running.
func _set_busy(busy: bool) -> void:
	_cancel_btn.visible = busy
	_composer.set_busy(busy)
	_new_btn.disabled = busy
	_delete_btn.disabled = busy
	_header_list.disabled = busy
