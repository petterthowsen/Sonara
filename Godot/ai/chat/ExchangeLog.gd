# ExchangeLog.gd
# Request/response records for debugging, one JSON file per OpenRouter call:
# `<conversation dir>/exchanges/<conversation id>/<exchange id>.json`.
class_name ExchangeLog extends RefCounted


const DIR_NAME := "exchanges"
## Inline media longer than this is replaced by a size note on write.
const MEDIA_KEEP_CHARS := 256


## New `ex_<unix>_<hex>` id; sorts chronologically by name.
static func new_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "ex_%d_%06x" % [int(Time.get_unix_time_from_system()), rng.randi() & 0xffffff]


## Write `record` (from OpenRouterClient.get_last_exchange) under `dir` as `id`, then keep the newest `keep`.
## Returns the file path, or "" when nothing was written.
static func write(dir: String, id: String, conversation_id: String, record: Dictionary, keep: int) -> String:
	if dir.is_empty() or id.is_empty() or record.is_empty() or keep <= 0:
		return ""
	DirAccess.make_dir_recursive_absolute(dir)
	var out := record.duplicate()
	out["id"] = id
	out["conversation_id"] = conversation_id
	out["request"] = redact_request(record.get("request", {}))
	var path := dir.path_join("%s.json" % id)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[ExchangeLog] Could not write %s" % path)
		return ""
	file.store_string(JSON.stringify(out, "\t"))
	file.close()
	prune(dir, keep)
	return path


## Load one record, or {} if missing / invalid.
static func read(dir: String, id: String) -> Dictionary:
	var path := dir.path_join("%s.json" % id)
	if dir.is_empty() or id.is_empty() or not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## Delete the oldest records so at most `keep` remain.
static func prune(dir: String, keep: int) -> void:
	var names := list_ids(dir)
	var excess := names.size() - maxi(keep, 0)
	for i in range(excess):
		DirAccess.remove_absolute(dir.path_join("%s.json" % names[i]))


## Record ids in `dir`, oldest first.
static func list_ids(dir: String) -> PackedStringArray:
	var ids: PackedStringArray = []
	if dir.is_empty() or not DirAccess.dir_exists_absolute(dir):
		return ids
	for name in DirAccess.get_files_at(dir):
		if name.begins_with("ex_") and name.ends_with(".json"):
			ids.append(name.get_basename())
	ids.sort()
	return ids


## Copy of a request body with image data URIs and input audio replaced by size notes.
static func redact_request(body: Dictionary) -> Dictionary:
	var out := body.duplicate(true)
	var msgs = out.get("messages", [])
	if not msgs is Array:
		return out
	for msg in msgs:
		if not msg is Dictionary or not msg.get("content", null) is Array:
			continue
		for part in msg.content:
			if not part is Dictionary:
				continue
			var img = part.get("image_url", null)
			if img is Dictionary:
				img["url"] = _redact_media(str(img.get("url", "")))
			var aud = part.get("input_audio", null)
			if aud is Dictionary:
				aud["data"] = _redact_media(str(aud.get("data", "")))
	return out


static func _redact_media(value: String) -> String:
	if value.length() <= MEDIA_KEEP_CHARS:
		return value
	var head := value.substr(0, value.find(",") + 1) if value.begins_with("data:") else ""
	return "%s<%d chars omitted>" % [head, value.length() - head.length()]
