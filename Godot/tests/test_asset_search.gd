# test_asset_search.gd
# Headless tests for AssetSearch.rank_tokens (word matching used by the AI search_assets tool).
#
# Asset.gd and AssetSearch.gd reference the AssetService autoload by bare name,
# which only resolves once the engine has processed a frame. This suite loads
# both scripts dynamically (via `load()`, after TestBase's startup wait)
# instead of referencing the Asset/AssetSearch class names, which the compiler
# would otherwise try to resolve while parsing this file, before any frame has run.
#
# Run: godot --headless --path Godot -s tests/test_asset_search.gd -- --test
extends TestBase

var _asset_script: GDScript
var _search: GDScript


func suite_name() -> String:
	return "Asset search word-matching tests"


func run_tests() -> void:
	_asset_script = load("res://browser/Asset.gd")
	_search = load("res://browser/AssetSearch.gd")
	_test_vpo_sec_perf_matches()
	_test_vpo_performance_prefix_match()
	_test_strings_matches_folder()
	_test_shorter_name_ranks_first()
	_test_typo_fuzzy_match()


func _make_asset(rel_path: String, tags: Array[String] = [], favorite: bool = false, last_used: int = 0) -> Object:
	var a: Object = _asset_script.new()
	a.type = 3  # Asset.TYPE.SFZ
	a.path = "/libs/" + rel_path
	a.tags = tags
	a.favorite = favorite
	a.last_used = last_used
	return a


func _rel_path_of(asset: Object) -> String:
	return str(asset.path).trim_prefix("/libs/")


func _paths(results: Array[Dictionary]) -> Array[String]:
	var out: Array[String] = []
	for r in results:
		out.append(_rel_path_of(r.asset))
	return out


func _test_vpo_sec_perf_matches() -> void:
	var assets: Array = [
		_make_asset("SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz"),
		_make_asset("SFZ/VPO3/Brass/trumpet-SEC-PERF-staccato.sfz"),
		_make_asset("SFZ/VPO3/Strings/harp-KS-B7.sfz"),
	]
	var results: Array[Dictionary] = _search.rank_tokens(assets, "vpo sec perf", _rel_path_of)
	var paths := _paths(results)
	_assert("SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz" in paths, "vpo sec perf matches violin SEC-PERF")
	_assert("SFZ/VPO3/Brass/trumpet-SEC-PERF-staccato.sfz" in paths, "vpo sec perf matches trumpet SEC-PERF")
	_assert(not ("SFZ/VPO3/Strings/harp-KS-B7.sfz" in paths), "vpo sec perf does not match harp")


func _test_vpo_performance_prefix_match() -> void:
	var assets: Array = [
		_make_asset("SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz"),
		_make_asset("SFZ/VPO3/Strings/harp-KS-B7.sfz"),
	]
	var results: Array[Dictionary] = _search.rank_tokens(assets, "vpo performance", _rel_path_of)
	var paths := _paths(results)
	_assert("SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz" in paths, "'performance' prefix-matches 'perf'")
	_assert(not ("SFZ/VPO3/Strings/harp-KS-B7.sfz" in paths), "'performance' still excludes harp")


func _test_strings_matches_folder() -> void:
	var assets: Array = [
		_make_asset("SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz"),
		_make_asset("SFZ/VPO3/Strings/harp-KS-B7.sfz"),
		_make_asset("SFZ/VPO3/Brass/trumpet-SEC-PERF-staccato.sfz"),
	]
	var results: Array[Dictionary] = _search.rank_tokens(assets, "strings", _rel_path_of)
	_assert(results.size() == 2, "'strings' matches everything under Strings/, got %d" % results.size())


func _test_shorter_name_ranks_first() -> void:
	var assets: Array = [
		_make_asset("SFZ/VPO3/Strings/1st-violin-SEC-PERF-KS-C2.sfz"),
		_make_asset("SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz"),
	]
	var results: Array[Dictionary] = _search.rank_tokens(assets, "violin sec perf", _rel_path_of)
	_assert(results.size() == 2, "both violin files match")
	_assert(_rel_path_of(results[0].asset) == "SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz", "shorter name ranks first, got %s" % _rel_path_of(results[0].asset))


func _test_typo_fuzzy_match() -> void:
	var assets: Array = [
		_make_asset("SFZ/VPO3/Brass/trumpet-SEC-PERF-staccato.sfz"),
		_make_asset("SFZ/VPO3/Strings/harp-KS-B7.sfz"),
	]
	var results: Array[Dictionary] = _search.rank_tokens(assets, "trumpt", _rel_path_of)
	var paths := _paths(results)
	_assert("SFZ/VPO3/Brass/trumpet-SEC-PERF-staccato.sfz" in paths, "typo 'trumpt' still finds trumpet via fuzzy match")
