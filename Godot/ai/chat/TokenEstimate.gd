# TokenEstimate.gd
# Rough token counts for text the provider has not reported usage for yet.
class_name TokenEstimate extends RefCounted


## Average characters per token for English prose and JSON on current BPE tokenizers.
const CHARS_PER_TOKEN := 4.0
## Per-message framing overhead (role markers, separators).
const MESSAGE_OVERHEAD := 4


## Estimated tokens for a string.
static func text(value: String) -> int:
	if value.is_empty():
		return 0
	return int(ceil(value.length() / CHARS_PER_TOKEN))


## Estimated tokens for one ORChatMessage (text, tool calls, reasoning excluded).
static func message(msg: ChatTypes.ORChatMessage) -> int:
	if msg == null:
		return 0
	var n := MESSAGE_OVERHEAD + text(msg.get_text()) + text(msg.get_context_text())
	for tc in msg.tool_calls:
		if tc is ChatTypes.ORToolCall:
			n += text(tc.name) + text(tc.arguments_raw if not tc.arguments_raw.is_empty() else JSON.stringify(tc.arguments))
	return n


## Estimated tokens for an array of ORChatMessage.
static func messages(msgs: Array) -> int:
	var n := 0
	for msg in msgs:
		if msg is ChatTypes.ORChatMessage:
			n += message(msg)
	return n


## Compact label: 950, 12.4k, 1.2M.
static func format_count(n: int) -> String:
	if n < 1000:
		return str(n)
	if n < 1000000:
		return ("%.1fk" % (n / 1000.0)).replace(".0k", "k")
	return ("%.1fM" % (n / 1000000.0)).replace(".0M", "M")
