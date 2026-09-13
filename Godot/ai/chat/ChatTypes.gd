# ChatTypes.gd
# On-wire shapes for OpenRouter Chat Completions. The assistant never builds raw dicts.
class_name ChatTypes extends RefCounted


## One content part: text, image, or audio (in or out).
class ContentPart:
	var kind: String = "text"
	var text: String = ""
	var url: String = ""
	var detail: String = "auto"
	var audio_b64: String = ""
	var audio_format: String = "wav"
	var mime: String = ""


	## Plain text part.
	static func text_part(p_text: String) -> ContentPart:
		var part := ContentPart.new()
		part.kind = "text"
		part.text = p_text
		return part


	## Image as HTTPS URL or data URI.
	static func image_url(p_url: String, p_detail: String = "auto") -> ContentPart:
		var part := ContentPart.new()
		part.kind = "image_url"
		part.url = p_url
		part.detail = p_detail
		return part


	## Input audio: raw base64 bytes, not a data URI.
	static func input_audio(p_b64: String, p_format: String = "wav") -> ContentPart:
		var part := ContentPart.new()
		part.kind = "input_audio"
		part.audio_b64 = p_b64
		part.audio_format = p_format
		return part


	## Assistant audio output (assembled after the stream ends).
	static func output_audio(p_b64: String, p_format: String = "wav") -> ContentPart:
		var part := ContentPart.new()
		part.kind = "output_audio"
		part.audio_b64 = p_b64
		part.audio_format = p_format
		return part


	## Assistant image output.
	static func output_image(p_url: String) -> ContentPart:
		var part := ContentPart.new()
		part.kind = "output_image"
		part.url = p_url
		return part


	## Serialize to an OpenRouter content-part object.
	func to_openrouter() -> Dictionary:
		match kind:
			"image_url", "output_image":
				return {"type": "image_url", "image_url": {"url": url, "detail": detail}}
			"input_audio":
				return {"type": "input_audio", "input_audio": {"data": audio_b64, "format": audio_format}}
			_:
				return {"type": "text", "text": text}


	## Persist a content part (media as data URI / base64).
	func to_storage() -> Dictionary:
		return {
			"kind": kind,
			"text": text,
			"url": url,
			"detail": detail,
			"audio_b64": audio_b64,
			"audio_format": audio_format,
			"mime": mime,
		}


	## Restore a content part saved by to_storage().
	static func from_storage(data: Dictionary) -> ContentPart:
		var part := ContentPart.new()
		part.kind = str(data.get("kind", "text"))
		part.text = str(data.get("text", ""))
		part.url = str(data.get("url", ""))
		part.detail = str(data.get("detail", "auto"))
		part.audio_b64 = str(data.get("audio_b64", ""))
		part.audio_format = str(data.get("audio_format", "wav"))
		part.mime = str(data.get("mime", ""))
		return part


	## Parse one OpenRouter content-part object.
	static func from_openrouter(data: Dictionary) -> ContentPart:
		var type_name := str(data.get("type", "text"))
		match type_name:
			"image_url":
				var img = data.get("image_url", {})
				var img_url := ""
				var img_detail := "auto"
				if img is Dictionary:
					img_url = str(img.get("url", ""))
					img_detail = str(img.get("detail", "auto"))
				elif img is String:
					img_url = img
				return image_url(img_url, img_detail)
			"input_audio":
				var aud = data.get("input_audio", {})
				if aud is Dictionary:
					return input_audio(str(aud.get("data", "")), str(aud.get("format", "wav")))
				return input_audio("", "wav")
			"output_audio":
				return output_audio(str(data.get("data", "")), str(data.get("format", "wav")))
			_:
				return text_part(str(data.get("text", "")))


