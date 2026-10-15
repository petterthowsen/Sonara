# test_build_info.gd
# BuildInfo: version ordering, build_info.json parsing, the dev fallback and the channel file
# (spec 046 REQ-005, REQ-022).
# Run: godot --headless --path Godot -s tests/test_build_info.gd -- --test
extends TestBase


func suite_name() -> String:
	return "BuildInfo tests"


func run_tests() -> void:
	_test_compare_versions()
	_test_parse_build_info()
	_test_dev_fallback_reads_version_file()
	_test_channel_file()


func _test_compare_versions() -> void:
	var ordered := ["0.1.0-alpha", "0.1.0-beta.1", "0.1.0-beta.2", "0.1.0-beta.10", "0.1.0-rc.1", "0.1.0", "0.1.1", "0.2.0", "1.0.0"]
	for i in range(ordered.size() - 1):
		_assert(BuildInfo.compare_versions(ordered[i], ordered[i + 1]) == -1, "%s < %s" % [ordered[i], ordered[i + 1]])
		_assert(BuildInfo.compare_versions(ordered[i + 1], ordered[i]) == 1, "%s > %s" % [ordered[i + 1], ordered[i]])
	_assert(BuildInfo.compare_versions("0.1.0", "0.1.0") == 0, "equal versions compare 0")
	_assert(BuildInfo.compare_versions("v0.1.0", "0.1.0") == 0, "a leading v is ignored")
	_assert(BuildInfo.compare_versions("0.1.0+abc", "0.1.0+def") == 0, "build metadata is ignored")
	_assert(BuildInfo.compare_versions("0.1.0-beta.1", "0.1.0-beta.1.1") == -1, "a longer prerelease sorts after its prefix")
	_assert(BuildInfo.compare_versions("0.1.0-1", "0.1.0-beta") == -1, "numeric identifiers sort before alphanumeric")
	_assert(BuildInfo.compare_versions("garbage", "0.0.1") == -1, "garbage counts as 0.0.0")


func _test_parse_build_info() -> void:
	var ok := BuildInfo.parse_build_info('{"version": "0.1.0-beta.1", "commit": "380d9b0"}')
	_assert(ok.get("version") == "0.1.0-beta.1" and ok.get("commit") == "380d9b0", "build_info.json parses")
	var no_commit := BuildInfo.parse_build_info('{"version": "1.2.3"}')
	_assert(no_commit.get("commit") == BuildInfo.DEV_COMMIT, "a missing commit reads as dev")
	_assert(BuildInfo.parse_build_info("").is_empty(), "empty text is rejected")
	_assert(BuildInfo.parse_build_info("[1]").is_empty(), "non-object JSON is rejected")
	_assert(BuildInfo.parse_build_info('{"version": ""}').is_empty(), "an empty version is rejected")


func _test_dev_fallback_reads_version_file() -> void:
	BuildInfo.reset()
	var version_file := ProjectSettings.globalize_path("res://").path_join("../VERSION").simplify_path()
	var expected := FileAccess.get_file_as_string(version_file).strip_edges()
	_assert(not expected.is_empty(), "the VERSION file exists at the repo root")
	if FileAccess.file_exists(BuildInfo.BUILD_INFO_PATH):
		print("(build_info.json present: dev fallback not exercised)")
	else:
		_assert(BuildInfo.version() == expected, "a dev run reports the VERSION file's version")
		_assert(BuildInfo.commit() == BuildInfo.DEV_COMMIT, "a dev run reports commit dev")
	_assert(BuildInfo.channel() == BuildInfo.CHANNEL_DEV, "an editor-binary run is the dev channel")
	_assert(FileAccess.file_exists(BuildInfo.install_dir().path_join("LICENSE")), "install_dir() holds LICENSE in dev")


func _test_channel_file() -> void:
	var dir := OS.get_cache_dir().path_join("sonara_test_channel_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_assert(BuildInfo.channel_from_dir(dir) == BuildInfo.CHANNEL_DEV, "no channel file means dev")
	for pair in [["github\n", "github"], [" itch ", "itch"], ["GitHub", "github"], ["steam", "dev"], ["", "dev"]]:
		var f := FileAccess.open(dir.path_join("channel"), FileAccess.WRITE)
		f.store_string(pair[0])
		f.close()
		_assert(BuildInfo.channel_from_dir(dir) == pair[1], "channel file %s reads as %s" % [var_to_str(pair[0]), pair[1]])
	DirAccess.remove_absolute(dir.path_join("channel"))
	DirAccess.remove_absolute(dir)
