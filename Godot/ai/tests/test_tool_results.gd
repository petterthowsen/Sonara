# test_tool_results.gd
# Headless tests for AiTool.ok_text / to_model_content.
# Run: godot --headless --path Godot -s ai/tests/test_tool_results.gd -- --test
#
# AiTool.gd references the Sonara autoload by bare name. That identifier only
# resolves once the engine has processed a frame, so this suite loads the
# script dynamically (via `load()`, after TestBase's startup wait) instead of
# referencing the `AiTool` class name, which the compiler would otherwise try
# to resolve while parsing this file, before any frame has run.
extends TestBase

var _ai_tool: GDScript


func suite_name() -> String:
	return "Tool result tests"


func run_tests() -> void:
	_ai_tool = load("res://ai/tools/AiTool.gd")
	_test_fail()
	_test_ok_text()
	_test_legacy_dict()


func _test_fail() -> void:
	var result: Dictionary = _ai_tool.fail("Track not found: 5")
	_assert(_ai_tool.to_model_content(result) == "Error: Track not found: 5", "fail becomes Error: message")


func _test_ok_text() -> void:
	var result: Dictionary = _ai_tool.ok_text("Created bus \"Strings\" (channel 14)", {"channel_id": 14})
	_assert(_ai_tool.to_model_content(result) == "Created bus \"Strings\" (channel 14)", "ok_text returns text")
	_assert(result.data.get("channel_id") == 14, "data is kept for tests/UI")


func _test_legacy_dict() -> void:
	var result: Dictionary = _ai_tool.ok({"id": 1, "name": "Delay"})
	var content: String = _ai_tool.to_model_content(result)
	_assert(content == JSON.stringify(result), "legacy ok() dict falls back to JSON")
	_assert(JSON.parse_string(content) != null, "legacy result is still valid JSON")
