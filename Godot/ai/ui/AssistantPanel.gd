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
var _usage_lbl: Label = null
var _exchange_viewer: ExchangeViewer = null

const USAGE_WARN_RATIO := 0.75
const USAGE_CRITICAL_RATIO := 0.9
const USAGE_COLOR := Color(0.7, 0.72, 0.78, 0.85)
const USAGE_WARN_COLOR := Color(0.95, 0.7, 0.3)
const USAGE_CRITICAL_COLOR := Color(0.95, 0.4, 0.35)


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
		if not assistant.model_info_changed.is_connected(_refresh_usage):
			assistant.model_info_changed.connect(_refresh_usage)
		assistant.refresh_model_info()
	_transcript.exchange_requested.connect(_on_exchange_requested)
	_setup_usage_label()
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
	_refresh_usage()
	_rebuilding = false


## Lightweight header update while a turn is in flight.
func _on_conversation_changed() -> void:
	if _rebuilding:
		return
	var assistant := _assistant()
	if assistant and assistant.is_busy():
		_header_list.rebuild(assistant.list_conversations(), assistant.store.get_active_id())
		_model_lbl.text = assistant.get_model_label()
		_refresh_usage()
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


## Context meter next to the model name: tokens / context window, %, and cost.
func _setup_usage_label() -> void:
	_usage_lbl = Label.new()
	_usage_lbl.add_theme_font_size_override("font_size", 11)
	_usage_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	_meta.add_child(_usage_lbl)
	_meta.move_child(_usage_lbl, _model_lbl.get_index() + 1)


func _refresh_usage() -> void:
	var assistant := _assistant()
	if _usage_lbl == null or assistant == null:
		return
	var u: Dictionary = assistant.get_usage_summary()
	var ctx := int(u.context_tokens)
	var limit := int(u.context_length)
	var approx := "~" if u.estimated else ""
	var text := "%s%s" % [approx, TokenEstimate.format_count(ctx)]
	var ratio := 0.0
	if limit > 0:
		ratio = float(ctx) / float(limit)
		text += " / %s (%d%%)" % [TokenEstimate.format_count(limit), roundi(ratio * 100.0)]
	else:
		text += " tok"
	if float(u.cost) > 0.0:
		text += " · $%.2f" % float(u.cost)
	_usage_lbl.text = text
	var color := USAGE_COLOR
	if ratio >= USAGE_CRITICAL_RATIO:
		color = USAGE_CRITICAL_COLOR
	elif ratio >= USAGE_WARN_RATIO:
		color = USAGE_WARN_COLOR
	_usage_lbl.add_theme_color_override("font_color", color)
	var lines: PackedStringArray = [
		"Context: %s%d tokens%s" % [approx, ctx, " of %d" % limit if limit > 0 else " (context window unknown)"],
		"  (%s)" % ("estimated: ~4 chars per token for messages not yet sent" if u.estimated else "last reported prompt + completion"),
		"Requests: %d" % int(u.requests),
		"Prompt tokens sent: %d (cached %d)" % [int(u.prompt_tokens), int(u.cached_tokens)],
		"Completion tokens: %d (reasoning %d)" % [int(u.completion_tokens), int(u.reasoning_tokens)],
		"Cost: $%.4f" % float(u.cost),
	]
	_usage_lbl.tooltip_text = "\n".join(lines)


## Open the stored request/response record for one assistant round.
func _on_exchange_requested(exchange_id: String) -> void:
	var assistant := _assistant()
	if assistant == null:
		return
	var record: Dictionary = assistant.load_exchange(exchange_id)
	if record.is_empty():
		push_warning("[AssistantPanel] Request log %s not found (pruned or logging off)" % exchange_id)
		return
	if _exchange_viewer == null:
		_exchange_viewer = ExchangeViewer.new()
		add_child(_exchange_viewer)
	var path: String = assistant.get_exchange_dir().path_join("%s.json" % exchange_id)
	_exchange_viewer.show_exchange(record, path)


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


## Forward composer text, attachments, and selection context to Assistant.
func _on_send(text: String, parts: Array, context: Array) -> void:
	var assistant := _assistant()
	if assistant:
		assistant.send_user(text, parts, context)


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
	_refresh()
	# Request failures are persisted as error notices; others (e.g. missing key) only live in the UI.
	var assistant := _assistant()
	var conv: Conversation = assistant.get_conversation() if assistant else null
	var last = conv.messages.back() if conv and not conv.messages.is_empty() else null
	if not (last is ChatTypes.ORChatMessage and last.finish_reason == "error"):
		_transcript.add_tool_result("error", {"ok": false, "error": error.message})


## Disable conversation switching and the composer while a turn is running.
func _set_busy(busy: bool) -> void:
	_cancel_btn.visible = busy
	_composer.set_busy(busy)
	_new_btn.disabled = busy
	if not busy:
		_refresh_usage()
	_delete_btn.disabled = busy
	_header_list.disabled = busy
