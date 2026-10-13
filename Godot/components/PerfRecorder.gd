## In-app performance recorder (autoload). Collects per-frame engine timings and named
## script scopes while recording, then builds a plain-text report on stop.
##
## Scopes: PerfRecorder.begin(&"Timeline._draw") ... PerfRecorder.end(&"Timeline._draw").
## Both return immediately when not recording. Scopes with the same name must not nest.
## Render CPU/GPU times describe the previous frame (Godot measures them one frame late),
## so each sample pairs them with the scopes of that same previous frame.
extends Node

signal recording_changed(recording: bool)

const WORST_FRAMES := 10
## Phases are timed here, per frame, because Performance.TIME_PROCESS and TIME_PHYSICS_PROCESS
## are refreshed only now and then and repeat stale values. "scripts" is every node's _process,
## "deferred" what runs after it before rendering (layout, queued _draw calls, deferred calls),
## "render" RenderingServer.draw, "other" the rest of the loop (input, physics, vsync wait).
const METRICS := ["frame", "scripts", "deferred", "render", "other", "render_cpu", "render_gpu", "setup_cpu"]
const COUNTERS := ["draw_calls", "primitives", "objects", "nodes"]

var _recording := false
var _start_msec := 0
var _frames := 0
var _viewport_rid: RID
## metric/counter name -> PackedFloat64Array with one entry per frame.
var _series: Dictionary = {}
## scope name -> { "ms": PackedFloat64Array, "calls": PackedInt32Array } per frame.
var _scope_series: Dictionary = {}
## Accumulators for the frame in progress.
var _cur_ms: Dictionary = {}
var _cur_calls: Dictionary = {}
var _open: Dictionary = {}
var last_report := ""
var _skip_first := false
## Phase timestamps (usec) of the frame in progress and of the previous one.
var _t_start := 0
var _t_scripts_end := 0
var _t_pre_draw := 0
var _t_post_draw := 0
var _end_marker: Node
## Script or class -> [nodes processing, nodes physics-processing], taken at start().
var _census: Dictionary = {}


## Runs after every other node's _process, to time the end of the scripts phase.
class _EndMarker extends Node:
	var recorder: Node
	func _process(_delta: float) -> void:
		recorder._t_scripts_end = Time.get_ticks_usec()


func _ready() -> void:
	process_priority = -1000 # sample before other nodes' _process
	set_process(false)
	_end_marker = _EndMarker.new()
	_end_marker.recorder = self
	_end_marker.process_priority = 1000
	_end_marker.set_process(false)
	add_child(_end_marker)
	RenderingServer.frame_pre_draw.connect(func(): _t_pre_draw = Time.get_ticks_usec())
	RenderingServer.frame_post_draw.connect(func(): _t_post_draw = Time.get_ticks_usec())


func is_recording() -> bool:
	return _recording


func start() -> void:
	if _recording:
		return
	_series.clear()
	_scope_series.clear()
	_cur_ms.clear()
	_cur_calls.clear()
	_open.clear()
	for key in METRICS + COUNTERS:
		_series[key] = PackedFloat64Array()
	_frames = 0
	_census = _processing_census()
	_viewport_rid = get_tree().root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	_start_msec = Time.get_ticks_msec()
	_skip_first = true
	_recording = true
	_t_start = 0
	set_process(true)
	_end_marker.set_process(true)
	recording_changed.emit(true)


## Stop recording and return the report. Outside test mode it is also copied to the
## clipboard and written to logs/perf_<timestamp>.txt next to last.log.
func stop() -> String:
	if not _recording:
		return ""
	_recording = false
	set_process(false)
	_end_marker.set_process(false)
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, false)
	var duration := (Time.get_ticks_msec() - _start_msec) / 1000.0
	last_report = build_report(duration)
	if not Utils.is_test_mode():
		DisplayServer.clipboard_set(last_report)
		var stamp := Time.get_datetime_string_from_system().replace(":", "-")
		var path := Log.log_file_path.get_base_dir().path_join("perf_%s.txt" % stamp)
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file:
			file.store_string(last_report)
			file.close()
		else:
			push_warning("PerfRecorder: could not write %s" % path)
		print("PerfRecorder: report written to ", ProjectSettings.globalize_path(path))
	recording_changed.emit(false)
	return last_report