## One streamed or completed tool call.
class ToolCall:
	var id: String = ""
	var name: String = ""
	var arguments: Dictionary = {}
	var arguments_raw: String = ""
	var index: int = 0


	## Serialize to OpenRouter tool_calls[] item.
	func to_openrouter() -> Dictionary:
		var raw := arguments_raw
		if raw.is_empty() and not arguments.is_empty():
			raw = JSON.stringify(arguments)
		return {
			"id": id,
			"type": "function",
			"function": {"name": name, "arguments": raw},
		}


	## Parse a completed tool_calls[] item.
	static func from_openrouter(data: Dictionary) -> ToolCall:
		var tc := ToolCall.new()
		tc.id = str(data.get("id", ""))
		tc.index = int(data.get("index", 0))
		var fn = data.get("function", {})
		if fn is Dictionary:
			tc.name = str(fn.get("name", ""))
			tc.arguments_raw = str(fn.get("arguments", ""))
		tc.parse_arguments()
		return tc


	## Merge a streaming tool-call delta (OpenAI index convention).
	func merge_delta(data: Dictionary) -> void:
		if data.has("id") and str(data.id) != "":
			id = str(data.id)
		if data.has("index"):
			index = int(data.index)
		var fn = data.get("function", {})
		if fn is Dictionary:
			if fn.has("name") and str(fn.name) != "":
				name = str(fn.name)
			if fn.has("arguments"):
				arguments_raw += str(fn.arguments)


	## Persist id / name / arguments for conversation files.
	func to_storage() -> Dictionary:
		return {
			"id": id,
			"name": name,
			"arguments": arguments,
			"arguments_raw": arguments_raw,
			"index": index,
		}


	## Restore a tool call saved by to_storage().
	static func from_storage(data: Dictionary) -> ToolCall:
		var tc := ToolCall.new()
		tc.id = str(data.get("id", ""))
		tc.name = str(data.get("name", ""))
		tc.arguments_raw = str(data.get("arguments_raw", ""))
		tc.index = int(data.get("index", 0))
		var args = data.get("arguments", {})
		if args is Dictionary:
			tc.arguments = args
		elif not tc.arguments_raw.is_empty():
			tc.parse_arguments()
		return tc


	## Parse arguments_raw into arguments. Leaves {} on invalid JSON.
	func parse_arguments() -> void:
		if arguments_raw.is_empty():
			arguments = {}
			return
		var parsed = JSON.parse_string(arguments_raw)
		arguments = parsed if parsed is Dictionary else {}


