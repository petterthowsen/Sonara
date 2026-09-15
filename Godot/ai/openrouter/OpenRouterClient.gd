# OpenRouterClient.gd
# First-party OpenRouter transport: Chat Completions over HTTPClient SSE + HTTPRequest for /models.
class_name OpenRouterClient extends Node


signal request_started()
signal text_delta(text: String)
signal reasoning_delta(text: String)
signal audio_delta(b64_chunk: String, transcript: String)
signal image_delta(part: ChatTypes.ORContentPart)
signal tool_calls_ready(calls: Array)
signal message_finished(message: ChatTypes.ORChatMessage)
signal request_failed(error: ChatTypes.ORChatError)
signal request_cancelled()


const APP_REFERER := "https://sonara.app"
const APP_TITLE := "Sonara"
## Takes precedence over the key stored in config.json.
const API_KEY_ENV := "OPENROUTER_API_KEY"

var logger := Log.make("OpenRouterClient")

var _http := HTTPClient.new()
var _sse := OpenRouterSse.new()
var _models_http: HTTPRequest

var _api_key: String = ""
var _base_url: String = "https://openrouter.ai/api/v1"
var _default_model: String = "anthropic/claude-sonnet-4.5"
var _temperature: float = 0.7
var _max_tokens: int = 4096
var _voice: String = "alloy"
var _audio_format: String = "wav"

var _host: String = ""
var _port: int = 443
var _use_tls: bool = true
var _api_path: String = "/api/v1"
var _model_caps: Dictionary = {}

var _in_flight: bool = false
var _request_sent: bool = false
var _headers_seen: bool = false
var _streaming: bool = true
var _request_path: String = ""
var _request_body: String = ""
var _response_code: int = 0
var _error_body := PackedByteArray()
var _plain_body := PackedByteArray()

var _text: String = ""
var _reasoning: String = ""
var _finish_reason: String = ""
var _audio_b64: String = ""
var _audio_transcript: String = ""
var _images: Array = []
var _tool_acc: Dictionary = {}


## Wire Settings and keep process off until a request starts.
func _ready() -> void:
	_http.set_read_chunk_size(64 * 1024)
	var settings := get_node_or_null("/root/Settings")
	if settings:
		if not settings.setting_changed.is_connected(_on_setting_changed):
			settings.setting_changed.connect(_on_setting_changed)
	configure_from_settings()
	set_process(false)


## Read key, base URL, model, and sampling from Settings.
func configure_from_settings() -> void:
	var settings := get_node_or_null("/root/Settings")
	if settings == null:
		return
	var env_key := OS.get_environment(API_KEY_ENV).strip_edges()
	_api_key = env_key if not env_key.is_empty() else str(settings.call("get_value", "ai/openrouter/api_key"))
	var base_url := str(settings.call("get_value", "ai/openrouter/base_url")).rstrip("/")
	if base_url != _base_url or _host.is_empty():
		_warn_if_insecure(base_url)
	_base_url = base_url
	_default_model = str(settings.call("get_value", "ai/openrouter/model"))
	_temperature = float(settings.call("get_value", "ai/chat/temperature"))
	_max_tokens = int(settings.call("get_value", "ai/chat/max_tokens"))
	_voice = str(settings.call("get_value", "ai/audio/voice"))
	_audio_format = str(settings.call("get_value", "ai/audio/format"))
	_parse_base_url(_base_url)


## True when a non-empty API key is configured.
func has_api_key() -> bool:
	return not _api_key.strip_edges().is_empty()


## Cached architecture for a model id after list_models(), or {}.
func get_model_capabilities(model_id: String) -> Dictionary:
	return _model_caps.get(model_id, {})


## GET /models (non-stream). Caches input/output modalities. Returns the data array.
func list_models(output_modalities: String = "all") -> Array:
	configure_from_settings()
	if not has_api_key():
		return []
	if _models_http == null:
		_models_http = HTTPRequest.new()
		add_child(_models_http)
	var url := "%s/models?output_modalities=%s" % [_base_url, output_modalities]
	var err := _models_http.request(url, _headers(false), HTTPClient.METHOD_GET)
	if err != OK:
		push_warning("[OpenRouter] list_models request failed to start")
		return []
	var completed: Array = await _models_http.request_completed
	var result: int = completed[0]
	var code: int = completed[1]
	var body: PackedByteArray = completed[3]
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("[OpenRouter] list_models HTTP %d" % code)
		return []
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Dictionary:
		return []
	var data = parsed.get("data", [])
	if data is Array:
		_cache_model_caps(data)
		return data
	return []


