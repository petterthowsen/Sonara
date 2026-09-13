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
signal turn_failed(error: ChatTypes.ChatError)


const DEFAULT_MAX_TOOL_ROUNDS := 64
const MIN_TOOL_ROUNDS := 8
const MAX_TOOL_ROUNDS_CAP := 256

var client: OpenRouterClient
var store: ConversationStore = ConversationStore.new()
var registry: ToolRegistry = ToolRegistry.create_default()
var prompt_context: PromptContext = PromptContext.new()

var _busy: bool = false
var _cancel: bool = false
var _wait_msg: ChatTypes.ChatMessage = null
var _wait_err: ChatTypes.ChatError = null
var _wait_cancelled: bool = false
var _editor_wired: bool = false


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


## Bind store to a project file path (empty = scratch).
func bind_project(project_path: String) -> void:
	store.bind_project(project_path)
	conversation_changed.emit()


## Flush and unbind on project close.
func unbind_project() -> void:
	store.unbind()
	conversation_changed.emit()


## After Save As, move scratch chats next to the project.
func migrate_if_scratch(project_path: String) -> void:
	if store.is_scratch() and not project_path.is_empty():
		store.migrate_scratch_to(project_path)
		conversation_changed.emit()


## Start a new thread on the current project.
func new_conversation() -> Conversation:
	if _busy:
		cancel()
	var c := store.create()
	conversation_changed.emit()
	return c


## Load an existing thread by id.
func open_conversation(id: String) -> void:
	if _busy:
		cancel()
	var c := store.load_conversation(id)
	if c:
		store.set_current(c)
		conversation_changed.emit()


## Delete a thread (creates a replacement if it was the last).
func delete_conversation(id: String) -> void:
	if _busy:
		cancel()
	store.delete_conversation(id)
	conversation_changed.emit()


## User turn: text and optional ContentPart array. No-ops if busy or missing key.
func send_user(text: String, parts: Array = []) -> void:
	if _busy:
		return
	if client == null or not client.has_api_key():
		turn_failed.emit(ChatTypes.ChatError.missing_key())
		return
	var conv := store.get_current()
	if conv == null:
		conv = store.create()
	var trimmed := text.strip_edges()
	var msg: ChatTypes.ChatMessage
	if parts.is_empty():
		if trimmed.is_empty():
			return
		msg = ChatTypes.ChatMessage.user_text(trimmed)
	else:
		var all_parts: Array = []
		if not trimmed.is_empty():
			all_parts.append(ChatTypes.ContentPart.text_part(trimmed))
		for p in parts:
			all_parts.append(p)
		msg = ChatTypes.ChatMessage.user_parts(all_parts)
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
	migrate_if_scratch(path)
	if store.get_current() == null:
		bind_project(path)


func _on_client_text(text: String) -> void:
	text_delta.emit(text)


func _on_client_reasoning(text: String) -> void:
	reasoning_delta.emit(text)


func _on_client_finished(message: ChatTypes.ChatMessage) -> void:
	_wait_msg = message


func _on_client_failed(error: ChatTypes.ChatError) -> void:
	_wait_err = error


func _on_client_cancelled() -> void:
	_wait_cancelled = true


func _run_turn() -> void:
	_busy = true
	_cancel = false
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
			if not tc is ChatTypes.ToolCall:
				continue
			tool_started.emit(tc.name, tc.arguments)
			var result: Dictionary = await registry.execute(tc.name, tc.arguments)
			tool_finished.emit(tc.name, result)
			var tool_msg := ChatTypes.ChatMessage.tool_result(tc.id, JSON.stringify(result))
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
	var notice := ChatTypes.ChatMessage.assistant_text(
		"Stopped after %d tool rounds. Raise Settings → AI → Max Tool Rounds to continue longer tasks." % limit
	)
	notice.finish_reason = "max_tool_rounds"
	conv.messages.append(notice)
	store.schedule_save()
	conversation_changed.emit()


func _chat_once(conv: Conversation, with_tools: bool = true, emit_fail: bool = true) -> ChatTypes.ChatMessage:
	_wait_msg = null
	_wait_err = null
	_wait_cancelled = false
	var req := ChatTypes.ChatRequest.new()
	req.stream = true
	req.modalities = PackedStringArray(["text"])
	if with_tools:
		req.tools = registry.get_openrouter_tools()
		req.tool_choice = "auto"
	req.model = get_model_label()
	var system := ChatTypes.ChatMessage.new()
	system.role = "system"
	system.content = PromptTemplate.render(prompt_context)
	var msgs: Array = [system]
	for m in conv.messages:
		msgs.append(m)
	req.messages = msgs
	client.chat(req)
	while _wait_msg == null and _wait_err == null and not _wait_cancelled:
		await get_tree().process_frame
	if _wait_err:
		if emit_fail:
			turn_failed.emit(_wait_err)
		return null
	if _wait_cancelled or _wait_msg == null:
		return null
	return _wait_msg
