# DeviceAssetProvider.gd
# Discovers and manages plugin/device assets (LV2, CLAP, built-in, etc.)
# Phase 2: Built-in devices
# Phase 4: Plugin discovery (LV2, CLAP, VST3)

class_name DeviceAssetProvider extends AssetProvider

var _assets: Array[Asset] = []
var _devices: Dictionary = {}  # device_id -> Device (both built-in and plugins)
var _plugin_cache_loaded: bool = false


func _init() -> void:
	provider_name = "DeviceAssetProvider"
	supports_hot_reload = false


func initialize(_tree: SceneTree) -> void:
	print("[DeviceAssetProvider] Initialized")
	_register_builtin_devices()
	_load_plugin_cache()
	_setup_osc_listeners()
	# Don't auto-scan plugins - user must manually trigger via menu
	# _trigger_plugin_scan()


func scan() -> void:
	"""Rebuild asset list from current device registry (both built-in and plugins)."""
	_assets.clear()

	for device in _devices.values():
		var asset = Asset.new()
		asset.type = Asset.TYPE.Device
		asset.name = device.name
		asset.path = device.device_id
		_assets.append(asset)

	print("[DeviceAssetProvider] Scanned %d devices" % _assets.size())


func get_assets() -> Array[Asset]:
	return _assets


## ============================================================================
## BUILT-IN DEVICE REGISTRATION
## ============================================================================

## Register all built-in devices (synchronous, called at initialization)
func _register_builtin_devices() -> void:
	# Create built-in devices
	var builtin_list = [
		Device.create_builtin_oscillator(),
		Device.create_builtin_delay(),
		Device.create_builtin_sfizz()
	]
	
	# Add to device registry
	for device in builtin_list:
		_devices[device.device_id] = device
	
	print("[DeviceAssetProvider] Registered %d built-in devices" % builtin_list.size())
	
	# Trigger initial scan to populate assets
	scan()
	
	# Emit signal for initial built-in devices
	var added_assets: Array[Asset] = []
	for device in builtin_list:
		var asset = Asset.new()
		asset.type = Asset.TYPE.Device
		asset.name = device.name
		asset.path = device.device_id
		added_assets.append(asset)
	
	assets_changed.emit(added_assets, [] as Array[Asset], [] as Array[Asset])


## Get a device by ID (built-in or plugin)
func get_builtin_device(device_id: String) -> Device:
	return _devices.get(device_id)


## ============================================================================
## OSC PLUGIN DISCOVERY
## ============================================================================

## Setup OSC listeners for plugin discovery messages
func _setup_osc_listeners() -> void:
	if not AudioEngineOSC:
		push_warning("[DeviceAssetProvider] AudioEngineOSC not available")
		return
	
	print("[DeviceAssetProvider] Registering OSC listeners...")
	AudioEngineOSC.listen("/plugin/info", _on_plugin_info_received)
	AudioEngineOSC.listen("/plugin/scan_complete", _on_plugin_scan_complete)
	print("[DeviceAssetProvider] OSC listeners registered for /plugin/info and /plugin/scan_complete")


## Trigger plugin scan via OSC (public method for manual triggering)
func trigger_plugin_scan() -> void:
	if not AudioEngineOSC:
		push_warning("[DeviceAssetProvider] AudioEngineOSC not available")
		return
	
	print("[DeviceAssetProvider] Triggering plugin scan...")
	
	# Find old plugin assets to remove
	var old_plugin_assets: Array[Asset] = []
	for asset in _assets:
		var device = _devices.get(asset.path)
		if device and device.device_type != Device.DeviceType.BuiltIn:
			old_plugin_assets.append(asset)
	
	# Clear existing plugins (keep built-in devices)
	var builtin_devices = {}
	for device_id in _devices.keys():
		var device = _devices[device_id]
		if device.device_type == Device.DeviceType.BuiltIn:
			builtin_devices[device_id] = device
	
	_devices = builtin_devices
	print("[DeviceAssetProvider] Cleared old plugins, keeping %d built-in devices" % builtin_devices.size())
	
	# Rebuild assets list with only built-ins
	scan()
	
	# Emit removal of old plugin assets
	if not old_plugin_assets.is_empty():
		print("[DeviceAssetProvider] Removing %d old plugin assets" % old_plugin_assets.size())
		assets_changed.emit([] as Array[Asset], old_plugin_assets, [] as Array[Asset])
	
	# Send scan request
	AudioEngineOSC.send("/plugin/scan", [])


## Handle incoming plugin info from OSC (asynchronous, arrives during scan)
func _on_plugin_info_received(args: Array) -> void:
	if args.size() < 7:
		push_warning("[DeviceAssetProvider] Invalid /plugin/info message: %s" % str(args))
		return
	
	var plugin_id: String = args[0]
	var plugin_name: String = args[1]
	var vendor: String = args[2]
	var version: String = args[3]
	var category_str: String = args[4]
	var description: String = args[5]
	var plugin_path: String = args[6]
	
	# Map category string to Device.DeviceCategory
	var category: Device.DeviceCategory
	match category_str:
		"instrument":
			category = Device.DeviceCategory.Instrument
		"effect":
			category = Device.DeviceCategory.Effect
		"utility":
			category = Device.DeviceCategory.Utility
		_:
			category = Device.DeviceCategory.Effect  # Default
	
	# Create Device object
	var device = Device.new(plugin_id, plugin_name, category, Device.DeviceType.CLAP)
	device.author = vendor
	device.version = version
	device.description = description if description != "" else "CLAP Plugin"
	device.title = plugin_name
	device.plugin_path = plugin_path
	
	# Determine MIDI support and audio channels based on category
	if category == Device.DeviceCategory.Instrument:
		device.accepts_midi = true
		device.audio_in_channels = 0
		device.audio_out_channels = 2
	else:
		device.accepts_midi = false
		device.audio_in_channels = 2
		device.audio_out_channels = 2
	
	# Add to device registry (overwrites if already exists)
	_devices[plugin_id] = device
	# Don't log each plugin individually - too verbose