## Start a chat completion. A second call cancels the first. Stream defaults on.
func chat(request: ChatTypes.ORChatRequest) -> void:
	if _in_flight:
		cancel()
	configure_from_settings()
	if not has_api_key():
		request_failed.emit(ChatTypes.ORChatError.missing_key())
		return
	_apply_request_defaults(request)
	var cap_err := _check_modalities(request)
	if cap_err:
		request_failed.emit(cap_err)
		return
	_reset_accumulator()
	_streaming = request.stream
	_request_path = _api_path + "/chat/completions"
	_request_body = JSON.stringify(request.to_openrouter())
	_log_request(request)
	var tls: TLSOptions = TLSOptions.client() if _use_tls else null
	var err := _http.connect_to_host(_host, _port, tls)
	if err != OK:
		request_failed.emit(ChatTypes.ORChatError.from_connect(0, "TLS / connect failed: %s" % error_string(err)))
		return
	_in_flight = true
	_request_sent = false
	set_process(true)
	request_started.emit()


## Disconnect the in-flight HTTPClient stream without executing leftover tools.
func cancel() -> void:
	if not _in_flight:
		return
	_close_http()
	request_cancelled.emit()


## One-shot ping used by AI → Test Connection. Prints nothing about the key.
func test_connection() -> void:
	var req := ChatTypes.ORChatRequest.new()
	req.messages = [ChatTypes.ORChatMessage.user_text("Reply with the word pong")]
	req.stream = true
	req.modalities = PackedStringArray(["text"])
	chat(req)


## Poll HTTPClient until the stream finishes or fails.
func _process(_delta: float) -> void:
	if not _in_flight:
		set_process(false)
		return
	_http.poll()
	var status := _http.get_status()
	match status:
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_REQUESTING:
			return
		HTTPClient.STATUS_CONNECTED:
			if not _request_sent:
				_send_request()
			elif _headers_seen:
				_finish_body()
		HTTPClient.STATUS_BODY:
			_read_body()
		HTTPClient.STATUS_CANT_RESOLVE:
			_fail(ChatTypes.ORChatError.from_connect(status, "DNS lookup failed for %s." % _host))
		HTTPClient.STATUS_CANT_CONNECT:
			_fail(ChatTypes.ORChatError.from_connect(status, "Could not connect to %s:%d." % [_host, _port]))
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_fail(ChatTypes.ORChatError.from_connect(status, "TLS handshake failed for %s." % _host))
		HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_DISCONNECTED:
			if _headers_seen and _response_code >= 200 and _response_code < 300:
				_finish_body()
			elif _in_flight:
				_fail(ChatTypes.ORChatError.from_connect(status, "Connection lost."))
		_:
			_fail(ChatTypes.ORChatError.from_connect(status, "Unexpected HTTP status %d." % status))


## POST the pending chat body once the socket is connected.
func _send_request() -> void:
	var err := _http.request(HTTPClient.METHOD_POST, _request_path, _headers(true), _request_body)
	if err != OK:
		_fail(ChatTypes.ORChatError.from_connect(0, "HTTP request() failed: %s" % error_string(err)))
		return
	_request_sent = true


## Read one body chunk: error JSON, SSE events, or a non-stream buffer.
func _read_body() -> void:
	if not _headers_seen:
		if not _http.has_response():
			return
		_response_code = _http.get_response_code()
		_headers_seen = true
		logger.info("response HTTP %d stream=%s" % [_response_code, _streaming])
	var chunk := _http.read_response_body_chunk()
	if chunk.is_empty():
		return
	if _response_code < 200 or _response_code >= 300:
		_error_body.append_array(chunk)
		return
	if _streaming:
		_ingest_sse(chunk)
	else:
		_plain_body.append_array(chunk)


## Feed bytes to the SSE parser and finish when [DONE] arrives.
func _ingest_sse(chunk: PackedByteArray) -> void:
	var events := _sse.feed(chunk)
	for payload in events:
		_handle_sse_payload(payload)
	if _sse.is_done():
		_finish_body()


## Merge one SSE JSON object into text / audio / image / tool-call state.
func _handle_sse_payload(payload: String) -> void:
	var parsed = JSON.parse_string(payload)
	if parsed == null:
		_fail(ChatTypes.ORChatError.parse_failure("Invalid JSON chunk in SSE stream."))
		return
	if not parsed is Dictionary:
		return
	var delta := ChatTypes.ORChatDelta.from_openrouter_chunk(parsed)
	if not delta.error_message.is_empty():
		var err := ChatTypes.ORChatError.new()
		err.message = delta.error_message
		err.code = delta.error_code
		_fail(err)
		return
	if not delta.text.is_empty():
		_text += delta.text
		text_delta.emit(delta.text)
	if not delta.reasoning.is_empty():
		_reasoning += delta.reasoning
		reasoning_delta.emit(delta.reasoning)
	if not delta.audio_b64.is_empty() or not delta.audio_transcript.is_empty():
		_audio_b64 += delta.audio_b64
		_audio_transcript += delta.audio_transcript
		audio_delta.emit(delta.audio_b64, delta.audio_transcript)
	if delta.image_part:
		_images.append(delta.image_part)
		image_delta.emit(delta.image_part)
	for frag in delta.tool_call_fragments:
		_merge_tool_fragment(frag)
	if not delta.finish_reason.is_empty() and delta.finish_reason != "<null>":
		_finish_reason = delta.finish_reason


