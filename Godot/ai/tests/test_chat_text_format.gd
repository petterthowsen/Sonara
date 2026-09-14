# test_chat_text_format.gd
# Run: godot --headless --path Godot -s ai/tests/test_chat_text_format.gd
extends SceneTree


var _failures: int = 0


func _init() -> void:
	print("=== ChatTextFormat tests ===")
	_test_escape_bbcode()
	_test_pretty_json()
	_test_json_highlights_keys()
	_test_message_inline_code()
	_test_message_fence()
	_test_message_bold()
	_test_message_link()
	_test_message_list()
	_test_message_heading()
	if _failures == 0:
		print("=== ALL PASSED ===")
	else:
		print("=== FAILED: %d ===" % _failures)
	quit(_failures)


func _assert(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		push_error("FAIL: " + msg)


func _test_escape_bbcode() -> void:
	_assert(
		ChatTextFormat.escape_bbcode("a [b]") == "a [lb]b[rb]",
		"brackets escaped"
	)


func _test_pretty_json() -> void:
	var compact := '{"a":1,"b":[2,3]}'
	var pretty := ChatTextFormat.pretty_json(compact)
	_assert(pretty.contains("\t"), "pretty JSON indents")
	_assert(JSON.parse_string(pretty) != null, "pretty JSON still parses")


func _test_json_highlights_keys() -> void:
	var bb := ChatTextFormat.json_to_bbcode('{"name":"clip"}')
	_assert(bb.contains("[color=#9ecfff]"), "JSON keys colored")
	_assert(bb.contains("[color=#a8e6a1]"), "JSON strings colored")
	_assert(bb.contains("[code]"), "JSON wrapped in code font")


func _test_message_inline_code() -> void:
	var bb := ChatTextFormat.message_to_bbcode("Use `foo` here")
	_assert(bb.contains("[code]"), "inline code uses code tag")
	_assert(bb.contains("foo"), "inline code preserved")
	_assert(not bb.contains("`"), "backticks removed")


func _test_message_fence() -> void:
	var bb := ChatTextFormat.message_to_bbcode("```gdscript\nvar x = 1\n```")
	_assert(bb.contains("var x = 1"), "fenced code body kept")
	_assert(bb.contains("[code]"), "fenced code uses code tag")


func _test_message_bold() -> void:
	var bb := ChatTextFormat.message_to_bbcode("Say **bold** word")
	_assert(bb.contains("[b]bold[/b]"), "bold markdown")


func _test_message_link() -> void:
	var bb := ChatTextFormat.message_to_bbcode("See [docs](https://example.com)")
	_assert(bb.contains("[url=https://example.com]"), "markdown link url")
	_assert(bb.contains("docs"), "markdown link label")


func _test_message_list() -> void:
	var bb := ChatTextFormat.message_to_bbcode("- one\n- two")
	_assert(bb.contains("[ul]"), "unordered list tag")
	_assert(bb.contains("one"), "list item one")
	_assert(bb.contains("two"), "list item two")


func _test_message_heading() -> void:
	var bb := ChatTextFormat.message_to_bbcode("## Title")
	_assert(bb.contains("[font_size=15]"), "h2 font size")
	_assert(bb.contains("[b]Title[/b]"), "heading bold")
