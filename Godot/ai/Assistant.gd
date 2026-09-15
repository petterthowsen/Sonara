# Assistant.gd
# Autoload: system prompt + conversation + tool loop + persist.
extends Node


signal conversation_changed()
signal turn_started()
signal text_delta(text: String)
signal reasoning_delta(text: String)
signal tool_started(tool_name: String, args: Dictionary)
signal tool_finished(tool_name: String, result: Dictionary)
signal turn_finished()
signal turn_failed(error: ChatTypes.ORChatError)
## Model metadata (context length) became available.
signal model_info_changed()


const DEFAULT_MAX_TOOL_ROUNDS := 64
const MIN_TOOL_ROUNDS := 8
const MAX_TOOL_ROUNDS_CAP := 256
const DEFAULT_KEEP_EXCHANGES := 200
## Assistant notice for a failed request. Shown in the transcript, never sent to the model.
const FINISH_ERROR := "error"

var client: OpenRouterClient
var store: ConversationStore = ConversationStore.new()
var registry: ToolRegistry = ToolRegistry.create_default()
var prompt_context: PromptContext = PromptContext.new()

var _busy: bool = false
var _cancel: bool = false
var _wait_msg: ChatTypes.ORChatMessage = null
var _wait_err: ChatTypes.ORChatError = null
var _wait_cancelled: bool = false
var _editor_wired: bool = false
var _last_rendered_system_prompt: String = ""
var _tools_token_estimate: int = -1


## Create the OpenRouter client and bind the current editor project.
func _ready() -> void:
	client = OpenRouterClient.new()
	add_child(client)
	client.text_delta.connect(_on_client_text)
	client.reasoning_delta.connect(_on_client_reasoning)
	client.message_finished.connect(_on_client_finished)
	client.request_failed.connect(_on_client_failed)
	client.request_cancelled.connect(_on_client_cancelled)
	call_deferred("_wire_editor")
	set_process(true)


## Debounced conversation writes.
func _process(_delta: float) -> void:
	store.poll_autosave()


func is_busy() -> bool:
	return _busy


func has_api_key() -> bool:
	return client != null and client.has_api_key()


func get_conversation() -> Conversation:
	return store.get_current()


func list_conversations() -> Array:
	return store.list_conversations()


func get_model_label() -> String:
	var settings := get_node_or_null("/root/Settings")
	if settings:
		return str(settings.call("get_value", "ai/openrouter/model"))
	return ""


## System prompt text from the most recent OpenRouter request (expanded template).
func get_last_rendered_system_prompt() -> String:
	return _last_rendered_system_prompt


## Token/cost totals for the current conversation plus the model's context window.
## Adds `context_length` (0 when unknown) and `model` to Conversation.usage_summary().
func get_usage_summary() -> Dictionary:
	var conv := store.get_current()
	var summary: Dictionary = conv.usage_summary(_tools_estimate()) if conv else Conversation.new().usage_summary()
	var model := get_model_label()
	summary["model"] = model
	summary["context_length"] = client.get_context_length(model) if client else 0
	return summary


## Fetch /models once per session so context_length is known. Emits model_info_changed.
func refresh_model_info() -> void:
	if client == null or not client.has_api_key() or client.has_model_cache():
		return
	var data: Array = await client.list_models()
	if not data.is_empty():
		model_info_changed.emit()


## Stored request/response record for the current conversation, or {}.
func load_exchange(exchange_id: String) -> Dictionary:
	var conv := store.get_current()
	if conv == null:
		return {}
	return ExchangeLog.read(store.exchange_dir(conv.id), exchange_id)


## Folder of request/response records for the current conversation ("" when unbound).
func get_exchange_dir() -> String:
	var conv := store.get_current()
	return store.exchange_dir(conv.id) if conv else ""


## Bind store to a project file path and reopen its last conversation. Empty = fresh scratch
## for a new untitled project.
func bind_project(project_path: String) -> void:
	if _busy:
		cancel()
	store.bind_project(project_path, project_path.is_empty())
	_sync_system_prompt_from_current_conversation()
	conversation_changed.emit()


## Flush and unbind on project close.
func unbind_project() -> void:
	if _busy:
		cancel()
	store.unbind()
	_last_rendered_system_prompt = ""
	conversation_changed.emit()


## After Save / Save As, carry the current chats over to the saved file's sidecar.
func migrate_to_saved(project_path: String) -> void:
	if project_path.is_empty() or project_path == store.get_bound_path():
		return
	store.migrate_to(project_path)
	conversation_changed.emit()


