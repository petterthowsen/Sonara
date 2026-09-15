# test_fuzzy_match.gd
# Headless property tests for Utils.fuzzy_match. Replaces the stale
# test_scoring.gd deleted in the frontend architecture audit (§3.3), which
# asserted nothing and failed all its scenarios against the current scorer.
# Run: godot --headless --path Godot -s tests/test_fuzzy_match.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Utils.fuzzy_match tests"


func run_tests() -> void:
	_test_edge_cases()
	_test_exact_and_substring()
	_test_case_insensitive()
	_test_ordering()
	_test_multi_word()
	_test_no_match()


func _test_edge_cases() -> void:
	_assert(Utils.fuzzy_match("", "anything") == 1.0, "empty query matches everything perfectly")
	_assert(Utils.fuzzy_match("kick", "") == 0.0, "empty target never matches")


func _test_exact_and_substring() -> void:
	_assert(Utils.fuzzy_match("kick", "kick") == 1.0, "exact match scores 1.0")
	_assert(Utils.fuzzy_match("kick", "kick drum") > 0.0, "prefix substring matches")
	_assert(Utils.fuzzy_match("drum", "kick drum") > 0.0, "word-boundary substring matches")
	_assert(Utils.fuzzy_match("kick", "kick drum") > Utils.fuzzy_match("drum", "kick drum"),
		"match at start of string outscores mid-string match")


func _test_case_insensitive() -> void:
	_assert(Utils.fuzzy_match("KICK", "kick") == 1.0, "query case does not matter")
	_assert(Utils.fuzzy_match("kick", "KICK") == 1.0, "target case does not matter")


func _test_ordering() -> void:
	var exact := Utils.fuzzy_match("snare", "snare")
	var substring := Utils.fuzzy_match("snare", "snare drum 01")
	var fuzzy := Utils.fuzzy_match("snredrm", "snare drum 01")
	_assert(exact >= substring, "exact match scores at least as high as substring match")
	_assert(substring >= fuzzy or fuzzy == 0.0, "substring match outscores a weak fuzzy match")


func _test_multi_word() -> void:
	_assert(Utils.fuzzy_match("hi hat", "hi_hat_closed_01") > 0.0, "multi-word query matches on split words")
	_assert(Utils.fuzzy_match("kick snare", "kick drum") > 0.0, "partial multi-word match still scores above zero")


func _test_no_match() -> void:
	_assert(Utils.fuzzy_match("xyzzy", "kick drum") == 0.0, "unrelated query scores zero")