## Append a streaming tool-call delta into `_tool_acc` by index.
func _merge_tool_fragment(frag: Dictionary) -> void:
	var idx := int(frag.get("index", 0))
	if not _tool_acc.has(idx):
		_tool_acc[idx] = ChatTypes.ORToolCall.new()
	var tc: ChatTypes.ORToolCall = _tool_acc[idx]
	tc.merge_delta(frag)


## Emit the assembled assistant message, or a ChatError for non-2xx.
func _finish_body() -> void:
	if not _in_flight:
		return
	if _response_code < 200 or _response_code >= 300:
		var body_text := _error_body.get_string_from_utf8()
		if not body_text.is_empty():
			logger.error("error body: %s" % body_text.substr(0, 1500))
		_fail(ChatTypes.ORChatError.from_http(_response_code, body_text))
		return
	if not _streaming:
		_apply_plain_response(_plain_body.get_string_from_utf8())
		if not _in_flight:
			return
	var calls := _sorted_tool_calls()
	if not calls.is_empty():
		tool_calls_ready.emit(calls)
	var msg := ChatTypes.ORChatMessage.new()
	msg.role = "assistant"
	msg.content = _text
	msg.tool_calls = calls
	msg.finish_reason = _finish_reason
	msg.reasoning = _reasoning
	msg.audio_b64 = _audio_b64
	msg.audio_transcript = _audio_transcript
	if not _images.is_empty():
		var parts: Array = []
		if not _text.is_empty():
			parts.append(ChatTypes.ORContentPart.text_part(_text))
		for img in _images:
			parts.append(img)
		msg.content = parts
	_close_http()
	logger.info("finished reason=%s chars=%d tools=%d audio=%d" % [
		_finish_reason, _text.length(), calls.size(), _audio_b64.length()
	])
	message_finished.emit(msg)


## Parse a non-stream chat/completions JSON body into the accumulator.
func _apply_plain_response(text: String) -> void:
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		_fail(ChatTypes.ORChatError.parse_failure("Invalid JSON in non-stream response."))
		return
	if parsed.has("error"):
		_fail(ChatTypes.ORChatError.from_http(_response_code, text))
		return
	var choices = parsed.get("choices", [])
	if choices.is_empty() or not choices[0] is Dictionary:
		_fail(ChatTypes.ORChatError.parse_failure("Chat response had no choices."))
		return
	var choice: Dictionary = choices[0]
	_finish_reason = str(choice.get("finish_reason", ""))
	var raw_msg = choice.get("message", {})
	if raw_msg is Dictionary:
		var msg := ChatTypes.ORChatMessage.from_openrouter(raw_msg)
		_text = msg.get_text()
		_reasoning = msg.reasoning
		_tool_acc.clear()
		for i in range(msg.tool_calls.size()):
			_tool_acc[i] = msg.tool_calls[i]
		_audio_b64 = msg.audio_b64
		_audio_transcript = msg.audio_transcript


## Tool calls in index order with parsed JSON arguments.
func _sorted_tool_calls() -> Array:
	var keys: Array = _tool_acc.keys()
	keys.sort()
	var calls: Array = []
	for k in keys:
		var tc: ChatTypes.ORToolCall = _tool_acc[k]
		tc.parse_arguments()
		calls.append(tc)
	return calls


## Close the socket and emit request_failed. Never logs the API key.
func _fail(error: ChatTypes.ORChatError) -> void:
	if not _in_flight:
		return
	_close_http()
	logger.error("failed: %s" % error.message)
	request_failed.emit(error)


## Drop the in-flight connection and stop polling.
func _close_http() -> void:
	_http.close()
	_in_flight = false
	_request_sent = false
	set_process(false)


## Clear stream assembly state before a new chat().
func _reset_accumulator() -> void:
	_sse.reset()
	_text = ""
	_reasoning = ""
	_finish_reason = ""
	_audio_b64 = ""
	_audio_transcript = ""
	_images.clear()
	_tool_acc.clear()
	_error_body = PackedByteArray()
	_plain_body = PackedByteArray()
	_response_code = 0
	_headers_seen = false


