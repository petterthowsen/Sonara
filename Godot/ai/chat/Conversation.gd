# Conversation.gd
# One project-scoped chat thread (no system message).
class_name Conversation extends RefCounted


var id: String = ""
var title: String = ""
var created_unix: int = 0
var updated_unix: int = 0
var model: String = ""
var messages: Array = []


## New empty conversation with a `conv_` hex id.
static func create_new() -> Conversation:
	var c := Conversation.new()
	c.id = "conv_%s" % _hex_id()
	c.created_unix = int(Time.get_unix_time_from_system())
	c.updated_unix = c.created_unix
	return c


## Index.json entry (id / title / updated).
func to_index_entry() -> Dictionary:
	return {"id": id, "title": title, "updated_unix": updated_unix}


## Full conversation file payload.
func to_storage() -> Dictionary:
	var msgs: Array = []
	for msg in messages:
		if msg is ChatTypes.ORChatMessage:
			msgs.append(msg.to_storage())
	return {
		"id": id,
		"title": title,
		"created_unix": created_unix,
		"updated_unix": updated_unix,
		"model": model,
		"messages": msgs,
	}


## Restore from a conversation file.
static func from_storage(data: Dictionary) -> Conversation:
	var c := Conversation.new()
	c.id = str(data.get("id", ""))
	c.title = str(data.get("title", ""))
	c.created_unix = int(data.get("created_unix", 0))
	c.updated_unix = int(data.get("updated_unix", 0))
	c.model = str(data.get("model", ""))
	for item in data.get("messages", []):
		if item is Dictionary:
			c.messages.append(ChatTypes.ORChatMessage.from_storage(item))
	return c


## Touch updated time (and optional model id).
func touch(p_model: String = "") -> void:
	updated_unix = int(Time.get_unix_time_from_system())
	if not p_model.is_empty():
		model = p_model


## Set title from the first user line if still empty.
func ensure_title_from_first_user() -> void:
	if not title.is_empty():
		return
	for msg in messages:
		if msg is ChatTypes.ORChatMessage and msg.role == "user":
			var bits: PackedStringArray = msg.get_text().strip_edges().split("\n")
			var line: String = bits[0] if bits.size() > 0 else ""
			if line.length() > 40:
				line = line.substr(0, 40).strip_edges() + "…"
			title = line if not line.is_empty() else "New chat"
			return
	if title.is_empty():
		title = "New chat"


static func _hex_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%08x%04x" % [rng.randi(), rng.randi() & 0xffff]
