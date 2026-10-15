# UpdateChecker.gd
# Asks GitHub for the release list at startup and shows a non-blocking notice when a newer
# version exists (spec 046 REQ-021, REQ-022). Notifies only; there is no in-app updater.
#
# Runs only in builds from the GitHub release channel, when the `updates/check_enabled` setting
# is on and the last check is more than 24 h old. Dev runs and itch.io builds never send a
# request. Failures are logged at INFO and show nothing.
class_name UpdateChecker extends Node

signal update_available(release: Dictionary)

const RELEASES_URL := "https://api.github.com/repos/petterthowsen/Sonara/releases?per_page=10"
const SETTING_ENABLED := "updates/check_enabled"
const CONFIG_LAST_CHECK := "updates/last_check_unix"
const CHECK_INTERVAL_SEC := 24 * 60 * 60
const REQUEST_TIMEOUT_SEC := 15.0

var logger := Log.make("UpdateChecker")
var _request: HTTPRequest


## Starts a check when one is due. Silent (no request, no log) when it isn't.
func check_if_due() -> void:
	if not should_check(BuildInfo.channel(), _setting_enabled(), _last_check_unix(), int(Time.get_unix_time_from_system())):
		return
	update_available.connect(_show_notice)
	_request = HTTPRequest.new()
	_request.timeout = REQUEST_TIMEOUT_SEC
	_request.request_completed.connect(_on_request_completed)
	add_child(_request)
	var err := _request.request(RELEASES_URL, PackedStringArray([
		"Accept: application/vnd.github+json",
		"User-Agent: Sonara/%s" % BuildInfo.version(),
	]))
	if err != OK:
		logger.info("Update check not started (error %d)" % err)
		return
	logger.info("Checking %s for a newer release" % RELEASES_URL)
	# Counted when asked, so a failing network does not retry on every launch.
	Sonara.set_config(CONFIG_LAST_CHECK, int(Time.get_unix_time_from_system()))
	Sonara.save_config()


## Whether a check should run: GitHub channel, setting on, last check at least a day ago.
static func should_check(channel: String, enabled: bool, last_check_unix: int, now_unix: int) -> bool:
	if channel != BuildInfo.CHANNEL_GITHUB or not enabled:
		return false
	return now_unix - last_check_unix >= CHECK_INTERVAL_SEC


func _setting_enabled() -> bool:
	return bool(Settings.get_value(SETTING_ENABLED))


func _last_check_unix() -> int:
	return int(Sonara.get_config(CONFIG_LAST_CHECK, 0))


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	handle_response(result, code, body.get_string_from_utf8())
	if _request != null:
		_request.queue_free()
		_request = null


## Process a finished request. Emits update_available for a newer release; anything else
## (network error, HTTP error, bad JSON, nothing newer) is logged quietly.
func handle_response(result: int, code: int, text: String) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		logger.info("Update check failed (result %d, HTTP %d)" % [result, code])
		return
	var releases = JSON.parse_string(text) if not text.strip_edges().is_empty() else null
	if not (releases is Array):
		logger.info("Update check: unexpected response")
		return
	var newest := pick_newest(releases, BuildInfo.version())
	if newest.is_empty():
		logger.info("Sonara %s is up to date" % BuildInfo.version())
		return
	logger.info("Newer release available: %s" % newest["tag_name"])
	update_available.emit(newest)


## The highest-versioned non-draft release in `releases` (GitHub's list format) if it is newer
## than `current`, else {}. Prereleases count: /releases/latest would hide them. Entries without a
## tag_name are skipped.
static func pick_newest(releases: Array, current: String) -> Dictionary:
	var best := {}
	for entry in releases:
		if not (entry is Dictionary):
			continue
		if entry.get("draft", false) == true:
			continue
		var tag = entry.get("tag_name")
		if not (tag is String) or (tag as String).strip_edges().is_empty():
			continue
		if best.is_empty() or BuildInfo.compare_versions(tag, best["tag_name"]) > 0:
			best = entry
	if best.is_empty() or BuildInfo.compare_versions(best["tag_name"], current) <= 0:
		return {}
	return best


func _show_notice(release: Dictionary) -> void:
	if Sonara.editor == null:
		return
	var url := str(release.get("html_url", "https://github.com/petterthowsen/Sonara/releases"))
	Sonara.editor.show_error("Update available",
			"Sonara %s is available. You are running %s." % [str(release["tag_name"]).trim_prefix("v"), BuildInfo.version()],
			[{"text": "Open release page", "callback": func() -> void: OS.shell_open(url)}])
