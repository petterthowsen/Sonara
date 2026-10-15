## What this build is: version, git commit, release channel and install folder (spec 046).
##
## Exported builds read `res://build_info.json`, which `scripts/stamp_version.sh` writes before
## export (Godot can't read the root VERSION file once exported). A dev run reads `../VERSION`
## next to the project folder and reports the commit as "dev".
##
## Static, with no autoload dependencies, so it works from tests and early startup.
class_name BuildInfo extends RefCounted

## OSC protocol number. Keep in step with `build_info::PROTOCOL` in Engine/src/build_info.rs and
## bump it on any incompatible OSC change.
const PROTOCOL := 1

const BUILD_INFO_PATH := "res://build_info.json"
const DEV_COMMIT := "dev"
const UNKNOWN_VERSION := "unknown"

const CHANNEL_GITHUB := "github"
const CHANNEL_ITCH := "itch"
const CHANNEL_DEV := "dev"
## File next to the executable that names the release channel.
const CHANNEL_FILE := "channel"

static var _info: Dictionary = {}
static var _loaded := false


## Release version, e.g. "0.1.0-beta.1".
static func version() -> String:
	_load()
	return str(_info.get("version", UNKNOWN_VERSION))


## Short git hash this build was made from, or "dev" for a run from a source checkout.
static func commit() -> String:
	_load()
	return str(_info.get("commit", DEV_COMMIT))


## "github", "itch" or "dev". Development runs (the editor binary) are always "dev"; an export
## reads the `channel` file next to the executable, and a missing or unknown file means "dev".
static func channel() -> String:
	if OS.has_feature("editor"):
		return CHANNEL_DEV
	return channel_from_dir(OS.get_executable_path().get_base_dir())


## The channel named by the `channel` file in `dir`.
static func channel_from_dir(dir: String) -> String:
	var path := dir.path_join(CHANNEL_FILE)
	if not FileAccess.file_exists(path):
		return CHANNEL_DEV
	var value := FileAccess.get_file_as_string(path).strip_edges().to_lower()
	if value == CHANNEL_GITHUB or value == CHANNEL_ITCH:
		return value
	return CHANNEL_DEV


## Where the license files live: next to the executable in an install, the repo root in dev.
static func install_dir() -> String:
	if OS.has_feature("editor"):
		return _project_dir().path_join("..").simplify_path()
	return OS.get_executable_path().get_base_dir()


## "0.1.0-beta.1 (380d9b0)" for the UI, About and logs.
static func display_string() -> String:
	return "%s (%s)" % [version(), commit()]


## Forget the cached info (tests).
static func reset() -> void:
	_info = {}
	_loaded = false


static func _project_dir() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/")


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_info = {"version": UNKNOWN_VERSION, "commit": DEV_COMMIT}
	if FileAccess.file_exists(BUILD_INFO_PATH):
		var parsed := parse_build_info(FileAccess.get_file_as_string(BUILD_INFO_PATH))
		if not parsed.is_empty():
			_info = parsed
			return
	# Dev run: the VERSION file at the repo root, next to the Godot project folder.
	var version_file := _project_dir().path_join("../VERSION").simplify_path()
	if FileAccess.file_exists(version_file):
		var text := FileAccess.get_file_as_string(version_file).strip_edges()
		if not text.is_empty():
			_info = {"version": text, "commit": DEV_COMMIT}


## Parse the text of build_info.json. Returns {} unless it holds a non-empty string "version".
static func parse_build_info(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return {}
	var data = JSON.parse_string(text)
	if not (data is Dictionary):
		return {}
	var version_value = data.get("version")
	if not (version_value is String) or (version_value as String).strip_edges().is_empty():
		return {}
	var commit_value = data.get("commit", DEV_COMMIT)
	if not (commit_value is String) or (commit_value as String).is_empty():
		commit_value = DEV_COMMIT
	return {"version": (version_value as String).strip_edges(), "commit": commit_value}


## Compare two semantic versions: -1 if a < b, 0 if equal, 1 if a > b. A leading "v" and
## "+build" metadata are ignored. A prerelease sorts before its release
## (0.1.0-beta.1 < 0.1.0-beta.2 < 0.1.0 < 0.1.1); numeric prerelease identifiers compare as
## numbers and sort before alphanumeric ones.
static func compare_versions(a: String, b: String) -> int:
	var pa := _split_version(a)
	var pb := _split_version(b)
	var core_a: Array = pa[0]
	var core_b: Array = pb[0]
	for i in range(3):
		if core_a[i] != core_b[i]:
			return -1 if core_a[i] < core_b[i] else 1
	var pre_a: Array = pa[1]
	var pre_b: Array = pb[1]
	if pre_a.is_empty() and pre_b.is_empty():
		return 0
	if pre_a.is_empty():
		return 1
	if pre_b.is_empty():
		return -1
	for i in range(mini(pre_a.size(), pre_b.size())):
		var x: String = pre_a[i]
		var y: String = pre_b[i]
		if x == y:
			continue
		var x_num := x.is_valid_int()
		var y_num := y.is_valid_int()
		if x_num and y_num:
			return -1 if x.to_int() < y.to_int() else 1
		if x_num != y_num:
			return -1 if x_num else 1
		return -1 if x < y else 1
	if pre_a.size() == pre_b.size():
		return 0
	return -1 if pre_a.size() < pre_b.size() else 1


## [[major, minor, patch], [prerelease identifiers]]. Missing or malformed numbers count as 0.
static func _split_version(v: String) -> Array:
	var text := v.strip_edges().trim_prefix("v").trim_prefix("V")
	var plus := text.find("+")
	if plus >= 0:
		text = text.substr(0, plus)
	var prerelease: Array = []
	var dash := text.find("-")
	if dash >= 0:
		for part in text.substr(dash + 1).split(".", false):
			prerelease.append(part)
		text = text.substr(0, dash)
	var core: Array = [0, 0, 0]
	var parts := text.split(".")
	for i in range(mini(3, parts.size())):
		core[i] = parts[i].to_int() if parts[i].is_valid_int() else 0
	return [core, prerelease]
