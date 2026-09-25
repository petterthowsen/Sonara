# AudioConfig.gd
# Audio output settings (engine-stability-plan Phase 7): the output device, sample rate and
# buffer size the engine runs with. Owns the engine's device list and the running config, sends
# the OSC and emits signals; UI never sends OSC directly.
#
# The three settings live in the Settings registry ("audio/output_device", "audio/sample_rate",
# "audio/buffer_size"). Changing one applies live: the engine reopens its stream, preparing
# devices for a new rate while it is stopped. The engine reports what actually runs, which can
# differ from the settings (missing device, unsupported rate, PipeWire's quantum):
#   /audio/devices/request -> /audio/device [name, is_default, min_buffer, max_buffer, channels, rate...]
#                             ... -> /audio/devices/complete [count]
#   /audio/config/set [device, rate, buffer]      ("" = system default device)
#   /audio/config/request -> /audio/config [device, rate, buffer, latency_ms, output_pairs,
#       is_default_device, requested_device, requested_rate, requested_buffer, graph_quantum,
#       graph_rate, mismatch, notice]
#   /audio/config/changed [rate]   (the device rate changed: audio clips reload)
#
# Registered as the "AudioConfig" autoload, after Settings.
extends Node

var logger := Log.make("AudioConfig")

const DEVICE_KEY := "audio/output_device"
const RATE_KEY := "audio/sample_rate"
const BUFFER_KEY := "audio/buffer_size"
const KEYS := [DEVICE_KEY, RATE_KEY, BUFFER_KEY]

## Hardware output IDs: 1000 = outputs 1/2 of the selected device, 1001 = 3/4, …
const HARDWARE_OUTPUT_BASE := 1000

## Rates and buffer sizes offered when the engine hasn't listed the device.
const FALLBACK_RATES := [44100, 48000, 88200, 96000]
const BUFFER_SIZES := [32, 64, 128, 256, 512, 1024, 2048]

signal devices_changed()
signal config_changed()
## The engine's device rate changed; clips decoded at the old rate should reload.
signal sample_rate_changed(sample_rate: int)
## The engine couldn't use the saved settings (e.g. the device is missing). Shown once per text.
signal notice_raised(text: String)

## Output devices from the engine: {name, is_default, min_buffer, max_buffer, channels, rates}.
var devices: Array[Dictionary] = []
## True once a device list arrived.
var devices_loaded := false
## Last /audio/config, as a Dictionary (see `parse_config`); empty until the first report.
var config: Dictionary = {}

var _pending_devices: Array[Dictionary] = []
var _apply_scheduled := false
var _last_notice := ""


func _ready() -> void:
	if Utils.is_test_mode():
		return
	start()


## Listen for engine reports, setting changes and engine (re)connects, then apply the settings.
func start() -> void:
	AudioEngineOSC.listen("/audio/device", _on_device)
	AudioEngineOSC.listen("/audio/devices/complete", _on_devices_complete)
	AudioEngineOSC.listen("/audio/config", _on_config)
	AudioEngineOSC.listen("/audio/config/changed", _on_config_changed)
	if not Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.connect(_on_setting_changed)
	if not AudioEngineOSC.engine_connected.is_connected(_on_engine_connected):
		AudioEngineOSC.engine_connected.connect(_on_engine_connected)
	sync_to_engine()


# ============================================================================
# SETTINGS -> ENGINE
# ============================================================================

## The /audio/config/set arguments from the saved settings.
func build_message() -> Array:
	return [
		str(Settings.get_value(DEVICE_KEY)),
		int(Settings.get_value(RATE_KEY)),
		int(Settings.get_value(BUFFER_KEY)),
	]


## Send the saved settings. Safe to repeat: the engine only reopens its stream on a change.
func sync_to_engine() -> void:
	AudioEngineOSC.send("/audio/config/set", build_message())


## Ask the engine for its output devices (it opens each one, so this takes a moment).
func request_devices() -> void:
	AudioEngineOSC.send("/audio/devices/request", [])


## Ask the engine for the running config.
func request_config() -> void:
	AudioEngineOSC.send("/audio/config/request", [])


func _on_setting_changed(key: String, _value) -> void:
	if key not in KEYS:
		return
	# Settings are written one at a time (and all at once on OK); apply once per frame.
	if not _apply_scheduled:
		_apply_scheduled = true
		_apply_deferred.call_deferred()


func _apply_deferred() -> void:
	_apply_scheduled = false
	sync_to_engine()


func _on_engine_connected() -> void:
	sync_to_engine()
	if devices_loaded:
		request_devices()