## Start a new thread on the current project.
func new_conversation() -> Conversation:
	if _busy:
		cancel()
	var c := store.create()
	_sync_system_prompt_from_current_conversation()
	conversation_changed.emit()
	return c


## Load an existing thread by id.
func open_conversation(id: String) -> void:
	if _busy:
		cancel()
	var c := store.load_conversation(id)
	if c:
		store.set_current(c)
		_sync_system_prompt_from_current_conversation()
		conversation_changed.emit()


## Delete a thread (creates a replacement if it was the last).
func delete_conversation(id: String) -> void:
	if _busy:
		cancel()
	store.delete_conversation(id)
	_sync_system_prompt_from_current_conversation()
	conversation_changed.emit()


## User turn: text, optional ContentPart array, and optional SelectionContext items attached
## as a `<selection_context>` block. No-ops if busy or missing key.
func send_user(text: String, parts: Array = [], context: Array = []) -> void:
	if _busy:
		return
	if client == null or not client.has_api_key():
		turn_failed.emit(ChatTypes.ORChatError.missing_key())
		return
	var conv := store.get_current()
	if conv == null:
		conv = store.create()
	var trimmed := text.strip_edges()
	var msg: ChatTypes.ORChatMessage
	if parts.is_empty():
		if trimmed.is_empty():
			return
		msg = ChatTypes.ORChatMessage.user_text(trimmed)
	else:
		var all_parts: Array = []
		if not trimmed.is_empty():
			all_parts.append(ChatTypes.ORContentPart.text_part(trimmed))
		for p in parts:
			all_parts.append(p)
		msg = ChatTypes.ORChatMessage.user_parts(all_parts)
	msg.context = SelectionContext.to_storage(context)
	conv.messages.append(msg)
	conv.ensure_title_from_first_user()
	store.schedule_save()
	conversation_changed.emit()
	await _run_turn()


## Stop the in-flight stream; leftover tools are not executed.
func cancel() -> void:
	if not _busy:
		return
	_cancel = true
	if client:
		client.cancel()


func _wire_editor() -> void:
	if _editor_wired:
		return
	if Sonara == null or Sonara.editor == null:
		return
	_editor_wired = true
	var ed: Editor = Sonara.editor
	if not ed.project_opened.is_connected(_on_project_opened):
		ed.project_opened.connect(_on_project_opened)
	if not ed.project_closed.is_connected(_on_project_closed):
		ed.project_closed.connect(_on_project_closed)
	if not ed.project_saved.is_connected(_on_project_saved):
		ed.project_saved.connect(_on_project_saved)
	if ed.project:
		bind_project(ed.project_path)
	else:
		bind_project("")


func _on_project_opened(_project: Project) -> void:
	var path := ""
	if Sonara and Sonara.editor:
		path = Sonara.editor.project_path
	bind_project(path)


func _on_project_closed() -> void:
	unbind_project()


func _on_project_saved(path: String) -> void:
	if store.get_current() == null:
		bind_project(path)
	else:
		migrate_to_saved(path)


func _on_client_text(text: String) -> void:
	text_delta.emit(text)


func _on_client_reasoning(text: String) -> void:
	reasoning_delta.emit(text)


func _on_client_finished(message: ChatTypes.ORChatMessage) -> void:
	_wait_msg = message


func _on_client_failed(error: ChatTypes.ORChatError) -> void:
	_wait_err = error


func _on_client_cancelled() -> void:
	_wait_cancelled = true


func _run_turn() -> void:
	_busy = true
	_cancel = false
	refresh_model_info()
	turn_started.emit()
	var conv := store.get_current()
	var hist = HistoryUtil.history()
	var limit := _max_tool_rounds()
	var rounds := 0
	var hit_limit := false
	while rounds < limit:
		if _cancel:
			break
		var assistant_msg := await _chat_once(conv, true)
		if assistant_msg == null:
			break
		conv.messages.append(assistant_msg)
		conv.touch(get_model_label())
		store.schedule_save()
		conversation_changed.emit()
		if _cancel:
			break
		if assistant_msg.tool_calls.is_empty():
			break
		if hist:
			hist.begin_macro("Assistant")
		for tc in assistant_msg.tool_calls:
			if _cancel:
				break
			if not tc is ChatTypes.ORToolCall:
				continue
			tool_started.emit(tc.name, tc.arguments)
			var result: Dictionary = await registry.execute(tc.name, tc.arguments)
			tool_finished.emit(tc.name, result)
			var tool_msg := ChatTypes.ORChatMessage.tool_result(tc.id, AiTool.to_model_content(result))
			conv.messages.append(tool_msg)
		if hist:
			hist.end_macro()
		store.schedule_save()
		conversation_changed.emit()
		rounds += 1
		if _cancel:
			break
		if rounds >= limit:
			hit_limit = true
			break
	if hit_limit and not _cancel:
		await _finish_after_tool_limit(conv, limit)
	conv.ensure_title_from_first_user()
	store.autosave_current()
	_busy = false
	_cancel = false
	turn_finished.emit()
	conversation_changed.emit()