## One chat message (system / user / assistant / tool).
class ChatMessage:
	var role: String = "user"
	var content = ""
	var name: String = ""
	var tool_calls: Array = []
	var tool_call_id: String = ""
	var finish_reason: String = ""
	var audio_b64: String = ""
	var audio_transcript: String = ""
	var reasoning: String = ""


	## User message with plain text.
	static func user_text(text: String) -> ChatMessage:
		var msg := ChatMessage.new()
		msg.role = "user"
		msg.content = text
		return msg


	## User message with multimodal parts.
	static func user_parts(parts: Array) -> ChatMessage:
		var msg := ChatMessage.new()
		msg.role = "user"
		msg.content = parts
		return msg


	## Assistant text (and optional tool calls).
	static func assistant_text(text: String) -> ChatMessage:
		var msg := ChatMessage.new()
		msg.role = "assistant"
		msg.content = text
		return msg


	## Tool result for tool_call_id.
	static func tool_result(p_call_id: String, p_content: String) -> ChatMessage:
		var msg := ChatMessage.new()
		msg.role = "tool"
		msg.tool_call_id = p_call_id
		msg.content = p_content
		return msg


	## Flatten text from string or part-array content.
	func get_text() -> String:
		if content is String:
			return content
		if content is Array:
			var bits: PackedStringArray = []
			for part in content:
				if part is ContentPart and part.kind == "text":
					bits.append(part.text)
			return "".join(bits)
		return ""


	## Serialize to an OpenRouter message object.
	func to_openrouter() -> Dictionary:
		var d := {"role": role}
		if not name.is_empty():
			d["name"] = name
		if not tool_call_id.is_empty():
			d["tool_call_id"] = tool_call_id
		if not tool_calls.is_empty():
			var calls: Array = []
			for tc in tool_calls:
				if tc is ToolCall:
					calls.append(tc.to_openrouter())
			d["tool_calls"] = calls
		if content is Array:
			var parts: Array = []
			for part in content:
				if part is ContentPart:
					parts.append(part.to_openrouter())
			d["content"] = parts
		elif content is String:
			if content.is_empty() and not tool_calls.is_empty():
				d["content"] = null
			else:
				d["content"] = content
		return d


	## Parse a completed OpenRouter message object.
	static func from_openrouter(data: Dictionary) -> ChatMessage:
		var msg := ChatMessage.new()
		msg.role = str(data.get("role", "assistant"))
		msg.name = str(data.get("name", ""))
		msg.tool_call_id = str(data.get("tool_call_id", ""))
		var raw_content = data.get("content", "")
		if raw_content is Array:
			var parts: Array = []
			for item in raw_content:
				if item is Dictionary:
					parts.append(ContentPart.from_openrouter(item))
				elif item is String:
					parts.append(ContentPart.text_part(item))
			msg.content = parts
		elif raw_content == null:
			msg.content = ""
		else:
			msg.content = str(raw_content)
		for tc_data in data.get("tool_calls", []):
			if tc_data is Dictionary:
				msg.tool_calls.append(ToolCall.from_openrouter(tc_data))
		var audio = data.get("audio", {})
		if audio is Dictionary:
			msg.audio_b64 = str(audio.get("data", ""))
			msg.audio_transcript = str(audio.get("transcript", ""))
		msg.reasoning = _reasoning_from(data)
		return msg


	## Persist without OpenRouter-only nulls. Includes reasoning for the transcript.
	func to_storage() -> Dictionary:
		var d := {
			"role": role,
			"name": name,
			"tool_call_id": tool_call_id,
			"finish_reason": finish_reason,
			"reasoning": reasoning,
			"audio_transcript": audio_transcript,
		}
		if not audio_b64.is_empty():
			d["audio_b64"] = audio_b64
		if content is Array:
			var parts: Array = []
			for part in content:
				if part is ContentPart:
					parts.append(part.to_storage())
			d["content_parts"] = parts
		else:
			d["content"] = str(content)
		if not tool_calls.is_empty():
			var calls: Array = []
			for tc in tool_calls:
				if tc is ToolCall:
					calls.append(tc.to_storage())
			d["tool_calls"] = calls
		return d


	## Restore a message saved by to_storage().
	static func from_storage(data: Dictionary) -> ChatMessage:
		var msg := ChatMessage.new()
		msg.role = str(data.get("role", "user"))
		msg.name = str(data.get("name", ""))
		msg.tool_call_id = str(data.get("tool_call_id", ""))
		msg.finish_reason = str(data.get("finish_reason", ""))
		msg.reasoning = str(data.get("reasoning", ""))
		msg.audio_transcript = str(data.get("audio_transcript", ""))
		msg.audio_b64 = str(data.get("audio_b64", ""))
		if data.has("content_parts") and data.content_parts is Array:
			var parts: Array = []
			for item in data.content_parts:
				if item is Dictionary:
					parts.append(ContentPart.from_storage(item))
			msg.content = parts
		else:
			msg.content = str(data.get("content", ""))
		for tc_data in data.get("tool_calls", []):
			if tc_data is Dictionary:
				msg.tool_calls.append(ToolCall.from_storage(tc_data))
		return msg


	## Pull a reasoning string from a message or delta object.
	static func _reasoning_from(data: Dictionary) -> String:
		var raw = data.get("reasoning", data.get("reasoning_content", ""))
		if raw is String:
			return raw
		if raw is Dictionary:
			return str(raw.get("text", raw.get("content", "")))
		return ""