# ============================================================================
# ENGINE -> MODEL
# ============================================================================

## Parse /audio/device arguments. Returns {} when malformed.
static func parse_device(args: Array) -> Dictionary:
	if args.size() < 5:
		return {}
	var rates: Array[int] = []
	for i in range(5, args.size()):
		rates.append(int(args[i]))
	return {
		"name": str(args[0]),
		"is_default": int(args[1]) != 0,
		"min_buffer": int(args[2]),
		"max_buffer": int(args[3]),
		"channels": int(args[4]),
		"rates": rates,
	}


## Parse /audio/config arguments. Returns {} when malformed.
static func parse_config(args: Array) -> Dictionary:
	if args.size() < 13:
		return {}
	return {
		"device": str(args[0]),
		"sample_rate": int(args[1]),
		"buffer_size": int(args[2]),
		"latency_ms": float(args[3]),
		"output_pairs": int(args[4]),
		"is_default_device": int(args[5]) != 0,
		"requested_device": str(args[6]),
		"requested_rate": int(args[7]),
		"requested_buffer": int(args[8]),
		"graph_quantum": int(args[9]),
		"graph_rate": int(args[10]),
		"mismatch": str(args[11]),
		"notice": str(args[12]),
	}


func _on_device(args: Array) -> void:
	var device := parse_device(args)
	if not device.is_empty():
		_pending_devices.append(device)


func _on_devices_complete(_args: Array) -> void:
	devices = _pending_devices.duplicate()
	_pending_devices.clear()
	devices_loaded = true
	logger.info("%d output devices" % devices.size())
	devices_changed.emit()


func _on_config(args: Array) -> void:
	var parsed := parse_config(args)
	if parsed.is_empty():
		logger.warn("Malformed /audio/config: %s" % [args])
		return
	apply_config(parsed)


## Store a parsed /audio/config and announce it. Public for tests.
func apply_config(parsed: Dictionary) -> void:
	config = parsed
	logger.info("Engine audio: %s at %d Hz, %d frames (%.1f ms), %d output pair(s)" % [
		parsed.device if not parsed.device.is_empty() else "(none)",
		parsed.sample_rate, parsed.buffer_size, parsed.latency_ms, parsed.output_pairs])
	var notice: String = parsed.notice
	if notice != _last_notice:
		_last_notice = notice
		if not notice.is_empty():
			logger.warn(notice)
			notice_raised.emit(notice)
	config_changed.emit()


func _on_config_changed(args: Array) -> void:
	if args.is_empty():
		return
	var rate := int(args[0])
	logger.info("Engine sample rate is now %d Hz; reloading audio clips" % rate)
	sample_rate_changed.emit(rate)


# ============================================================================
# QUERIES (for the Settings controls and routing menus)
# ============================================================================

## True once the engine reported a running stream.
func has_config() -> bool:
	return not config.is_empty() and not str(config.get("device", "")).is_empty()


## Stereo output pairs on the running device (1 until the engine reports).
func output_pairs() -> int:
	return maxi(1, int(config.get("output_pairs", 1)))


## Menu label for hardware output `output_id`: "Outputs 1/2", "Outputs 3/4", …
static func output_label(output_id: int) -> String:
	var pair := output_id - HARDWARE_OUTPUT_BASE
	return "Outputs %d/%d" % [pair * 2 + 1, pair * 2 + 2]


## The listed device `name` ("" = the system default device), or {} when unknown.
func find_device(name: String) -> Dictionary:
	for device in devices:
		if (name.is_empty() and device.is_default) or device.name == name:
			return device
	return {}


## Sample rates to offer for device `name`, always including `current`.
func rates_for(name: String, current: int) -> Array[int]:
	var result: Array[int] = []
	var device := find_device(name)
	var listed: Array = device.get("rates", [])
	for rate in (listed if not listed.is_empty() else FALLBACK_RATES):
		result.append(int(rate))
	if current > 0 and current not in result:
		result.append(current)
	result.sort()
	return result


## Buffer sizes (frames) to offer for device `name`, always including `current`.
func buffer_sizes_for(name: String, current: int) -> Array[int]:
	var device := find_device(name)
	var low := int(device.get("min_buffer", BUFFER_SIZES[0]))
	var high := int(device.get("max_buffer", BUFFER_SIZES[-1]))
	var result: Array[int] = []
	for size in BUFFER_SIZES:
		if size >= low and size <= high:
			result.append(size)
	if current > 0 and current not in result:
		result.append(current)
	result.sort()
	return result
