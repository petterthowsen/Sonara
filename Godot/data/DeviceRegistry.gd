# DeviceRegistry.gd
# Every known Device type (built-in and plugin), discovered from the engine over OSC.
# Built-ins arrive via /builtin/request → /builtin/info → /builtin/complete; plugins via
# /plugin/scan [path:String]* → /plugin/info → /plugin/scan_complete and are cached in
# plugins.json. Search paths come from the "assets/clap/paths" setting; with no paths given
# the engine falls back to its built-in defaults.
# Owned by AssetService; DeviceAssetProvider only maps these devices to browser Assets.
class_name DeviceRegistry extends RefCounted

static var logger := Log.make("DeviceRegistry")

## A device was stored (or replaced). Fires per /builtin/info and per cached plugin, before the batch signal.
signal device_registered(device: Device)

## A batch of registrations or removals finished (builtin advertisement, plugin scan, cache load).
signal devices_changed(added: Array[Device], removed: Array[Device])

## The engine advertised a (new) modulator kind. See `modulator_kinds` (spec 018).
signal modulator_kind_registered(kind_id: String)

## The engine's modulator-kind batch finished.
signal modulator_kinds_changed()

var _devices: Dictionary[String, Device] = {}

## Modulator kinds the engine offers (spec 018), by id:
## `{id: String, name: String, bipolar: bool, params: Array[DeviceParameter]}`. Kinds are
## engine-global, not per device; a modulator builds its controls from `params`.
var modulator_kinds: Dictionary = {}


## Load the plugin cache, listen for engine advertisements and request built-ins.
func start() -> void:
	_load_plugin_cache()
	AudioEngineOSC.listen("/plugin/info", _on_plugin_info_received)
	AudioEngineOSC.listen("/plugin/scan_complete", _on_plugin_scan_complete)
	AudioEngineOSC.listen("/builtin/info", _on_builtin_info_received)
	AudioEngineOSC.listen("/builtin/complete", _on_builtin_complete)
	AudioEngineOSC.listen("/builtin/modulator_kind", _on_modulator_kind_received)
	AudioEngineOSC.listen("/builtin/modulator_complete", _on_modulator_kinds_complete)
	# Re-request built-ins whenever the engine (re)connects.
	if not AudioEngineOSC.engine_connected.is_connected(_request_builtin_devices):
		AudioEngineOSC.engine_connected.connect(_request_builtin_devices)
	_request_builtin_devices()


## Device by ID (built-in or plugin), or null.
func get_device(device_id: String) -> Device:
	return _devices.get(device_id)


## True once the engine finished advertising its built-in devices (/builtin/complete).
var builtins_complete: bool = false


## All registered devices.
func get_devices() -> Array[Device]:
	var out: Array[Device] = []
	out.assign(_devices.values())
	return out


## One modulator kind the engine offered, or {} when it isn't advertised (yet).
func get_modulator_kind(kind_id: String) -> Dictionary:
	return modulator_kinds.get(kind_id, {})


## Every advertised modulator kind, sorted by id for stable UI order.
func get_modulator_kinds() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for kind in modulator_kinds.values():
		out.append(kind)
	out.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
	return out


## Drop cached plugins and ask the engine for a fresh plugin scan. Built-ins are kept.
func scan_plugins() -> void:
	var removed: Array[Device] = []
	for device in _devices.values():
		if device.device_type != Device.DeviceType.BuiltIn:
			removed.append(device)
	for device in removed:
		_devices.erase(device.device_id)
	logger.info("Plugin scan: cleared %d cached plugins" % removed.size())
	if not removed.is_empty():
		devices_changed.emit([] as Array[Device], removed)
	AudioEngineOSC.send("/plugin/scan", _clap_scan_paths())


## Configured CLAP search paths, expanded and de-duplicated. Order is preserved.
func _clap_scan_paths() -> Array:
	var raw = Settings.get_value("assets/clap/paths")
	var seen: Dictionary = {}
	var paths: Array = []
	for p in raw:
		var expanded: String = Utils.expand_path(str(p)).strip_edges()
		if expanded.is_empty() or seen.has(expanded):
			continue
		seen[expanded] = true
		paths.append(expanded)
	return paths