## Outgoing chat/completions body.
class ChatRequest:
	var model: String = ""
	var messages: Array = []
	var tools: Array = []
	var stream: bool = true
	var modalities: PackedStringArray = PackedStringArray(["text"])
	var audio: Dictionary = {}
	var temperature: float = -1.0
	var max_tokens: int = 0
	var tool_choice = "auto"
	var reasoning: Dictionary = {}


	## Serialize to the OpenRouter request body.
	func to_openrouter() -> Dictionary:
		var body := {
			"model": model,
			"stream": stream,
			"temperature": temperature,
			"max_tokens": max_tokens,
		}
		var msgs: Array = []
		for msg in messages:
			if msg is ChatMessage:
				msgs.append(msg.to_openrouter())
			elif msg is Dictionary:
				msgs.append(msg)
		body["messages"] = msgs
		if not tools.is_empty():
			body["tools"] = tools
			body["tool_choice"] = tool_choice
		if not modalities.is_empty():
			var mods: Array = []
			for m in modalities:
				mods.append(m)
			body["modalities"] = mods
		if modalities.has("audio"):
			body["stream"] = true
			if not audio.is_empty():
				body["audio"] = audio
		if not reasoning.is_empty():
			body["reasoning"] = reasoning
		return body


	## True when any user part is an image.
	func has_image_input() -> bool:
		return _has_part_kind("image_url")


	## True when any user part is input audio.
	func has_audio_input() -> bool:
		return _has_part_kind("input_audio")


	func _has_part_kind(kind: String) -> bool:
		for msg in messages:
			if not msg is ChatMessage:
				continue
			if msg.content is Array:
				for part in msg.content:
					if part is ContentPart and part.kind == kind:
						return true
		return false


## Incremental SSE chunk.
class ChatDelta:
	var text: String = ""
	var tool_call_fragments: Array = []
	var audio_b64: String = ""
	var audio_transcript: String = ""
	var finish_reason: String = ""
	var reasoning: String = ""
	var image_part: ContentPart = null
	var error_message: String = ""
	var error_code: String = ""


	## Parse one `data:` JSON object from the SSE stream.
	static func from_openrouter_chunk(data: Dictionary) -> ChatDelta:
		var delta := ChatDelta.new()
		if data.has("error") and data.error is Dictionary:
			delta.error_message = ChatError.format_openrouter_error(data.error, 0)
			delta.error_code = str(data.error.get("code", ""))
			return delta
		var choices = data.get("choices", [])
		if choices.is_empty() or not choices[0] is Dictionary:
			return delta
		var choice: Dictionary = choices[0]
		delta.finish_reason = str(choice.get("finish_reason", ""))
		var raw = choice.get("delta", {})
		if not raw is Dictionary:
			raw = choice.get("message", {})
		if not raw is Dictionary:
			return delta
		var content = raw.get("content", null)
		if content is String:
			delta.text = content
		elif content is Array:
			for item in content:
				if not item is Dictionary:
					continue
				var part := ContentPart.from_openrouter(item)
				if part.kind == "text":
					delta.text += part.text
				elif part.kind == "image_url" or part.kind == "output_image":
					delta.image_part = part
		var audio = raw.get("audio", {})
		if audio is Dictionary:
			delta.audio_b64 = str(audio.get("data", ""))
			delta.audio_transcript = str(audio.get("transcript", ""))
		var images = raw.get("images", [])
		if images is Array and not images.is_empty() and images[0] is Dictionary:
			delta.image_part = ContentPart.from_openrouter(images[0])
		for frag in raw.get("tool_calls", []):
			if frag is Dictionary:
				delta.tool_call_fragments.append(frag)
		delta.reasoning = ChatMessage._reasoning_from(raw)
		if delta.reasoning.is_empty():
			delta.reasoning = ChatMessage._reasoning_from(data)
		return delta


