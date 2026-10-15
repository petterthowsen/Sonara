# test_update_checker.gd
# UpdateChecker: which release counts as newer, when a check is due, and that only "newer"
# raises the notice (spec 046 REQ-021, REQ-022).
# Run: godot --headless --path Godot -s tests/test_update_checker.gd -- --test
extends TestBase

## Loaded at runtime: the script names autoloads, which don't exist yet when this file compiles.
var _uc: GDScript


func suite_name() -> String:
	return "UpdateChecker tests"


func _rel(tag: String, draft := false, pre := false) -> Dictionary:
	return {"tag_name": tag, "draft": draft, "prerelease": pre, "html_url": "https://example.test/" + tag}


func run_tests() -> void:
	_uc = load("res://core/UpdateChecker.gd")
	_test_pick_newest()
	_test_due()
	_test_responses()


func _test_pick_newest() -> void:
	var cur := "0.1.0-beta.1"
	_assert(_uc.pick_newest([_rel("v0.1.0-beta.2", false, true), _rel("v0.1.0-beta.1")], cur).get("tag_name") == "v0.1.0-beta.2", "newer prerelease is picked")
	_assert(_uc.pick_newest([_rel("v0.1.0-beta.1")], cur).is_empty(), "same version is not an update")
	_assert(_uc.pick_newest([_rel("v0.0.9")], cur).is_empty(), "older version is not an update")
	_assert(_uc.pick_newest([_rel("v9.0.0", true)], cur).is_empty(), "drafts are ignored")
	_assert(_uc.pick_newest([_rel("v0.2.0"), _rel("v0.3.0"), _rel("v0.1.5")], cur).get("tag_name") == "v0.3.0", "the highest version wins, not the first")
	_assert(_uc.pick_newest([], cur).is_empty(), "an empty list has nothing newer")
	_assert(_uc.pick_newest([1, "x", {}, {"tag_name": 5}, {"tag_name": ""}], cur).is_empty(), "malformed entries are skipped")
	_assert(_uc.pick_newest([_rel("v0.1.0")], cur).get("tag_name") == "v0.1.0", "the release beats its own prerelease")


func _test_due() -> void:
	var day: int = _uc.CHECK_INTERVAL_SEC
	_assert(_uc.should_check("github", true, 0, 1000000), "github, enabled, never checked")
	_assert(not _uc.should_check("dev", true, 0, 1000000), "dev channel never checks")
	_assert(not _uc.should_check("itch", true, 0, 1000000), "itch channel never checks")
	_assert(not _uc.should_check("github", false, 0, 1000000), "setting off never checks")
	_assert(not _uc.should_check("github", true, 1000000 - day + 1, 1000000), "checked less than 24 h ago")
	_assert(_uc.should_check("github", true, 1000000 - day, 1000000), "checked 24 h ago")


func _test_responses() -> void:
	var checker = _uc.new()
	var notices := []
	checker.update_available.connect(func(r): notices.append(r["tag_name"]))
	var cur := BuildInfo.version()
	checker.handle_response(HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify([_rel("v99.0.0")]))
	_assert(notices == ["v99.0.0"], "newer shows the notice")
	checker.handle_response(HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify([_rel("v" + cur)]))
	checker.handle_response(HTTPRequest.RESULT_SUCCESS, 200, JSON.stringify([_rel("v0.0.1")]))
	checker.handle_response(HTTPRequest.RESULT_CANT_CONNECT, 0, "")
	checker.handle_response(HTTPRequest.RESULT_SUCCESS, 403, "{}")
	checker.handle_response(HTTPRequest.RESULT_SUCCESS, 200, "not json")
	checker.handle_response(HTTPRequest.RESULT_SUCCESS, 200, "")
	checker.handle_response(HTTPRequest.RESULT_SUCCESS, 200, '{"message": "rate limited"}')
	_assert(notices.size() == 1, "same, older, network error, HTTP error and bad JSON show nothing")
	checker.free()