func _request_builtin_devices() -> void:
	AudioEngineOSC.send("/builtin/request", [])


func _register(device: Device) -> void:
	_devices[device.device_id] = device
	device_registered.emit(device)


func _devices_of_kind(builtin: bool) -> Array[Device]:
	var out: Array[Device] = []
	for device in _devices.values():
		if (device.device_type == Device.DeviceType.BuiltIn) == builtin:
			out.append(device)
	return out


static func _category_from_string(category_str: String) -> Device.DeviceCategory:
	match category_str:
		"instrument":
			return Device.DeviceCategory.Instrument
		"utility":
			return Device.DeviceCategory.Utility
		"note_effect":
			return Device.DeviceCategory.NoteEffect
		_:
			return Device.DeviceCategory.Effect


## ============================================================================
## PLUGINS (ENGINE → GODOT)
## ============================================================================

## One plugin found during a scan: [id, name, vendor, version, category, description, path, features].
func _on_plugin_info_received(args: Array) -> void:
	if args.size() < 7:
		logger.warn("Invalid /plugin/info message: %s" % str(args))
		return

	var plugin_id: String = args[0]
	var plugin_name: String = args[1]
	var category := _category_from_string(args[4])
	var description: String = args[5]

	var device := Device.new(plugin_id, plugin_name, category, Device.DeviceType.CLAP)
	device.author = args[2]
	device.version = args[3]
	device.description = description if description != "" else "CLAP Plugin"
	device.title = plugin_name
	device.plugin_path = args[6]
	if args.size() >= 8 and args[7] is String and not String(args[7]).is_empty():
		var features: Array[String] = []
		for tag in String(args[7]).split(","):
			features.append(tag)
		device.features = features
	if category == Device.DeviceCategory.Instrument:
		device.accepts_midi = true
		device.audio_in_channels = 0
	else:
		device.accepts_midi = false
		device.audio_in_channels = 2
	device.audio_out_channels = 2
	_register(device)


func _on_plugin_scan_complete(args: Array) -> void:
	if args.size() < 1:
		logger.warn("Invalid /plugin/scan_complete message")
		return
	logger.info("Plugin scan complete: %d plugins discovered" % int(args[0]))
	var plugins := _devices_of_kind(false)
	if not plugins.is_empty():
		devices_changed.emit(plugins, [] as Array[Device])
	_save_plugin_cache()


## ============================================================================
## BUILT-INS (ENGINE → GODOT)
## ============================================================================

## One built-in device. Args layout from the engine:
## [id:String, name:String, category:String, description:String, accepts_midi:Int(0|1),
##  audio_in:Int, audio_out:Int, supports_file_loading:Int(0|1), file_type_description:String,
##  extension_count:Int, each extension:String..., param_count:Int, then param tuples:
##  (param_id:Int, name:String, unit:String, type:String, syncable:Int(0|1),
##   min:Float, max:Float, default:Float, is_log:Int(0|1), skew:Float, enum_count:Int,
##   enum_values:String..., module:String, automatable:Int(0|1), modulatable:Int(0|1)) ...,
##  is_container:Int, then optionally the modulation block:
##  source_count:Int, (id:String, name:String, bipolar:Int(0|1))..., route_count:Int,
##  (source:String, param_id:Int, amount:Float)... (the default patch)]
func _on_builtin_info_received(args: Array) -> void:
	if args.size() < 10:
		logger.warn("Invalid /builtin/info message: %s" % str(args))
		return

	var dev_id: String = args[0]
	var dev_name: String = args[1]
	var device := Device.new(dev_id, dev_name, _category_from_string(args[2]), Device.DeviceType.BuiltIn)
	device.title = dev_name
	device.description = args[3]
	device.accepts_midi = int(args[4]) != 0
	device.audio_in_channels = int(args[5])
	device.audio_out_channels = int(args[6])
	device.supports_file_loading = int(args[7]) != 0
	device.file_type_description = String(args[8])

	var extension_count: int = int(args[9])
	var idx := 10
	var extensions: Array[String] = []
	for _i in range(extension_count):
		if idx >= args.size():
			logger.warn("Missing extension data in /builtin/info message: %s" % str(args))
			return
		extensions.append(String(args[idx]))
		idx += 1
	device.supported_file_extensions = extensions

	if idx >= args.size():
		logger.warn("Missing parameter count in /builtin/info message: %s" % str(args))
		return
	var param_count: int = int(args[idx])
	idx += 1

	for _i in range(param_count):
		var parsed := _parse_param(args, idx, dev_id)
		var param: DeviceParameter = parsed[0]
		if param == null:
			logger.warn("Truncated parameter data for builtin device %s" % dev_id)
			break
		idx = parsed[1]
		device.add_parameter(param)

	if idx < args.size():
		device.is_container = int(args[idx]) != 0
		idx += 1

	_parse_default_modulators(device, args, idx)

	# Batched: devices_changed fires on /builtin/complete.
	_register(device)