## Handle plugin scan completion
func _on_plugin_scan_complete(args: Array) -> void:
	if args.size() < 1:
		push_warning("[DeviceAssetProvider] Invalid /plugin/scan_complete message")
		return
	
	var count: int = args[0]
	print("[DeviceAssetProvider] Plugin scan complete: %d total plugins discovered" % count)
	
	# Rebuild asset list from devices
	scan()
	
	# Emit assets_changed for all plugin assets (exclude built-in)
	var plugin_assets: Array[Asset] = []
	for asset in _assets:
		var device = _devices.get(asset.path)
		if device and device.device_type != Device.DeviceType.BuiltIn:
			plugin_assets.append(asset)
	
	if not plugin_assets.is_empty():
		print("[DeviceAssetProvider] Emitting %d plugin assets" % plugin_assets.size())
		assets_changed.emit(plugin_assets, [] as Array[Asset], [] as Array[Asset])
	
	# Save discovered plugins to cache
	_save_plugin_cache()


## ============================================================================
## PLUGIN CACHING
## ============================================================================

## Load cached plugins from disk (so we don't need to scan every time)
func _load_plugin_cache() -> void:
	var cache_path = _get_plugin_cache_path()
	if not FileAccess.file_exists(cache_path):
		print("[DeviceAssetProvider] No plugin cache found")
		return
	
	var file = FileAccess.open(cache_path, FileAccess.READ)
	if not file:
		push_error("[DeviceAssetProvider] Failed to open plugin cache: %s" % cache_path)
		return
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_string)
	if error != OK:
		push_error("[DeviceAssetProvider] Failed to parse plugin cache: %s" % json.get_error_message())
		return
	
	var cache_data = json.data
	if not cache_data is Dictionary:
		push_error("[DeviceAssetProvider] Invalid plugin cache format")
		return
	
	# Load plugins from cache
	var plugins = cache_data.get("plugins", [])
	for plugin_data in plugins:
		if not plugin_data is Dictionary:
			continue
		
		var device = _device_from_cache_data(plugin_data)
		if device:
			_devices[device.device_id] = device
			
			# Create asset
			var asset = Asset.new()
			asset.type = Asset.TYPE.Device
			asset.name = device.name
			asset.path = device.device_id
			_assets.append(asset)
	
	print("[DeviceAssetProvider] Loaded %d plugins from cache" % plugins.size())
	_plugin_cache_loaded = true
	
	# Emit assets_changed for cached plugins
	if not _assets.is_empty():
		# Get only plugin assets (exclude built-in)
		var plugin_assets: Array[Asset] = []
		for asset in _assets:
			var device = _devices.get(asset.path)
			if device and device.device_type != Device.DeviceType.BuiltIn:
				plugin_assets.append(asset)
		
		if not plugin_assets.is_empty():
			assets_changed.emit(plugin_assets, [] as Array[Asset], [] as Array[Asset])


## Save discovered plugins to cache
func _save_plugin_cache() -> void:
	var cache_path = _get_plugin_cache_path()
	# Collect plugin devices (exclude built-in)
	var plugins = []
	for device in _devices.values():
		if device.device_type != Device.DeviceType.BuiltIn:
			plugins.append(_device_to_cache_data(device))
	
	var cache_data = {
		"version": 1,
		"plugins": plugins
	}
	
	var file = FileAccess.open(cache_path, FileAccess.WRITE)
	if not file:
		push_error("[DeviceAssetProvider] Failed to save plugin cache: %s" % cache_path)
		return
	
	var json_string = JSON.stringify(cache_data, "\t")
	file.store_string(json_string)
	file.close()
	
	print("[DeviceAssetProvider] ✓ Saved %d plugins to cache: %s" % [plugins.size(), cache_path])


## Get the plugin cache file path
func _get_plugin_cache_path() -> String:
	return Sonara.get_config_dir() + "/plugins.json"


## Convert Device to cache data
func _device_to_cache_data(device: Device) -> Dictionary:
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
		"audio_out_channels": device.audio_out_channels
	}


## Create Device from cache data
func _device_from_cache_data(data: Dictionary) -> Device:
	var device_id = data.get("device_id", "")
	var name = data.get("name", "Unknown")
	
	# Parse device type
	var device_type_str = data.get("device_type", "CLAP")
	var device_type = Device.DeviceType.get(device_type_str) if Device.DeviceType.has(device_type_str) else Device.DeviceType.CLAP
	
	# Parse category
	var category_str = data.get("category", "Effect")
	var category = Device.DeviceCategory.get(category_str) if Device.DeviceCategory.has(category_str) else Device.DeviceCategory.Effect
	
	var device = Device.new(device_id, name, category, device_type)
	device.title = data.get("title", name)
	device.plugin_path = data.get("plugin_path", "")
	device.version = data.get("version", "1.0")
	device.description = data.get("description", "")
	device.author = data.get("author", "")
	device.accepts_midi = data.get("accepts_midi", false)
	device.audio_in_channels = data.get("audio_in_channels", 2)
	device.audio_out_channels = data.get("audio_out_channels", 2)
	
	return device