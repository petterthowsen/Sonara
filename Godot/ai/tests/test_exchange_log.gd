# test_exchange_log.gd
# Headless tests for request/response logging and token usage accounting.
# Run: godot --headless --path Godot -s ai/tests/test_exchange_log.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Exchange log / token usage tests"


func run_tests() -> void:
	_test_usage_chunk_parsed()
	_test_message_usage_roundtrip()
	_test_redact_request()
	_test_write_read_prune()
	_test_usage_summary_reported()
	_test_usage_summary_estimated()
	_test_format_count()
	_test_summary_and_link_labels()


func _usage() -> Dictionary:
	return {
		"prompt_tokens": 1200,
		"completion_tokens": 80,
		"total_tokens": 1280,
		"cost": 0.0042,
		"prompt_tokens_details": {"cached_tokens": 1000},
		"completion_tokens_details": {"reasoning_tokens": 20},
	}


## The final accounting chunk carries usage and the generation id.
func _test_usage_chunk_parsed() -> void:
	var chunk := {
		"id": "gen-abc",
		"choices": [{"index": 0, "delta": {"content": "", "role": "assistant"}, "finish_reason": "stop"}],
		"usage": _usage(),
	}
	var delta := ChatTypes.ORChatDelta.from_openrouter_chunk(chunk)
	_assert(delta.generation_id == "gen-abc", "generation id parsed")
	_assert(int(delta.usage.get("prompt_tokens", 0)) == 1200, "usage parsed from final chunk")
	var plain := ChatTypes.ORChatDelta.from_openrouter_chunk({"choices": [{"delta": {"content": "hi"}}]})
	_assert(plain.usage.is_empty(), "content chunk has no usage")


## usage and exchange_id persist; neither is sent back to the model.
func _test_message_usage_roundtrip() -> void:
	var msg := ChatTypes.ORChatMessage.assistant_text("done")
	msg.usage = _usage()
	msg.exchange_id = "ex_1_abc"
	var restored := ChatTypes.ORChatMessage.from_storage(msg.to_storage())
	_assert(restored.exchange_id == "ex_1_abc", "exchange_id round-trips")
	_assert(int(restored.usage.get("completion_tokens", 0)) == 80, "usage round-trips")
	var wire := msg.to_openrouter()
	_assert(not wire.has("usage") and not wire.has("exchange_id"), "debug fields not on the wire")
	var bare := ChatTypes.ORChatMessage.assistant_text("x").to_storage()
	_assert(not bare.has("usage") and not bare.has("exchange_id"), "empty debug fields not stored")


## Image data URIs and input audio are shortened; text and the original body are untouched.
func _test_redact_request() -> void:
	var big := "A".repeat(5000)
	var body := {
		"model": "m",
		"messages": [
			{"role": "system", "content": "B".repeat(5000)},
			{"role": "user", "content": [
				{"type": "text", "text": "look"},
				{"type": "image_url", "image_url": {"url": "data:image/png;base64," + big, "detail": "auto"}},
				{"type": "image_url", "image_url": {"url": "https://example.com/a.png"}},
				{"type": "input_audio", "input_audio": {"data": big, "format": "wav"}},
			]},
		],
	}
	var out := ExchangeLog.redact_request(body)
	var parts: Array = out.messages[1].content
	var img_url: String = parts[1].image_url.url
	_assert(img_url.begins_with("data:image/png;base64,<"), "data URI keeps its header")
	_assert(img_url.contains("5000 chars omitted"), "data URI payload replaced by size")
	_assert(parts[2].image_url.url == "https://example.com/a.png", "short URL kept")
	_assert(str(parts[3].input_audio.data).contains("omitted"), "audio payload replaced")
	_assert(str(out.messages[0].content).length() == 5000, "long system text kept")
	_assert(str(body.messages[1].content[3].input_audio.data).length() == 5000, "original body not mutated")