## Parse one parameter tuple starting at `idx` (the layout `push_param_args` writes). Returns
## `[DeviceParameter, next_idx]`, or `[null, idx]` when the tuple is truncated.
func _parse_param(args: Array, idx: int, owner_id: String) -> Array:
	if idx + 10 >= args.size():
		return [null, idx]
	var param := DeviceParameter.new(int(args[idx]), String(args[idx + 1]), String(args[idx + 2]))
	param.param_type = String(args[idx + 3])
	param.syncable = int(args[idx + 4]) != 0
	param.min_value = float(args[idx + 5])
	param.max_value = float(args[idx + 6])
	param.default_value = float(args[idx + 7])
	param.is_logarithmic = int(args[idx + 8]) != 0
	param.skew = maxf(float(args[idx + 9]), 0.01)
	var enum_count: int = int(args[idx + 10])
	idx += 11

	var enum_vals: Array[String] = []
	for _j in range(enum_count):
		if idx >= args.size():
			logger.warn("Missing enum value for param %s on %s" % [param.name, owner_id])
			break
		enum_vals.append(String(args[idx]))
		idx += 1
	param.enum_values = enum_vals
	if idx + 1 < args.size():
		param.module = String(args[idx])
		param.is_automation_safe = int(args[idx + 1]) != 0
		idx += 2
		if idx < args.size():
			param.is_modulatable = int(args[idx]) != 0
			idx += 1
	return [param, idx]


## Default-modulator block of /builtin/info starting at `idx`. Absent for devices without a
## default patch. `{kind, name, params: {id: norm}, routes: [{target, amount}]}`.
func _parse_default_modulators(device: Device, args: Array, idx: int) -> void:
	if idx >= args.size():
		return
	var count := int(args[idx])
	idx += 1
	for _i in range(count):
		if idx + 2 >= args.size():
			logger.warn("Truncated default modulators for builtin device %s" % device.device_id)
			return
		var modulator := {"kind": String(args[idx]), "name": String(args[idx + 1]), "params": {}, "routes": []}
		idx += 2
		var param_count := int(args[idx])
		idx += 1
		for _p in range(param_count):
			if idx + 1 >= args.size():
				logger.warn("Truncated default modulator params for %s" % device.device_id)
				return
			modulator["params"][int(args[idx])] = float(args[idx + 1])
			idx += 2
		var route_count := int(args[idx])
		idx += 1
		for _r in range(route_count):
			if idx + 1 >= args.size():
				logger.warn("Truncated default modulator routes for %s" % device.device_id)
				return
			modulator["routes"].append({"target": String(args[idx]), "amount": float(args[idx + 1])})
			idx += 2
		device.default_modulators.append(modulator)


## ============================================================================
## MODULATOR KINDS (ENGINE -> GODOT)
## ============================================================================

## One modulator kind: [id, name, bipolar, param_count, then the same parameter tuples as
## /builtin/info]. Kinds are engine-global; they arrive in the same /builtin/request batch.
func _on_modulator_kind_received(args: Array) -> void:
	if args.size() < 4:
		logger.warn("Invalid /builtin/modulator_kind message: %s" % str(args))
		return
	var kind_id := String(args[0])
	var entry := {
		"id": kind_id,
		"name": String(args[1]),
		"bipolar": int(args[2]) != 0,
		"params": [] as Array[DeviceParameter],
	}
	var param_count := int(args[3])
	var idx := 4
	for _i in range(param_count):
		var parsed := _parse_param(args, idx, kind_id)
		var param: DeviceParameter = parsed[0]
		if param == null:
			logger.warn("Truncated parameters for modulator kind %s" % kind_id)
			break
		idx = parsed[1]
		entry["params"].append(param)
	modulator_kinds[kind_id] = entry
	modulator_kind_registered.emit(kind_id)


