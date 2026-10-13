# EngineStatus.gd
# Engine-wide status stream (not tied to a project): audio callback load, xruns and lock misses.
class_name EngineStatus extends RefCounted

## Emitted for each /status/engine_stats report (2 Hz). Loads are 0.0-1.0+ of the block time;
## `xruns`, `lock_misses` and `callbacks` are running totals since the engine started.
signal engine_stats_received(stats: Stats)
## Emitted for each /status/channel_perf report (every 500 ms per channel that ran, while
## subscribed with subscribe_perf()).
signal channel_perf_received(perf: ChannelPerf)
## Emitted for each /status/engine_perf report (every 500 ms while subscribed).
signal engine_perf_received(perf: EnginePerf)
## Emitted for each /status/engine_memory report (every 500 ms while subscribed).
signal engine_memory_received(memory: EngineMemory)


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


## One /status/channel_perf report: i channel_id, f load_avg, f load_peak, i out_latency_frames,
## i device_count, (f device_avg, f device_peak) x device_count. Loads are shares of the block time.
class ChannelPerf:
	var channel_id: int = 0
	var load_avg: float = 0.0
	var load_peak: float = 0.0
	var out_latency_frames: int = 0
	## Per top-level device, indexed by its position in the channel's chain.
	var device_avg: PackedFloat32Array = PackedFloat32Array()
	var device_peak: PackedFloat32Array = PackedFloat32Array()

	func device_count() -> int:
		return device_avg.size()

	## Null for a short or malformed message.
	static func from_osc(args: Array) -> ChannelPerf:
		if args.size() < 5:
			return null
		var count := int(args[4])
		if count < 0 or args.size() < 5 + count * 2:
			return null
		var perf := ChannelPerf.new()
		perf.channel_id = int(args[0])
		perf.load_avg = float(args[1])
		perf.load_peak = float(args[2])
		perf.out_latency_frames = int(args[3])
		for i in count:
			perf.device_avg.append(float(args[5 + i * 2]))
			perf.device_peak.append(float(args[6 + i * 2]))
		return perf


## One /status/engine_perf report: i processing_threads, s threads_realtime,
## i output_latency_frames, i over_limit_channels, i sample_rate.
class EnginePerf:
	var processing_threads: int = 0
	## "granted", "denied", "partial" or "none".
	var threads_realtime: String = "none"
	var output_latency_frames: int = 0
	var over_limit_channels: int = 0
	var sample_rate: int = 0

	## Null for a short message.
	static func from_osc(args: Array) -> EnginePerf:
		if args.size() < 5:
			return null
		var perf := EnginePerf.new()
		perf.processing_threads = int(args[0])
		perf.threads_realtime = str(args[1])
		perf.output_latency_frames = int(args[2])
		perf.over_limit_channels = int(args[3])
		perf.sample_rate = int(args[4])
		return perf


## One /status/engine_memory report: i engine_kib, i plugins_kib, i plugin_hosts. PSS, so memory
## shared between the engine and the plugin hosts is counted once.
class EngineMemory:
	var engine_bytes: int = 0
	## Sum over the plugin host processes.
	var plugin_bytes: int = 0
	var plugin_hosts: int = 0

	func total_bytes() -> int:
		return engine_bytes + plugin_bytes

	## Null for a short message.
	static func from_osc(args: Array) -> EngineMemory:
		if args.size() < 3:
			return null
		var memory := EngineMemory.new()
		memory.engine_bytes = int(args[0]) * 1024
		memory.plugin_bytes = int(args[1]) * 1024
		memory.plugin_hosts = int(args[2])
		return memory


var _listening: bool = false


## Start listening for engine status messages.
func start() -> void:
	if _listening:
		return
	AudioEngineOSC.listen("/status/engine_stats", _on_engine_stats)
	AudioEngineOSC.listen("/status/channel_perf", _on_channel_perf)
	AudioEngineOSC.listen("/status/engine_perf", _on_engine_perf)
	AudioEngineOSC.listen("/status/engine_memory", _on_engine_memory)
	_listening = true


## Stop listening. Call before dropping the last reference (the listener holds one).
func stop() -> void:
	if not _listening:
		return
	AudioEngineOSC.unlisten("/status/engine_stats", _on_engine_stats)
	AudioEngineOSC.unlisten("/status/channel_perf", _on_channel_perf)
	AudioEngineOSC.unlisten("/status/engine_perf", _on_engine_perf)
	AudioEngineOSC.unlisten("/status/engine_memory", _on_engine_memory)
	_listening = false


## Ask the engine for per-channel and per-device timing. The engine counts subscribers, so
## every call needs a matching unsubscribe_perf().
func subscribe_perf() -> void:
	AudioEngineOSC.send("/engine/perf/subscribe", [])


func unsubscribe_perf() -> void:
	AudioEngineOSC.send("/engine/perf/unsubscribe", [])


func _on_channel_perf(values: Array) -> void:
	var perf := ChannelPerf.from_osc(values)
	if perf != null:
		channel_perf_received.emit(perf)


func _on_engine_memory(values: Array) -> void:
	var memory := EngineMemory.from_osc(values)
	if memory != null:
		engine_memory_received.emit(memory)


func _on_engine_perf(values: Array) -> void:
	var perf := EnginePerf.from_osc(values)
	if perf != null:
		engine_perf_received.emit(perf)


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