## Transport or API failure. Never includes the API key.
class ChatError:
	var http_status: int = 0
	var message: String = ""
	var code: String = ""


	## Missing API key before any request is sent.
	static func missing_key() -> ChatError:
		var err := ChatError.new()
		err.message = "OpenRouter API key is not set. Add it in Settings → AI."
		err.code = "missing_api_key"
		return err


	## Connect / TLS / DNS failure.
	static func from_connect(status: int, detail: String) -> ChatError:
		var err := ChatError.new()
		err.code = "connect"
		err.message = detail if not detail.is_empty() else "Could not connect to OpenRouter (status %d)." % status
		return err


	## HTTP error body (`error.message`, plus OpenRouter `metadata` provider detail).
	static func from_http(status: int, body: String) -> ChatError:
		var err := ChatError.new()
		err.http_status = status
		err.message = "HTTP %d" % status
		if status == 401:
			err.message = "HTTP 401: invalid or missing API key."
		elif status == 402:
			err.message = "HTTP 402: OpenRouter credits required."
		elif status == 429:
			err.message = "HTTP 429: rate limited. Try again shortly."
		var parsed = JSON.parse_string(body) if not body.is_empty() else null
		if parsed is Dictionary:
			var api_err = parsed.get("error", {})
			if api_err is Dictionary:
				var formatted := format_openrouter_error(api_err, status)
				var has_msg := not str(api_err.get("message", "")).strip_edges().is_empty()
				var has_meta := not _metadata_detail(api_err.get("metadata", null)).is_empty()
				if has_msg or has_meta:
					err.message = formatted
				err.code = str(api_err.get("code", err.code))
			elif parsed.has("message"):
				err.message = "HTTP %d: %s" % [status, parsed.message]
		elif not body.is_empty() and status >= 500:
			err.message = "HTTP %d: %s" % [status, body.substr(0, 180)]
		if err.code.is_empty() and status > 0:
			err.code = str(status)
		return err


	## `error.message` plus provider name / raw from OpenRouter metadata.
	static func format_openrouter_error(api_err: Dictionary, status: int = 0) -> String:
		var api_msg := str(api_err.get("message", "")).strip_edges()
		var detail := _metadata_detail(api_err.get("metadata", null))
		var head := api_msg
		if status > 0:
			head = "HTTP %d: %s" % [status, api_msg] if not api_msg.is_empty() else "HTTP %d" % status
		elif head.is_empty():
			head = "OpenRouter error"
		if detail.is_empty() or head.contains(detail):
			return head
		return "%s — %s" % [head, detail]


	## Provider name and unwrapped `metadata.raw` (Google/Anthropic payload).
	static func _metadata_detail(meta: Variant) -> String:
		if meta == null:
			return ""
		if not meta is Dictionary:
			return _clip_error_text(str(meta))
		var provider := str(meta.get("provider_name", meta.get("provider", ""))).strip_edges()
		var raw_text := _unwrap_provider_raw(meta.get("raw", meta.get("message", "")))
		if provider.is_empty():
			return raw_text
		if raw_text.is_empty():
			return provider
		return "%s: %s" % [provider, raw_text]


	## Pull a readable message out of metadata.raw (string, JSON, or nested error).
	static func _unwrap_provider_raw(raw: Variant) -> String:
		if raw == null:
			return ""
		if raw is Dictionary:
			var nested = raw.get("error", null)
			if nested is Dictionary:
				var inner := str(nested.get("message", "")).strip_edges()
				if not inner.is_empty():
					return _clip_error_text(inner)
			var msg := str(raw.get("message", "")).strip_edges()
			if not msg.is_empty():
				return _clip_error_text(msg)
			return _clip_error_text(JSON.stringify(raw))
		var s := str(raw).strip_edges()
		if s.is_empty():
			return ""
		var parsed = JSON.parse_string(s)
		if parsed != null:
			return _unwrap_provider_raw(parsed)
		return _clip_error_text(s)


	## Collapse whitespace and cap length for logs / UI.
	static func _clip_error_text(text: String) -> String:
		var s := text.strip_edges().replace("\n", " ").replace("\r", " ")
		while s.contains("  "):
			s = s.replace("  ", " ")
		if s.length() > 800:
			return s.substr(0, 800) + "…"
		return s


	## Model rejected a requested modality.
	static func unsupported_modality(detail: String) -> ChatError:
		var err := ChatError.new()
		err.code = "unsupported_modality"
		err.message = detail
		return err


	## Truncated or invalid SSE payload.
	static func parse_failure(detail: String) -> ChatError:
		var err := ChatError.new()
		err.code = "parse"
		err.message = detail
		return err


	func _to_string() -> String:
		return message