func _on_modulator_kinds_complete(args: Array) -> void:
	var count := int(args[0]) if args.size() > 0 else -1
	logger.info("Modulator kind advertisement complete: %d kinds" % count)
	modulator_kinds_changed.emit()


func _on_builtin_complete(args: Array) -> void:
	var count := int(args[0]) if args.size() > 0 else -1
	logger.info("Builtin advertisement complete: %d devices" % count)
	builtins_complete = true
	var builtins := _devices_of_kind(true)
	if not builtins.is_empty():
		devices_changed.emit(builtins, [] as Array[Device])


## ============================================================================
## PLUGIN CACHE
## ============================================================================

func _plugin_cache_path() -> String:
	return Sonara.get_config_dir() + "/plugins.json"


## Load cached plugins so the browser is populated before (or without) a scan.
func _load_plugin_cache() -> void:
	var cache_path := _plugin_cache_path()
	if not FileAccess.file_exists(cache_path):
		logger.info("No plugin cache found")
		return

	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(cache_path)) != OK:
		logger.error("Failed to parse plugin cache: %s" % json.get_error_message())
		return
	if not json.data is Dictionary:
		logger.error("Invalid plugin cache format")
		return

	var loaded: Array[Device] = []
	for plugin_data in json.data.get("plugins", []):
		if plugin_data is Dictionary:
			var device := _device_from_cache_data(plugin_data)
			_register(device)
			loaded.append(device)
	logger.info("Loaded %d plugins from cache" % loaded.size())
	if not loaded.is_empty():
		devices_changed.emit(loaded, [] as Array[Device])


func _save_plugin_cache() -> void:
	var cache_path := _plugin_cache_path()
	var plugins: Array = []
	for device in _devices_of_kind(false):
		plugins.append(_device_to_cache_data(device))

	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if not file:
		logger.error("Failed to save plugin cache: %s" % cache_path)
		return
	file.store_string(JSON.stringify({"version": 1, "plugins": plugins}, "\t"))
	file.close()
	logger.info("Saved %d plugins to cache: %s" % [plugins.size(), cache_path])


static func _device_to_cache_data(device: Device) -> Dictionary:
	return {
		"device_id": device.device_id,
		"name": device.name,
		"title": device.title,
		"plugin_path": device.plugin_path,
		"device_type": Device.DeviceType.keys()[device.device_type],
		"category": Device.DeviceCategory.keys()[device.category],
		"version": device.version,
		"description": device.description,
		"author": device.author,
		"accepts_midi": device.accepts_midi,
		"audio_in_channels": device.audio_in_channels,
		"audio_out_channels": device.audio_out_channels,
		"features": device.features
	}


static func _device_from_cache_data(data: Dictionary) -> Device:
	var device_name := str(data.get("name", "Unknown"))
	var type_str := str(data.get("device_type", "CLAP"))
	var device_type: Device.DeviceType = Device.DeviceType.get(type_str, Device.DeviceType.CLAP)
	var category_str := str(data.get("category", "Effect"))
	var category: Device.DeviceCategory = Device.DeviceCategory.get(category_str, Device.DeviceCategory.Effect)

	var device := Device.new(str(data.get("device_id", "")), device_name, category, device_type)
	device.title = data.get("title", device_name)
	device.plugin_path = data.get("plugin_path", "")
	device.version = data.get("version", "1.0")
	device.description = data.get("description", "")
	device.author = data.get("author", "")
	device.accepts_midi = bool(data.get("accepts_midi", false))
	device.audio_in_channels = int(data.get("audio_in_channels", 2))
	device.audio_out_channels = int(data.get("audio_out_channels", 2))
	var features: Array[String] = []
	for tag in data.get("features", []):
		features.append(str(tag))
	device.features = features
	return device
