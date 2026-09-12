# ChatTranscript.gd
# Scrollable transcript: user/assistant text plus collapsed thinking and tools.
class_name ChatTranscript extends ScrollContainer


var _list: VBoxContainer
var _stream_text: RichTextLabel = null
var _stream_wrap: Node = null
var _stream_thinking: CollapsibleBlock = null
var _pending_tools: Dictionary = {}


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	add_child(_list)


## Rebuild from the active conversation (no system messages).
func rebuild(conversation: Conversation) -> void:
	_clear_children()
	_stream_text = null
	_stream_thinking = null
	_pending_tools.clear()
	if conversation == null:
		return
	var show_thinking := _thinking_enabled()
	for msg in conversation.messages:
		if not msg is ChatTypes.ChatMessage:
			continue
		match msg.role:
			"user":
				_add_bubble("You", msg.get_text(), Color(0.35, 0.45, 0.62, 0.35), msg)
			"assistant":
				if show_thinking and not msg.reasoning.is_empty():
					_list.add_child(CollapsibleBlock.new("thinking", "Thinking", msg.reasoning))
				var text: String = msg.get_text()
				if not text.is_empty() or msg.tool_calls.is_empty():
					_add_bubble("Assistant", text if not text.is_empty() else "…", Color(0.22, 0.22, 0.26, 0.55), msg)
				for tc in msg.tool_calls:
					if tc is ChatTypes.ToolCall:
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
	_stream_text = _add_bubble("Assistant", "", Color(0.22, 0.22, 0.26, 0.55), null)
	_stream_wrap = _stream_text.get_parent().get_parent() if _stream_text else null
	_pending_tools.clear()
	_scroll_to_end()


func append_reasoning(text: String) -> void:
	if not _thinking_enabled() or text.is_empty():
		return
	if _stream_thinking == null:
		_stream_thinking = CollapsibleBlock.new("thinking", "Thinking", "")
		var idx := _stream_wrap.get_index() if _stream_wrap else _list.get_child_count()
		_list.add_child(_stream_thinking)
		_list.move_child(_stream_thinking, idx)
	_stream_thinking.append_body(text)
	_scroll_to_end()


func append_text(text: String) -> void:
	if _stream_text == null:
		_stream_text = _add_bubble("Assistant", text, Color(0.22, 0.22, 0.26, 0.55), null)
	else:
		_stream_text.text += text
	_scroll_to_end()


func add_tool_call(tool_name: String, args: Dictionary) -> void:
	var args_text := JSON.stringify(args, "\t")
	var block := CollapsibleBlock.new("tool", "Tool · %s" % tool_name, args_text)
	_list.add_child(block)
	_pending_tools[tool_name] = _list.get_child_count()
	_scroll_to_end()


func add_tool_result(tool_name: String, result: Dictionary) -> void:
	var body := JSON.stringify(result, "\t")
	_list.add_child(CollapsibleBlock.new("result", "Result · %s" % tool_name, body))
	_scroll_to_end()


func _add_bubble(who: String, text: String, bg: Color, msg: ChatTypes.ChatMessage) -> RichTextLabel:
	var wrap := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	wrap.add_theme_stylebox_override("panel", style)
	var col := VBoxContainer.new()
	var who_lbl := Label.new()
	who_lbl.text = who
	who_lbl.add_theme_font_size_override("font_size", 11)
	who_lbl.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78, 0.8))
	col.add_child(who_lbl)
	var body := RichTextLabel.new()
	body.bbcode_enabled = false
	body.fit_content = true
	body.scroll_active = false
	body.selection_enabled = true
	body.text = text
	col.add_child(body)
	if msg:
		_add_media(col, msg)
	wrap.add_child(col)
	_list.add_child(wrap)
	return body


func _add_media(col: VBoxContainer, msg: ChatTypes.ChatMessage) -> void:
	if not msg.content is Array:
		return
	for part in msg.content:
		if not part is ChatTypes.ContentPart:
			continue
		if part.kind == "image_url" or part.kind == "output_image":
			var tex := MediaEncode.image_from_data_uri(part.url)
			if tex:
				var rect := TextureRect.new()
				rect.texture = tex
				rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
				rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				rect.custom_minimum_size = Vector2(0, 80)
				col.add_child(rect)
		elif part.kind == "input_audio" or part.kind == "output_audio":
			var hint := Label.new()
			hint.text = "Audio (%s)" % part.audio_format
			hint.add_theme_font_size_override("font_size", 11)
			col.add_child(hint)


func _tool_name_for(conversation: Conversation, call_id: String) -> String:
	for msg in conversation.messages:
		if not msg is ChatTypes.ChatMessage:
			continue
		for tc in msg.tool_calls:
			if tc is ChatTypes.ToolCall and tc.id == call_id:
				return tc.name
	return call_id


func _thinking_enabled() -> bool:
	var settings := get_node_or_null("/root/Settings")
	if settings == null:
		return true
	return bool(settings.call("get_value", "ai/chat/reasoning"))


func _clear_children() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		child.queue_free()


func _scroll_to_end() -> void:
	await get_tree().process_frame
	set_deferred("scroll_vertical", int(get_v_scroll_bar().max_value))
