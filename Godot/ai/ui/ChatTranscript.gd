## Scrollable transcript: user/assistant text plus collapsed thinking and tools.
class_name ChatTranscript extends ScrollContainer


const MESSAGE_SCENE := preload("res://ai/ui/ChatMessage.tscn")

@onready var _list: VBoxContainer = $List

var _stream_message: ChatMessage = null
var _stream_thinking: CollapsibleBlock = null
var _pending_tools: Dictionary = {}


## Rebuild from the active conversation (no system messages).
func rebuild(conversation: Conversation) -> void:
	_clear_children()
	_stream_message = null
	_stream_thinking = null
	_pending_tools.clear()
	if conversation == null:
		return
	var show_thinking := _thinking_enabled()
	for msg in conversation.messages:
		if not msg is ChatTypes.ORChatMessage:
			continue
		match msg.role:
			"user":
				_add_message(ChatMessage.Kind.USER, msg.get_text(), msg)
			"assistant":
				if msg.finish_reason == "max_tool_rounds":
					_add_message(ChatMessage.Kind.LIMIT, msg.get_text(), msg)
					continue
				if show_thinking and not msg.reasoning.is_empty():
					_list.add_child(CollapsibleBlock.new("thinking", "Thinking", msg.reasoning))
				var text: String = msg.get_text()
				if not text.is_empty() or msg.tool_calls.is_empty():
					_add_message(ChatMessage.Kind.ASSISTANT, text if not text.is_empty() else "…", msg)
				for tc in msg.tool_calls:
					if tc is ChatTypes.ORToolCall:
						var args_text: String = JSON.stringify(tc.arguments, "\t") if not tc.arguments.is_empty() else tc.arguments_raw
						_list.add_child(CollapsibleBlock.new("tool", "Tool · %s" % tc.name, args_text))
			"tool":
				var body := str(msg.content)
				var title := "Result"
				if not msg.tool_call_id.is_empty():
					title = "Result · %s" % _tool_name_for(conversation, msg.tool_call_id)
				_list.add_child(CollapsibleBlock.new("result", title, body))
	_scroll_to_end()


## Prepare streaming widgets for a new assistant turn.
func begin_assistant_turn() -> void:
	_stream_thinking = null
	_stream_message = _add_message(ChatMessage.Kind.ASSISTANT, "", null)
	_pending_tools.clear()
	_scroll_to_end()


## Append streamed reasoning into a collapsible thinking block.
func append_reasoning(text: String) -> void:
	if not _thinking_enabled() or text.is_empty():
		return
	if _stream_thinking == null:
		_stream_thinking = CollapsibleBlock.new("thinking", "Thinking", "")
		var idx := _stream_message.get_index() if _stream_message else _list.get_child_count()
		_list.add_child(_stream_thinking)
		_list.move_child(_stream_thinking, idx)
	_stream_thinking.append_body(text)
	_scroll_to_end()


## Append streamed assistant text to the current bubble.
func append_text(text: String) -> void:
	if _stream_message == null:
		_stream_message = _add_message(ChatMessage.Kind.ASSISTANT, text, null)
	else:
		_stream_message.append_text(text)
	_scroll_to_end()


## Show a collapsed block for an in-flight tool call.
func add_tool_call(tool_name: String, args: Dictionary) -> void:
	var args_text := JSON.stringify(args, "\t")
	var block := CollapsibleBlock.new("tool", "Tool · %s" % tool_name, args_text)
	_list.add_child(block)
	_pending_tools[tool_name] = _list.get_child_count()
	_scroll_to_end()


## Show a collapsed block for a tool result or error.
func add_tool_result(tool_name: String, result: Dictionary) -> void:
	var body := AiTool.to_model_content(result)
	_list.add_child(CollapsibleBlock.new("result", "Result · %s" % tool_name, body))
	_scroll_to_end()


## Instance a message prefab, add it to the list, and return it.
func _add_message(kind: ChatMessage.Kind, text: String, msg: ChatTypes.ORChatMessage) -> ChatMessage:
	var bubble := MESSAGE_SCENE.instantiate() as ChatMessage
	_list.add_child(bubble)
	bubble.configure(kind, text, msg)
	return bubble


## Resolve a tool-call id to the tool name in this conversation.
func _tool_name_for(conversation: Conversation, call_id: String) -> String:
	for msg in conversation.messages:
		if not msg is ChatTypes.ORChatMessage:
			continue
		for tc in msg.tool_calls:
			if tc is ChatTypes.ORToolCall and tc.id == call_id:
				return tc.name
	return call_id


## Whether Settings asks the transcript to show model reasoning.
func _thinking_enabled() -> bool:
	var settings := get_node_or_null("/root/Settings")
	if settings == null:
		return true
	return bool(settings.call("get_value", "ai/chat/reasoning"))


## Free every message node in the list.
func _clear_children() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		child.queue_free()


## Scroll to the latest message after the next layout pass.
func _scroll_to_end() -> void:
	await get_tree().process_frame
	set_deferred("scroll_vertical", int(get_v_scroll_bar().max_value))