## Fill model / sampling / audio from Settings when the request left them unset.
func _apply_request_defaults(request: ChatTypes.ORChatRequest) -> void:
	if request.model.is_empty():
		request.model = _default_model
	if request.temperature < 0.0:
		request.temperature = _temperature
	if request.max_tokens <= 0:
		request.max_tokens = _max_tokens
	if request.modalities.has("audio") and request.audio.is_empty():
		request.audio = {"voice": _voice, "format": _audio_format}
	if request.reasoning.is_empty():
		var settings := get_node_or_null("/root/Settings")
		if settings and bool(settings.call("get_value", "ai/chat/reasoning")):
			var effort := str(settings.call("get_value", "ai/chat/reasoning_effort"))
			if effort.is_empty():
				effort = "medium"
			request.reasoning = {"enabled": true, "effort": effort}


## Refuse image/audio the cached model cannot take or emit. Null if unknown.
func _check_modalities(request: ChatTypes.ORChatRequest) -> ChatTypes.ORChatError:
	var caps = _model_caps.get(request.model, null)
	if caps == null:
		return null
	var inputs: Array = caps.get("input", [])
	var outputs: Array = caps.get("output", [])
	if request.has_image_input() and not inputs.has("image"):
		return ChatTypes.ORChatError.unsupported_modality("Model does not accept image input: %s" % request.model)
	if request.has_audio_input() and not inputs.has("audio"):
		return ChatTypes.ORChatError.unsupported_modality("Model does not accept audio input: %s" % request.model)
	for mod in request.modalities:
		if mod != "text" and not outputs.has(mod):
			return ChatTypes.ORChatError.unsupported_modality("Model does not output %s: %s" % [mod, request.model])
	return null


## Auth and attribution headers. Caller must not print this array.
func _headers(include_json: bool) -> PackedStringArray:
	var h := PackedStringArray([
		"Authorization: Bearer %s" % _api_key,
		"HTTP-Referer: %s" % APP_REFERER,
		"X-Title: %s" % APP_TITLE,
	])
	if include_json:
		h.append("Content-Type: application/json")
	return h


## Split base URL into host, port, path, and TLS flag.
func _parse_base_url(url: String) -> void:
	_use_tls = url.begins_with("https://")
	var rest := url.trim_prefix("https://").trim_prefix("http://")
	var slash := rest.find("/")
	var host_port := rest if slash < 0 else rest.substr(0, slash)
	_api_path = "" if slash < 0 else rest.substr(slash)
	if _api_path.ends_with("/"):
		_api_path = _api_path.substr(0, _api_path.length() - 1)
	_port = 443 if _use_tls else 80
	if ":" in host_port:
		var bits := host_port.split(":")
		_host = bits[0]
		_port = int(bits[1])
	else:
		_host = host_port


## Warn when the API key would be sent unencrypted to a host other than localhost.
func _warn_if_insecure(url: String) -> void:
	if not url.begins_with("http://"):
		return
	var host := url.trim_prefix("http://").get_slice("/", 0)
	if host.begins_with("["):
		host = host.get_slice("]", 0).trim_prefix("[")
	else:
		host = host.get_slice(":", 0)
	if host in ["localhost", "127.0.0.1", "::1"] or host.begins_with("127."):
		return
	push_warning("[OpenRouter] base_url %s is not HTTPS; the API key will be sent unencrypted" % url)


## Store architecture.input/output_modalities from GET /models.
func _cache_model_caps(data: Array) -> void:
	for item in data:
		if not item is Dictionary:
			continue
		var id := str(item.get("id", ""))
		if id.is_empty():
			continue
		var arch = item.get("architecture", {})
		var inputs: Array = []
		var outputs: Array = []
		if arch is Dictionary:
			inputs = arch.get("input_modalities", [])
			outputs = arch.get("output_modalities", [])
		_model_caps[id] = {"input": inputs, "output": outputs}


## Log model and part counts only — never the key or media payloads.
func _log_request(request: ChatTypes.ORChatRequest) -> void:
	var image_n := 0
	var audio_n := 0
	for msg in request.messages:
		if not msg is ChatTypes.ORChatMessage or not msg.content is Array:
			continue
		for part in msg.content:
			if part is ChatTypes.ORContentPart and part.kind == "image_url":
				image_n += 1
			elif part is ChatTypes.ORContentPart and part.kind == "input_audio":
				audio_n += 1
	logger.info("chat model=%s stream=%s modalities=%s messages=%d images=%d audio_parts=%d" % [
		request.model, request.stream, ",".join(request.modalities),
		request.messages.size(), image_n, audio_n
	])


## Rebuild host/headers when AI settings change.
func _on_setting_changed(key: String, _value) -> void:
	if key.begins_with("ai/openrouter/") or key.begins_with("ai/chat/") or key.begins_with("ai/audio/"):
		configure_from_settings()
