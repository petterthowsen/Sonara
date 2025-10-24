# DeviceAssetProvider.gd
# Discovers and manages plugin/device assets (LV2, CLAP, built-in, etc.)
# Phase 2: Built-in devices
# Phase 4: Plugin discovery (LV2, CLAP, VST3)

class_name DeviceAssetProvider extends AssetProvider

var _assets: Array[Asset] = []
var _devices: Dictionary = {}  # device_id -> Device (both built-in and plugins)


func _init() -> void:
	provider_name = "DeviceAssetProvider"
	supports_hot_reload = false


func initialize(_tree: SceneTree) -> void:
	print("[DeviceAssetProvider] Initialized")
	_register_builtin_devices()
	_setup_osc_listeners()
	_trigger_plugin_scan()


func scan() -> void:
	"""Rebuild asset list from current device registry (both built-in and plugins)."""
	print("[DeviceAssetProvider] Scanning devices...")
	_assets.clear()

	for device in _devices.values():
		var asset = Asset.new()
		asset.type = Asset.TYPE.Device
		asset.name = device.name
		asset.path = device.device_id
		_assets.append(asset)

	print("[DeviceAssetProvider] Found %d devices" % _assets.size())


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
		Device.create_builtin_delay()
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
	
	AudioEngineOSC.listen("/plugin/info", _on_plugin_info_received)
	AudioEngineOSC.listen("/plugin/scan_complete", _on_plugin_scan_complete)
	print("[DeviceAssetProvider] OSC listeners registered")


## Trigger plugin scan via OSC
func _trigger_plugin_scan() -> void:
	if not AudioEngineOSC:
		push_warning("[DeviceAssetProvider] AudioEngineOSC not available")
		return
	
	print("[DeviceAssetProvider] Triggering plugin scan...")
	AudioEngineOSC.send("/plugin/scan", [])


## Handle incoming plugin info from OSC (asynchronous, arrives during scan)
func _on_plugin_info_received(args: Array) -> void:
	if args.size() < 6:
		push_warning("[DeviceAssetProvider] Invalid /plugin/info message: %s" % str(args))
		return
	
	var plugin_id: String = args[0]
	var plugin_name: String = args[1]
	var vendor: String = args[2]
	var version: String = args[3]
	var category_str: String = args[4]
	var description: String = args[5]
	
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
	
	# Determine MIDI support and audio channels based on category
	if category == Device.DeviceCategory.Instrument:
		device.accepts_midi = true
		device.audio_in_channels = 0
		device.audio_out_channels = 2
	else:
		device.accepts_midi = false
		device.audio_in_channels = 2
		device.audio_out_channels = 2
	
	# Add to device registry
	_devices[plugin_id] = device
	
	# Create asset and add to list
	var asset = Asset.new()
	asset.type = Asset.TYPE.Device
	asset.name = device.name
	asset.path = device.device_id
	_assets.append(asset)
	
	# Emit signal for this new plugin
	assets_changed.emit([asset] as Array[Asset], [] as Array[Asset], [] as Array[Asset])


## Handle plugin scan completion
func _on_plugin_scan_complete(args: Array) -> void:
	if args.size() < 1:
		push_warning("[DeviceAssetProvider] Invalid /plugin/scan_complete message")
		return
	
	var count: int = args[0]
	print("[DeviceAssetProvider] Plugin scan complete: %d total plugins discovered" % count)