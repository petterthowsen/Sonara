# test_openrouter_sse.gd
# Headless tests for OpenRouterSse, ChatTypes wire format, and ChatError.
# Run: godot --headless --path Godot -s ai/tests/test_openrouter_sse.gd
extends SceneTree


var _failures: int = 0


func _init() -> void:
	print("=== OpenRouter SSE / ChatTypes tests ===")
	_test_split_mid_line()
	_test_multiple_events_per_chunk()
	_test_done_and_comments()
	_test_crlf_and_ignore_after_done()
	_test_multimodal_user_message()
	_test_tool_call_merge()
	_test_chat_error_401()
	_test_audio_modalities_force_stream()
	if _failures == 0:
		print("=== ALL PASSED ===")
	else:
		print("=== FAILED: %d ===" % _failures)
	quit(_failures)


func _assert(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		push_error("FAIL: " + msg)
		print("FAIL: ", msg)
	else:
		print("ok: ", msg)


## A payload split across two feed() calls is reassembled.
func _test_split_mid_line() -> void:
	var sse := OpenRouterSse.new()
	var first := sse.feed_text("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"")
	_assert(first.is_empty(), "incomplete line yields no event")
	var second := sse.feed_text("}}]}\n")
	_assert(second.size() == 1, "second chunk completes one event")
	_assert(second[0].contains("Hel"), "reassembled payload has content")
	_assert(not sse.is_done(), "not done without [DONE]")


## One chunk can contain several complete SSE events.
func _test_multiple_events_per_chunk() -> void:
	var sse := OpenRouterSse.new()
	var chunk := (
		"data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n"
		+ "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n"
		+ "data: [DONE]\n"
	)
	var events := sse.feed_text(chunk)
	_assert(events.size() == 2, "two data events before DONE")
	_assert(events[0].contains("Hel"), "first event is Hel")
	_assert(events[1].contains("lo"), "second event is lo")
	_assert(sse.is_done(), "[DONE] marks parser finished")


## Comments and blank lines are ignored; [DONE] stops the parser.
func _test_done_and_comments() -> void:
	var sse := OpenRouterSse.new()
	var events := sse.feed_text(": keep-alive\n\ndata: {\"a\":1}\n\ndata: [DONE]\n")
	_assert(events.size() == 1, "comment lines skipped")
	_assert(events[0] == "{\"a\":1}", "payload stripped of data: prefix")
	_assert(sse.is_done(), "done after [DONE]")


## CRLF line endings work; bytes after [DONE] are ignored.
func _test_crlf_and_ignore_after_done() -> void:
	var sse := OpenRouterSse.new()
	var events := sse.feed("data: {\"x\":1}\r\ndata: [DONE]\r\ndata: {\"x\":2}\r\n".to_utf8_buffer())
	_assert(events.size() == 1, "only the event before DONE")
	_assert(sse.is_done(), "done after CRLF [DONE]")
	var extra := sse.feed_text("data: {\"x\":3}\n")
	_assert(extra.is_empty(), "feed after DONE returns nothing")


## User message can carry text + image_url + input_audio in OpenRouter shape.
func _test_multimodal_user_message() -> void:
	var parts: Array = [
		ChatTypes.ContentPart.text_part("What's on this clip?"),
		ChatTypes.ContentPart.image_url("data:image/png;base64,aaa", "auto"),
		ChatTypes.ContentPart.input_audio("YmFzZTY0", "wav"),
	]
	var msg := ChatTypes.ChatMessage.user_parts(parts)
	var wire: Dictionary = msg.to_openrouter()
	_assert(wire.role == "user", "role is user")
	_assert(wire.content is Array and wire.content.size() == 3, "three content parts")
	_assert(wire.content[0].type == "text", "first part is text")
	_assert(wire.content[1].type == "image_url", "second part is image_url")
	_assert(str(wire.content[1].image_url.url).begins_with("data:image/png;base64,"), "image is a data URI")
	_assert(wire.content[2].type == "input_audio", "third part is input_audio")
	_assert(wire.content[2].input_audio.data == "YmFzZTY0", "audio is raw base64")
	_assert(not str(wire.content[2].input_audio.data).begins_with("data:"), "audio is not a data URI")


## Streaming tool-call fragments merge by index and parse JSON arguments.
func _test_tool_call_merge() -> void:
	var tc := ChatTypes.ToolCall.new()
	tc.merge_delta({"index": 0, "id": "call_1", "function": {"name": "list_project", "arguments": "{"}})
	tc.merge_delta({"index": 0, "function": {"arguments": "}"}})
	tc.parse_arguments()
	_assert(tc.id == "call_1", "id from first fragment")
	_assert(tc.name == "list_project", "name from first fragment")
	_assert(tc.arguments_raw == "{}", "arguments concatenated")
	_assert(tc.arguments is Dictionary, "parsed arguments dict")
	var chunk := {
		"choices": [{
			"delta": {
				"tool_calls": [
					{"index": 0, "id": "call_1", "function": {"name": "list_project", "arguments": "{}"}}
				]
			},
			"finish_reason": "tool_calls",
		}]
	}
	var delta := ChatTypes.ChatDelta.from_openrouter_chunk(chunk)
	_assert(delta.tool_call_fragments.size() == 1, "delta carries tool_calls")
	_assert(delta.finish_reason == "tool_calls", "finish_reason from choice")


## 401 surfaces a readable message, never the request body key.
func _test_chat_error_401() -> void:
	var err := ChatTypes.ChatError.from_http(401, '{"error":{"message":"User not found.","code":401}}')
	_assert(err.http_status == 401, "status stored")
	_assert(err.message.contains("401"), "message mentions 401")
	_assert(err.message.contains("User not found") or err.message.contains("invalid"), "API or fallback message")
	var missing := ChatTypes.ChatError.missing_key()
	_assert(missing.code == "missing_api_key", "missing key code")
	_assert(missing.message.contains("Settings"), "missing key points at Settings")
	var provider_body := JSON.stringify({
		"error": {
			"message": "Provider returned error",
			"code": 400,
			"metadata": {
				"provider_name": "Google",
				"raw": JSON.stringify({"error": {"message": "items is required"}}),
			},
		},
	})
	var provider := ChatTypes.ChatError.from_http(400, provider_body)
	_assert(provider.message.contains("Google"), "provider name in message")
	_assert(provider.message.contains("items is required"), "unwrapped provider raw")
	_assert(provider.message.contains("400"), "status in message")


## Audio output modalities force stream true and include voice/format.
func _test_audio_modalities_force_stream() -> void:
	var req := ChatTypes.ChatRequest.new()
	req.model = "openai/gpt-4o-audio-preview"
	req.messages = [ChatTypes.ChatMessage.user_text("Say hi")]
	req.stream = false
	req.modalities = PackedStringArray(["text", "audio"])
	req.audio = {"voice": "alloy", "format": "wav"}
	req.temperature = 0.2
	req.max_tokens = 128
	var body: Dictionary = req.to_openrouter()
	_assert(body.stream == true, "audio out requires stream")
	_assert(body.audio.voice == "alloy", "audio voice passed through")
	_assert(body.modalities.has("audio"), "modalities include audio")
	var img_req := ChatTypes.ChatRequest.new()
	img_req.model = "google/gemini-2.5-flash-image"
	img_req.messages = [ChatTypes.ChatMessage.user_text("a red square")]
	img_req.modalities = PackedStringArray(["text", "image"])
	img_req.temperature = 0.5
	img_req.max_tokens = 256
	var img_body: Dictionary = img_req.to_openrouter()
	_assert(img_body.modalities.has("image"), "modalities include image")