func begin(name: StringName) -> void:
	if _recording:
		_open[name] = Time.get_ticks_usec()


func end(name: StringName) -> void:
	if not _recording:
		return
	var t0: int = _open.get(name, 0)
	if t0 == 0:
		return
	_open.erase(name)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_cur_ms[name] = _cur_ms.get(name, 0.0) + ms
	_cur_calls[name] = _cur_calls.get(name, 0) + 1


## Scope name for an incoming OSC message: its address with numeric segments collapsed, so
## /channel/3/peak and /channel/7/peak share "OSC /channel/*/peak".
func osc_scope(address: String) -> StringName:
	var key: StringName = _osc_scopes.get(address, &"")
	if key == &"":
		var parts := address.split("/")
		for i in parts.size():
			if parts[i].is_valid_int():
				parts[i] = "*"
		key = StringName("OSC " + "/".join(parts))
		_osc_scopes[address] = key
	return key


var _osc_scopes: Dictionary = {}


func _process(_delta: float) -> void:
	# Scopes accumulated since the last call belong to the previous frame, as do the
	# measured render times and phase stamps. The first call only discards the partial frame.
	var now := Time.get_ticks_usec()
	if _skip_first or _t_start == 0:
		_skip_first = false
		_cur_ms.clear()
		_cur_calls.clear()
		_t_start = now
		return
	# Headless never draws, so the draw stamps stay behind; those phases then read 0.
	var drew := _t_pre_draw >= _t_scripts_end and _t_post_draw >= _t_pre_draw
	record_frame((now - _t_start) / 1000.0, maxf(0.0, (_t_scripts_end - _t_start) / 1000.0),
		(_t_pre_draw - _t_scripts_end) / 1000.0 if drew else 0.0,
		(_t_post_draw - _t_pre_draw) / 1000.0 if drew else 0.0,
		(now - _t_post_draw) / 1000.0 if drew else 0.0)
	_t_start = now