## Records are written, read back, and pruned oldest-first.
func _test_write_read_prune() -> void:
	var dir := ProjectSettings.globalize_path("user://test_exchange_log_%d" % Time.get_ticks_usec())
	var record := {"status": "ok", "model": "m", "request": {"messages": []}, "response": {"usage": _usage()}}
	var ids := ["ex_100_000001", "ex_100_000002", "ex_101_000001", "ex_102_000001"]
	for id in ids:
		ExchangeLog.write(dir, id, "conv_x", record, 3)
	var left := ExchangeLog.list_ids(dir)
	_assert(left.size() == 3, "pruned to keep=3")
	_assert(not left.has("ex_100_000001"), "oldest record removed")
	var back := ExchangeLog.read(dir, "ex_102_000001")
	_assert(back.get("conversation_id", "") == "conv_x", "conversation id stored")
	_assert(back.get("id", "") == "ex_102_000001", "id stored")
	_assert(ExchangeLog.read(dir, "ex_missing").is_empty(), "missing record reads as {}")
	_assert(ExchangeLog.write(dir, "ex_103_000001", "conv_x", record, 0).is_empty(), "keep=0 disables writing")
	ExchangeLog.prune(dir, 0)
	DirAccess.remove_absolute(dir)
	_assert(not DirAccess.dir_exists_absolute(dir), "temp dir cleaned up")


## Context = last reported prompt + completion; messages after it are estimated.
func _test_usage_summary_reported() -> void:
	var conv := Conversation.create_new()
	conv.messages.append(ChatTypes.ORChatMessage.user_text("hello"))
	var first := ChatTypes.ORChatMessage.assistant_text("hi")
	first.usage = {"prompt_tokens": 500, "completion_tokens": 10, "cost": 0.001}
	conv.messages.append(first)
	var second := ChatTypes.ORChatMessage.assistant_text("ok")
	second.usage = _usage()
	conv.messages.append(second)
	var s := conv.usage_summary()
	_assert(int(s.context_tokens) == 1280, "context from last usage")
	_assert(not s.estimated, "not estimated right after a response")
	_assert(int(s.requests) == 2, "two reported requests")
	_assert(int(s.prompt_tokens) == 1700, "prompt tokens summed")
	_assert(int(s.cached_tokens) == 1000, "cached tokens summed")
	_assert(absf(float(s.cost) - 0.0052) < 0.000001, "cost summed")
	conv.messages.append(ChatTypes.ORChatMessage.user_text("x".repeat(400)))
	var after := conv.usage_summary()
	_assert(after.estimated, "pending user message makes it an estimate")
	_assert(int(after.context_tokens) == 1280 + 100 + TokenEstimate.MESSAGE_OVERHEAD, "pending message estimated at 4 chars/token")


## Without any usage the whole context is estimated, including extra (tool schema) tokens.
func _test_usage_summary_estimated() -> void:
	var conv := Conversation.create_new()
	conv.last_rendered_system_prompt = "s".repeat(800)
	conv.messages.append(ChatTypes.ORChatMessage.user_text("u".repeat(40)))
	var s := conv.usage_summary(50)
	_assert(s.estimated, "estimated without usage")
	_assert(int(s.context_tokens) == 200 + 10 + TokenEstimate.MESSAGE_OVERHEAD + 50, "system + message + extra")
	_assert(int(s.requests) == 0 and float(s.cost) == 0.0, "no requests, no cost")


func _test_format_count() -> void:
	_assert(TokenEstimate.format_count(950) == "950", "under 1k")
	_assert(TokenEstimate.format_count(12400) == "12.4k", "k with decimal")
	_assert(TokenEstimate.format_count(200000) == "200k", "whole k drops .0")
	_assert(TokenEstimate.format_count(1048576) == "1M", "M rounding")


func _test_summary_and_link_labels() -> void:
	var record := {
		"status": "error",
		"model": "anthropic/claude-sonnet-4.5",
		"duration_ms": 1500,
		"request": {"messages": [{}, {}], "tools": [{}]},
		"response": {"http_status": 400, "usage": _usage(), "error": {"message": "bad tool schema", "code": "400"}},
	}
	# UI scripts depend on autoloads, so load them at runtime rather than naming the classes.
	var viewer: GDScript = load("res://ai/ui/ExchangeViewer.gd")
	var transcript: GDScript = load("res://ai/ui/ChatTranscript.gd")
	var text: String = viewer.summary_text(record, "/tmp/x.json")
	_assert(text.contains("1.50 s"), "summary has duration")
	_assert(text.contains("(cached 1000)"), "summary has cached tokens")
	_assert(text.contains("bad tool schema"), "summary has error")
	_assert(text.contains("/tmp/x.json"), "summary has file path")
	_assert(transcript.exchange_link_label(_usage()) == "{ } 1.2k in · 80 out · $0.0042", "link label with usage")
	_assert(transcript.exchange_link_label({}) == "{ } request", "link label without usage")
