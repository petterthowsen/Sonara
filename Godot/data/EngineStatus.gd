# EngineStatus.gd
# Engine-wide status stream (not tied to a project): audio callback load, xruns and lock misses.
class_name EngineStatus extends RefCounted

## Emitted for each /status/engine_stats report (2 Hz). Loads are 0.0-1.0+ of the block time;
## `xruns`, `lock_misses` and `callbacks` are running totals since the engine started.
signal engine_stats_received(stats: Stats)


## One /status/engine_stats report.
class Stats:
	var load_avg: float = 0.0
	## Worst single block in the interval.
	var load_peak: float = 0.0
	var xruns: int = 0
	## Callbacks that output silence because the engine state lock was busy.
	var lock_misses: int = 0
	var callbacks: int = 0
	## Frames in the last block.
	var frames: int = 0
	## Plugin blocks padded with silence because the plugin's output wasn't ready.
	var plugin_underruns: int = 0


var _listening: bool = false


## Start listening for engine status messages.
func start() -> void:
	if _listening:
		return
	AudioEngineOSC.listen("/status/engine_stats", _on_engine_stats)
	_listening = true


## Stop listening. Call before dropping the last reference (the listener holds one).
func stop() -> void:
	if not _listening:
		return
	AudioEngineOSC.unlisten("/status/engine_stats", _on_engine_stats)
	_listening = false


func _on_engine_stats(values: Array) -> void:
	if values.size() < 6:
		return
	var stats := Stats.new()
	stats.load_avg = float(values[0])
	stats.load_peak = float(values[1])
	stats.xruns = int(values[2])
	stats.lock_misses = int(values[3])
	stats.callbacks = int(values[4])
	stats.frames = int(values[5])
	if values.size() > 6:
		stats.plugin_underruns = int(values[6])
	engine_stats_received.emit(stats)