## Append one frame sample (phase times in ms) plus the live engine counters, and flush the
## scope accumulators.
func record_frame(frame_ms: float, scripts_ms: float, deferred_ms: float, render_ms: float, other_ms: float) -> void:
	_series["frame"].append(frame_ms)
	_series["scripts"].append(scripts_ms)
	_series["deferred"].append(deferred_ms)
	_series["render"].append(render_ms)
	_series["other"].append(other_ms)
	_series["render_cpu"].append(RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid))
	_series["render_gpu"].append(RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid))
	_series["setup_cpu"].append(RenderingServer.get_frame_setup_time_cpu())
	_series["draw_calls"].append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_series["primitives"].append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_series["objects"].append(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_series["nodes"].append(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	for name in _cur_ms:
		if not _scope_series.has(name):
			var ms := PackedFloat64Array()
			var calls := PackedInt32Array()
			ms.resize(_frames)
			calls.resize(_frames)
			_scope_series[name] = {"ms": ms, "calls": calls}
	for name in _scope_series:
		_scope_series[name]["ms"].append(_cur_ms.get(name, 0.0))
		_scope_series[name]["calls"].append(_cur_calls.get(name, 0))
	_cur_ms.clear()
	_cur_calls.clear()
	_frames += 1


## Count the nodes whose _process / _physics_process run every frame, by script (or class).
## Per-node script time can't be measured without the editor profiler, so this names suspects.
func _processing_census() -> Dictionary:
	var counts := {}
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children(true))
		if node == self or node == _end_marker:
			continue
		var p := node.is_processing()
		var ph := node.is_physics_processing()
		if not p and not ph:
			continue
		var script: Script = node.get_script()
		var key: String = script.resource_path if script and not script.resource_path.is_empty() else node.get_class()
		var c: Array = counts.get(key, [0, 0])
		c[0] += 1 if p else 0
		c[1] += 1 if ph else 0
		counts[key] = c
	return counts


func build_report(duration_s: float) -> String:
	var n := _frames
	var lines: PackedStringArray = []
	lines.append("=== Sonara performance capture ===")
	lines.append("Date: %s" % Time.get_datetime_string_from_system())
	lines.append("Duration: %.2f s" % duration_s)
	lines.append("Frames: %d" % n)
	if n == 0:
		return "\n".join(lines) + "\nNo frames recorded.\n"
	var frame_mean := _mean(_series["frame"])
	lines.append("FPS (mean): %.1f" % (1000.0 / frame_mean if frame_mean > 0.0 else 0.0))
	lines.append("")
	lines.append("--- Frame timings (ms) ---")
	lines.append("%-14s %8s %8s %8s %8s %8s" % ["metric", "mean", "p50", "p95", "p99", "max"])
	var labels := {"frame": "frame", "scripts": "scripts", "deferred": "deferred", "render": "render",
		"other": "input/phys/wait", "render_cpu": "render CPU",
		"render_gpu": "render GPU", "setup_cpu": "frame setup"}
	for key in METRICS:
		var s := _stats(_series[key])
		lines.append("%-14s %8.2f %8.2f %8.2f %8.2f %8.2f" % [labels[key], s[0], s[1], s[2], s[3], s[4]])
	lines.append("")
	lines.append("--- Render load (mean per frame) ---")
	lines.append("Draw calls: %.0f  Primitives: %.0f  Objects: %.0f  Nodes: %.0f" % [
		_mean(_series["draw_calls"]), _mean(_series["primitives"]),
		_mean(_series["objects"]), _mean(_series["nodes"])])
	lines.append("")
	lines.append("--- Scopes ---")
	lines.append("%-40s %10s %10s %10s" % ["scope", "mean ms", "max ms", "calls/frame"])
	var names := _scope_series.keys()
	names.sort_custom(func(a, b): return _mean(_scope_series[a]["ms"]) > _mean(_scope_series[b]["ms"]))
	if names.is_empty():
		lines.append("(none recorded)")
	for name in names:
		var ms: PackedFloat64Array = _scope_series[name]["ms"]
		var calls: PackedInt32Array = _scope_series[name]["calls"]
		var total_calls := 0
		for c in calls:
			total_calls += c
		lines.append("%-40s %10.3f %10.3f %10.2f" % [name, _mean(ms), _max(ms), float(total_calls) / n])
	lines.append("")
	lines.append("--- Worst %d frames ---" % WORST_FRAMES)
	var order := range(n)
	var frame_ms: PackedFloat64Array = _series["frame"]
	order.sort_custom(func(a, b): return frame_ms[a] > frame_ms[b])
	for i in mini(WORST_FRAMES, n):
		var f: int = order[i]
		lines.append("#%d frame %d: %.2f ms  scripts %.2f  deferred %.2f  render %.2f  other %.2f  renderGPU %.2f  draws %.0f  prims %.0f  objs %.0f" % [
			i + 1, f, frame_ms[f], _series["scripts"][f], _series["deferred"][f], _series["render"][f],
			_series["other"][f], _series["render_gpu"][f], _series["draw_calls"][f],
			_series["primitives"][f], _series["objects"][f]])
		var parts: PackedStringArray = []
		for name in names:
			var v: float = _scope_series[name]["ms"][f]
			if v > 0.0:
				parts.append("%s=%.3f(x%d)" % [name, v, _scope_series[name]["calls"][f]])
		if not parts.is_empty():
			lines.append("    scopes: " + ", ".join(parts))
	lines.append("")
	lines.append("--- Nodes processing every frame (at start) ---")
	lines.append("%-60s %8s %8s" % ["script / class", "process", "physics"])
	var keys := _census.keys()
	keys.sort_custom(func(a, b): return _census[a][0] + _census[a][1] > _census[b][0] + _census[b][1])
	for key in keys:
		lines.append("%-60s %8d %8d" % [key, _census[key][0], _census[key][1]])
	lines.append("")
	lines.append("Note: render CPU/GPU are measured one frame late; GPU is 0 when the driver does not support timestamps.")
	return "\n".join(lines) + "\n"


static func _mean(a: PackedFloat64Array) -> float:
	if a.is_empty():
		return 0.0
	var sum := 0.0
	for v in a:
		sum += v
	return sum / a.size()


## [mean, p50, p95, p99, max]
static func _stats(a: PackedFloat64Array) -> Array:
	var sorted := a.duplicate()
	sorted.sort()
	var last := sorted.size() - 1
	return [_mean(a), sorted[int(last * 0.5)], sorted[int(last * 0.95)], sorted[int(last * 0.99)], sorted[last]]


static func _max(a: PackedFloat64Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m
