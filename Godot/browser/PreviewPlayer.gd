## PreviewPlayer.gd
## Browser sample preview (spec 037). The engine plays the file (`/preview/*`, see
## docs/subsystems/osc-protocol.md); this model sends the OSC and mirrors the engine's
## `/preview/status`. UI code (BrowserInfoPanel, Browser) calls this class instead of sending
## OSC itself. Between status messages the position is extrapolated, so the playhead moves
## smoothly.
##
## It also asks the engine for a file's waveform and duration (`request_info`), because the info
## panel draws a WaveformView for the selected sample.
class_name PreviewPlayer extends Node

## Mirrors the `state` argument of `/preview/status`.
enum State { STOPPED, LOADING, PLAYING, FAILED }

## The preview state changed for `path`.
signal state_changed(path: String, state: int)
## The (extrapolated) position moved, or a status arrived.
signal position_changed(pos_s: float, duration_s: float)
## Peak file and duration of `path` are known, from `request_info`.
signal info_ready(path: String, peak_path: String, duration_s: float)

## Request ids of waveform/duration requests, so Project ignores them quietly.
const INFO_REQ_PREFIX := "browse:"

var path := ""
var state: State = State.STOPPED
var position_s := 0.0
var duration_s := 0.0

var _anchor_msec := 0
var _anchor_pos_s := 0.0
var _info_counter := 0
## req_id -> {path, duration_s}
var _info_requests: Dictionary = {}
## path -> {peak_path, duration_s}
var _info_cache: Dictionary = {}
var _listening := false


func _ready() -> void:
	set_process(false)


## Listen on every tree entry, not only in _ready: the editor reparents the Browser at startup,
## and _exit_tree drops the listeners.
func _enter_tree() -> void:
	if not Utils.is_test_mode():
		listen()


## Register the OSC listeners; safe to call twice.
func listen() -> void:
	if _listening:
		return
	_listening = true
	AudioEngineOSC.listen("/preview/status", _on_status)
	AudioEngineOSC.listen("/audiofile/decode/ready", _on_decode_ready)
	AudioEngineOSC.listen("/audiofile/waveform/ready", _on_waveform_ready)
	AudioEngineOSC.listen("/audiofile/error", _on_error)


func _exit_tree() -> void:
	if not _listening:
		return
	_listening = false
	AudioEngineOSC.unlisten("/preview/status", _on_status)
	AudioEngineOSC.unlisten("/audiofile/decode/ready", _on_decode_ready)
	AudioEngineOSC.unlisten("/audiofile/waveform/ready", _on_waveform_ready)
	AudioEngineOSC.unlisten("/audiofile/error", _on_error)


# ============================================================================
# PLAYBACK
# ============================================================================

## Play `file_path` from `start_s`, replacing any current preview.
func play(file_path: String, start_s: float = 0.0) -> void:
	if file_path.is_empty():
		return
	path = file_path
	duration_s = _cached_duration(file_path)
	_anchor(start_s)
	_set_state(State.LOADING)
	_send("/preview/play", [file_path, start_s])
	position_changed.emit(position_s, duration_s)


func stop() -> void:
	if state == State.STOPPED:
		return
	_send("/preview/stop", [])
	_anchor(position_s)
	_set_state(State.STOPPED)


## Jump to `pos_s`. While stopped the engine keeps the position for the next play.
func seek(pos_s: float) -> void:
	pos_s = clampf(pos_s, 0.0, duration_s) if duration_s > 0.0 else maxf(pos_s, 0.0)
	_send("/preview/seek", [pos_s])
	_anchor(pos_s)
	position_changed.emit(position_s, duration_s)


## Stop `file_path` if it is playing or loading, otherwise play it from the start.
func toggle(file_path: String) -> void:
	if file_path == path and is_active():
		stop()
	else:
		play(file_path, 0.0)


## True while the preview loads or plays.
func is_active() -> bool:
	return state == State.LOADING or state == State.PLAYING


func is_playing_path(file_path: String) -> bool:
	return file_path == path and is_active()


func _send(address: String, args: Array) -> void:
	AudioEngineOSC.send(address, args)


func _anchor(pos_s: float) -> void:
	position_s = pos_s
	_anchor_pos_s = pos_s
	_anchor_msec = Time.get_ticks_msec()


func _set_state(new_state: State) -> void:
	var changed := state != new_state
	state = new_state
	set_process(state == State.PLAYING)
	if changed:
		state_changed.emit(path, int(state))


func _process(_delta: float) -> void:
	if state != State.PLAYING:
		return
	var pos := _anchor_pos_s + float(Time.get_ticks_msec() - _anchor_msec) / 1000.0
	if duration_s > 0.0:
		pos = minf(pos, duration_s)
	position_s = pos
	position_changed.emit(position_s, duration_s)


## `/preview/status`: [path, state, pos_s, duration_s]. Statuses of another file are old news.
func _on_status(args: Array) -> void:
	if args.size() < 4:
		return
	if str(args[0]) != path:
		return
	var new_state := clampi(int(args[1]), 0, State.FAILED) as State
	# A stop or seek we just sent can still be answered by a playing status for the old state.
	if state == State.STOPPED and new_state == State.PLAYING:
		return
	if float(args[3]) > 0.0:
		duration_s = float(args[3])
	_anchor(float(args[2]))
	_set_state(new_state)
	position_changed.emit(position_s, duration_s)


# ============================================================================
# FILE INFO (waveform and duration)
# ============================================================================

## Ask the engine for the peak file and duration of `file_path`. `info_ready` follows (at once
## when the answer is cached). Returns the request id, or "" for a cached answer.
func request_info(file_path: String) -> String:
	if _info_cache.has(file_path):
		var cached: Dictionary = _info_cache[file_path]
		info_ready.emit(file_path, cached.peak_path, cached.duration_s)
		return ""
	_info_counter += 1
	var req_id := "%s%d" % [INFO_REQ_PREFIX, _info_counter]
	_info_requests[req_id] = {"path": file_path, "duration_s": 0.0}
	_send("/audiofile/waveform/start", [req_id, file_path])
	return req_id


func cached_info(file_path: String) -> Dictionary:
	return _info_cache.get(file_path, {})


func _cached_duration(file_path: String) -> float:
	return float(_info_cache.get(file_path, {}).get("duration_s", 0.0))


## `/audiofile/decode/ready`: [req_id, cache_key, channels, frames, sample_rate, duration_s, ...].
func _on_decode_ready(args: Array) -> void:
	if args.size() < 6:
		return
	var req_id := str(args[0])
	if _info_requests.has(req_id):
		_info_requests[req_id].duration_s = float(args[5])


## `/audiofile/waveform/ready`: [req_id, peak_file_path].
func _on_waveform_ready(args: Array) -> void:
	if args.size() < 2:
		return
	var req_id := str(args[0])
	if not _info_requests.has(req_id):
		return
	var request: Dictionary = _info_requests[req_id]
	_info_requests.erase(req_id)
	var info := {"peak_path": str(args[1]), "duration_s": float(request.duration_s)}
	_info_cache[request.path] = info
	if request.path == path and duration_s <= 0.0:
		duration_s = info.duration_s
	info_ready.emit(request.path, info.peak_path, info.duration_s)


func _on_error(args: Array) -> void:
	if args.is_empty():
		return
	_info_requests.erase(str(args[0]))
