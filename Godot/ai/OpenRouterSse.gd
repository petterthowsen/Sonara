# OpenRouterSse.gd
# Incremental SSE line parser for OpenRouter chat streams.
class_name OpenRouterSse extends RefCounted


signal event_received(payload: String)
signal done()
signal parse_error(message: String)


var _buffer: String = ""
var _finished: bool = false


## True after `data: [DONE]` (or reset).
func is_done() -> bool:
	return _finished


## Clear buffer and done flag so the parser can be reused.
func reset() -> void:
	_buffer = ""
	_finished = false


## Feed UTF-8 bytes; returns newly completed `data:` payloads (not including [DONE]).
func feed(bytes: PackedByteArray) -> PackedStringArray:
	if _finished or bytes.is_empty():
		return PackedStringArray()
	return feed_text(bytes.get_string_from_utf8())


## Feed a UTF-8 string (tests and callers that already decoded).
func feed_text(text: String) -> PackedStringArray:
	if _finished or text.is_empty():
		return PackedStringArray()
	_buffer += text
	return _drain()


## Split complete lines out of `_buffer` and emit payloads.
func _drain() -> PackedStringArray:
	var events: PackedStringArray = []
	while not _finished:
		var nl := _buffer.find("\n")
		if nl < 0:
			break
		var line := _buffer.substr(0, nl)
		_buffer = _buffer.substr(nl + 1)
		if line.ends_with("\r"):
			line = line.substr(0, line.length() - 1)
		var payload: Variant = _line_payload(line)
		if payload == null:
			continue
		if str(payload) == "[DONE]":
			_finished = true
			done.emit()
			break
		var text := str(payload)
		events.append(text)
		event_received.emit(text)
	return events


## Return the data payload, or null to ignore the line.
func _line_payload(line: String) -> Variant:
	if line.is_empty():
		return null
	if line.begins_with(":"):
		return null
	if not line.begins_with("data:"):
		return null
	return line.substr(5).strip_edges()