## Tool-round cap from Settings, clamped to a safe range.
func _max_tool_rounds() -> int:
	var settings := get_node_or_null("/root/Settings")
	var n := DEFAULT_MAX_TOOL_ROUNDS
	if settings:
		n = int(settings.call("get_value", "ai/chat/max_tool_rounds"))
	return clampi(n, MIN_TOOL_ROUNDS, MAX_TOOL_ROUNDS_CAP)


## One last un-tooled reply, then a visible notice that the round cap was hit.
func _finish_after_tool_limit(conv: Conversation, limit: int) -> void:
	var closing := await _chat_once(conv, false, false)
	if closing:
		conv.messages.append(closing)
		conv.touch(get_model_label())
		store.schedule_save()
		conversation_changed.emit()
	var notice := ChatTypes.ORChatMessage.assistant_text(
		"Stopped after %d tool rounds. Raise Settings → AI → Max Tool Rounds to continue longer tasks." % limit
	)
	notice.finish_reason = "max_tool_rounds"
	conv.messages.append(notice)
	store.schedule_save()
	conversation_changed.emit()


## Restore in-memory prompt snapshot from the active conversation file.
func _sync_system_prompt_from_current_conversation() -> void:
	var conv := store.get_current()
	if conv == null:
		_last_rendered_system_prompt = ""
		return
	_last_rendered_system_prompt = conv.last_rendered_system_prompt


func _chat_once(conv: Conversation, with_tools: bool = true, emit_fail: bool = true) -> ChatTypes.ORChatMessage:
	_wait_msg = null
	_wait_err = null
	_wait_cancelled = false
	var req := ChatTypes.ORChatRequest.new()
	req.stream = true
	req.modalities = PackedStringArray(["text"])
	if with_tools:
		req.tools = registry.get_openrouter_tools()
		req.tool_choice = "auto"
	req.model = get_model_label()
	var system := ChatTypes.ORChatMessage.new()
	system.role = "system"
	_last_rendered_system_prompt = PromptTemplate.render(prompt_context)
	conv.last_rendered_system_prompt = _last_rendered_system_prompt
	system.content = _last_rendered_system_prompt
	var msgs: Array = [system]
	for m in conv.messages:
		if m is ChatTypes.ORChatMessage and m.finish_reason == FINISH_ERROR:
			continue
		msgs.append(m)
	req.messages = msgs
	client.chat(req)
	while _wait_msg == null and _wait_err == null and not _wait_cancelled:
		await get_tree().process_frame
	var exchange_id := _store_exchange(conv)
	if _wait_err:
		var notice := ChatTypes.ORChatMessage.assistant_text("Request failed: %s" % _wait_err.message)
		notice.finish_reason = FINISH_ERROR
		notice.exchange_id = exchange_id
		conv.messages.append(notice)
		store.schedule_save()
		if emit_fail:
			turn_failed.emit(_wait_err)
		return null
	if _wait_cancelled or _wait_msg == null:
		return null
	_wait_msg.exchange_id = exchange_id
	return _wait_msg


## Persist the client's last request/response for `conv`. Returns the exchange id or "".
func _store_exchange(conv: Conversation) -> String:
	var record: Dictionary = client.get_last_exchange()
	var keep := _keep_exchanges()
	if record.is_empty() or keep <= 0:
		return ""
	var id := ExchangeLog.new_id()
	var path := ExchangeLog.write(store.exchange_dir(conv.id), id, conv.id, record, keep)
	return id if not path.is_empty() else ""


## How many request/response records to keep per conversation (0 = off).
func _keep_exchanges() -> int:
	var settings := get_node_or_null("/root/Settings")
	if settings:
		return int(settings.call("get_value", "ai/debug/keep_exchanges"))
	return DEFAULT_KEEP_EXCHANGES


## Estimated tokens for the tool schemas sent with every request (cached).
func _tools_estimate() -> int:
	if _tools_token_estimate < 0:
		_tools_token_estimate = TokenEstimate.text(JSON.stringify(registry.get_openrouter_tools()))
	return _tools_token_estimate
