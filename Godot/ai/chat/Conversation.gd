# Conversation.gd
# One project-scoped chat thread (no system message).
class_name Conversation extends RefCounted


var id: String = ""
var title: String = ""
var created_unix: int = 0
var updated_unix: int = 0
var model: String = ""
var messages: Array = []
## Expanded system prompt from the last OpenRouter request in this thread.
var last_rendered_system_prompt: String = ""


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
		"last_rendered_system_prompt": last_rendered_system_prompt,
	}


## Restore from a conversation file.
static func from_storage(data: Dictionary) -> Conversation:
	var c := Conversation.new()
	c.id = str(data.get("id", ""))
	c.title = str(data.get("title", ""))
	c.created_unix = int(data.get("created_unix", 0))
	c.updated_unix = int(data.get("updated_unix", 0))
	c.model = str(data.get("model", ""))
	c.last_rendered_system_prompt = str(data.get("last_rendered_system_prompt", ""))
	for item in data.get("messages", []):
		if item is Dictionary:
			c.messages.append(ChatTypes.ORChatMessage.from_storage(item))
	return c


## Touch updated time (and optional model id).
func touch(p_model: String = "") -> void:
	updated_unix = int(Time.get_unix_time_from_system())
	if not p_model.is_empty():
		model = p_model


## Token and cost totals. `context_tokens` is the size of the next request: the last reported
## prompt + completion, plus estimates for messages added since. Before any reported usage it is
## an estimate of the system prompt, messages, and `extra_estimate` (e.g. tool schemas).
func usage_summary(extra_estimate: int = 0) -> Dictionary:
	var summary := {
		"context_tokens": 0,
		"estimated": true,
		"requests": 0,
		"prompt_tokens": 0,
		"completion_tokens": 0,
		"cached_tokens": 0,
		"reasoning_tokens": 0,
		"cost": 0.0,
	}
	var last_idx := -1
	for i in range(messages.size()):
		var msg = messages[i]
		if not msg is ChatTypes.ORChatMessage or msg.usage.is_empty():
			continue
		var u: Dictionary = msg.usage
		summary.requests += 1
		summary.prompt_tokens += int(u.get("prompt_tokens", 0))
		summary.completion_tokens += int(u.get("completion_tokens", 0))
		summary.cost += float(u.get("cost", 0.0)) if u.get("cost", null) != null else 0.0
		if u.get("prompt_tokens_details", null) is Dictionary:
			summary.cached_tokens += int(u.prompt_tokens_details.get("cached_tokens", 0))
		if u.get("completion_tokens_details", null) is Dictionary:
			summary.reasoning_tokens += int(u.completion_tokens_details.get("reasoning_tokens", 0))
		if int(u.get("prompt_tokens", 0)) > 0:
			last_idx = i
	if last_idx >= 0:
		var last: Dictionary = messages[last_idx].usage
		var tail := TokenEstimate.messages(messages.slice(last_idx + 1))
		summary.context_tokens = int(last.get("prompt_tokens", 0)) + int(last.get("completion_tokens", 0)) + tail
		summary.estimated = tail > 0
	else:
		summary.context_tokens = TokenEstimate.text(last_rendered_system_prompt) + TokenEstimate.messages(messages) + extra_estimate
	return summary


const PLACEHOLDER_TITLE := "New chat"


## Set title from the first user line while it is still empty or the placeholder.
func ensure_title_from_first_user() -> void:
	if not title.is_empty() and title != PLACEHOLDER_TITLE:
		return
	for msg in messages:
		if msg is ChatTypes.ORChatMessage and msg.role == "user":
			var bits: PackedStringArray = msg.get_text().strip_edges().split("\n")
			var line: String = bits[0] if bits.size() > 0 else ""
			if line.length() > 40:
				line = line.substr(0, 40).strip_edges() + "…"
			title = line if not line.is_empty() else PLACEHOLDER_TITLE
			return
	if title.is_empty():
		title = PLACEHOLDER_TITLE


static func _hex_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%08x%04x" % [rng.randi(), rng.randi() & 0xffff]
