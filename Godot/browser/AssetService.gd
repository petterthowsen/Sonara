# AssetService.gd
# Central singleton for asset discovery and management
# Manages multiple asset providers (FileSystem, Devices, etc.)
# Should be added as autoload in project settings

extends Node

# ============================================================================
# SIGNALS
# ============================================================================

signal assets_updated  # Emitted when any assets change
signal asset_added(asset: Asset)
signal asset_removed(asset: Asset)
signal asset_modified(asset: Asset)


# ============================================================================
# PROPERTIES
# ============================================================================

# All providers managed by this service
var _providers: Array[AssetProvider] = []

# All discovered assets (keyed by path for fast lookup)
var _assets_by_path: Dictionary[String, Asset] = {}

# Asset metadata cache (favorites, tags, last_used)
# Structure: { "asset_path": { "favorite": bool, "tags": Array, "last_used": int } }
var _asset_metadata: Dictionary = {}

# Whether service is ready
var _is_ready: bool = false
var _is_scanning: bool = false


# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	print("[AssetService] Initializing...")
	_load_asset_cache()
	_setup_default_config()
	_initialize_providers()
	
	# Connect to Settings autoload for runtime updates
	var settings = get_node_or_null("/root/Settings")
	if settings:
		settings.connect("setting_changed", _on_setting_changed)
	
	print("[AssetService] Ready")


func _exit_tree() -> void:
	# Cleanup providers
	for provider in _providers:
		if provider:
			provider.assets_changed.disconnect(_on_provider_assets_changed)


# ============================================================================
# PROVIDER MANAGEMENT
# ============================================================================

## Initialize all configured providers
func _initialize_providers() -> void:
	_providers.clear()

	var enabled_providers = Sonara.get_config("assets/enabled_providers", ["filesystem", "devices", "sfz"])

	# File system provider
	if "filesystem" in enabled_providers:
		var fs_provider = FileSystemAssetProvider.new()
		fs_provider.assets_changed.connect(_on_provider_assets_changed)
		fs_provider.initialize(get_tree())  # Pass SceneTree for timer management
		_providers.append(fs_provider)
		print("[AssetService] Registered FileSystemAssetProvider")

	# Device provider (stub)
	if "devices" in enabled_providers:
		var device_provider = DeviceAssetProvider.new()
		device_provider.assets_changed.connect(_on_provider_assets_changed)
		device_provider.initialize(get_tree())
		_providers.append(device_provider)
		print("[AssetService] Registered DeviceAssetProvider")

	# SFZ sampler provider
	if "sfz" in enabled_providers:
		var sfz_provider = SfzAssetProvider.new()
		sfz_provider.assets_changed.connect(_on_provider_assets_changed)
		sfz_provider.initialize(get_tree())
		_providers.append(sfz_provider)
		print("[AssetService] Registered SfzAssetProvider")

	# Skip initial scan - rely on cache and hot-reload timers
	# Users can manually trigger scan via Edit > Scan Assets
	print("[AssetService] Skipping initial scan, relying on cached data")
	_is_ready = true


## Trigger scan on all providers
func scan() -> void:
	_scan_all_providers()


func _scan_all_providers() -> void:
	if _is_scanning:
		return

	_is_scanning = true
	print("[AssetService] Starting asset scan...")

	# Clear previous assets
	_assets_by_path.clear()

	# Scan all providers
	for provider in _providers:
		provider.scan()
		_consolidate_provider_assets(provider)

	_is_ready = true
	_is_scanning = false
	assets_updated.emit()
	print("[AssetService] Asset scan complete: %d assets found" % _assets_by_path.size())


## Consolidate assets from a provider into the main asset registry
func _consolidate_provider_assets(provider: AssetProvider) -> void:
	var assets = provider.get_assets()
	for asset in assets:
		_assets_by_path[asset.path] = asset


# ============================================================================
# ASSET QUERIES
# ============================================================================

## Get all discovered assets
func get_all_assets() -> Array[Asset]:
	return _assets_by_path.values()


## Get all assets of a specific type
func get_assets_by_type(type: Asset.TYPE) -> Array[Asset]:
	var result: Array[Asset] = []
	for asset in _assets_by_path.values():
		if asset.type == type:
			result.append(asset)
	return result


## Find an asset by path
func find_asset(path: String) -> Asset:
	return _assets_by_path.get(path)


## Get all audio assets
func get_audio_assets() -> Array[Asset]:
	return get_assets_by_type(Asset.TYPE.Audio)


## Get all MIDI assets
func get_midi_assets() -> Array[Asset]:
	return get_assets_by_type(Asset.TYPE.Midi)


## Get all device assets
func get_device_assets() -> Array[Asset]:
	return get_assets_by_type(Asset.TYPE.Device)


## Get all SFZ assets
func get_sfz_assets() -> Array[Asset]:
	return get_assets_by_type(Asset.TYPE.SFZ)


## Get all SoundFont assets
func get_soundfont_assets() -> Array[Asset]:
	return get_assets_by_type(Asset.TYPE.SoundFont)


## Get device by ID (for built-in or plugin devices)
func get_device(device_id: String) -> Device:
	# Try to find in asset registry first
	var asset = find_asset(device_id)
	if asset and asset.type == Asset.TYPE.Device:
		# Get the actual Device object from the provider
		for provider in _providers:
			if provider is DeviceAssetProvider:
				return (provider as DeviceAssetProvider).get_builtin_device(device_id)
	return null


## Get all available device categories (instruments, effects, utilities)
func get_instruments() -> Array[Device]:
	var result: Array[Device] = []
	for provider in _providers:
		if provider is DeviceAssetProvider:
			for device in (provider as DeviceAssetProvider).get_builtin_devices():
				if device.category == Device.DeviceCategory.Instrument:
					result.append(device)
	return result


func get_effects() -> Array[Device]:
	var result: Array[Device] = []
	for provider in _providers:
		if provider is DeviceAssetProvider:
			for device in (provider as DeviceAssetProvider).get_builtin_devices():
				if device.category == Device.DeviceCategory.Effect:
					result.append(device)
	return result


## Check if service is ready
func is_ready() -> bool:
	return _is_ready


## Manually trigger plugin scan
func scan_plugins() -> void:
	print("[AssetService] Manually triggering plugin scan...")
	for provider in _providers:
		if provider is DeviceAssetProvider:
			(provider as DeviceAssetProvider).trigger_plugin_scan()
			return
	push_warning("[AssetService] No DeviceAssetProvider found")


# ============================================================================
# METADATA MANAGEMENT
# ============================================================================

## Mark asset as favorite
func set_favorite(asset_path: String, is_favorite: bool) -> void:
	if not _asset_metadata.has(asset_path):
		_asset_metadata[asset_path] = {}

	_asset_metadata[asset_path]["favorite"] = is_favorite
	_save_asset_cache()

	var asset = find_asset(asset_path)
	if asset:
		asset.favorite = is_favorite


## Add tag to asset
func add_tag(asset_path: String, tag: String) -> void:
	if not _asset_metadata.has(asset_path):
		_asset_metadata[asset_path] = {}

	var tags: Array[String] = _asset_metadata[asset_path].get("tags", [])
	if not tag in tags:
		tags.append(tag)

	_asset_metadata[asset_path]["tags"] = tags
	_save_asset_cache()

	var asset = find_asset(asset_path)
	if asset:
		asset.tags = tags


## Remove tag from asset
func remove_tag(asset_path: String, tag: String) -> void:
	if not _asset_metadata.has(asset_path):
		return

	var tags: Array[String] = _asset_metadata[asset_path].get("tags", [])
	tags.erase(tag)

	_asset_metadata[asset_path]["tags"] = tags
	_save_asset_cache()

	var asset = find_asset(asset_path)
	if asset:
		asset.tags = tags


## Record asset as used
func mark_asset_used(asset_path: String) -> void:
	if not _asset_metadata.has(asset_path):
		_asset_metadata[asset_path] = {}

	_asset_metadata[asset_path]["last_used"] = Time.get_unix_time_from_system()
	_save_asset_cache()

	var asset = find_asset(asset_path)
	if asset:
		asset.mark_as_used()


## Load metadata for an asset from cache
func _load_asset_metadata(asset: Asset) -> void:
	if _asset_metadata.has(asset.path):
		var asset_meta = _asset_metadata[asset.path]
		asset.favorite = asset_meta.get("favorite", false)
		asset.tags = asset_meta.get("tags", [] as Array[String])
		asset.last_used = asset_meta.get("last_used", 0)


# ============================================================================
# PROVIDER CALLBACKS
# ============================================================================

func _on_provider_assets_changed(added: Array[Asset], removed: Array[Asset], modified: Array[Asset]) -> void:
	# Update asset registry
	for asset in added:
		_load_asset_metadata(asset)  # Load metadata from config
		_assets_by_path[asset.path] = asset
		asset_added.emit(asset)

	for asset in removed:
		_assets_by_path.erase(asset.path)
		asset_removed.emit(asset)

	for asset in modified:
		_load_asset_metadata(asset)  # Reload metadata
		asset_modified.emit(asset)

	# Notify listeners
	if added.size() > 0 or removed.size() > 0 or modified.size() > 0:
		assets_updated.emit()


# ============================================================================
# CONFIGURATION
# ============================================================================

## Setup default configuration if not already present
func _setup_default_config() -> void:
	# Ensure assets config structure exists
	if not Sonara.config.has("assets"):
		var default_config = {
			"samples": {
				"paths": ["~/Music"]
			},
			"sfz": {
				"paths": ["~/Music/SFZ"]
			},
			"scan_interval_seconds": 30.0,
			"enabled_providers": ["filesystem", "devices", "sfz"]
		}
		Sonara.set_config("assets", default_config)
		Sonara.save_config()
		print("[AssetService] Created default asset configuration")


# ============================================================================
# ASSET CACHE (assets.json)
# ============================================================================

## Get the assets cache file path
func _get_asset_cache_path() -> String:
	return Sonara.get_config_dir() + "/assets.json"


## Load asset metadata cache from disk
func _load_asset_cache() -> void:
	var cache_path = _get_asset_cache_path()
	if FileAccess.file_exists(cache_path):
		var file = FileAccess.open(cache_path, FileAccess.READ)
		if file:
			var json_string = file.get_as_text()
			file.close()
			
			var json = JSON.new()
			var error = json.parse(json_string)
			if error == OK:
				_asset_metadata = json.data
				print("[AssetService] Asset cache loaded from: ", cache_path)
			else:
				push_error("[AssetService] Failed to parse asset cache JSON: " + json.get_error_message())
				_asset_metadata = {}
		else:
			push_error("[AssetService] Failed to open asset cache file: " + cache_path)
			_asset_metadata = {}
	else:
		print("[AssetService] No asset cache found, starting fresh")
		_asset_metadata = {}


## Save asset metadata cache to disk
func _save_asset_cache() -> void:
	var cache_path = _get_asset_cache_path()
	var file = FileAccess.open(cache_path, FileAccess.WRITE)
	if file:
		var json_string = JSON.stringify(_asset_metadata, "\t")
		file.store_string(json_string)
		file.close()
		# Cache saved silently (too verbose to log every time)
	else:
		push_error("[AssetService] Failed to save asset cache to: " + cache_path)


# ---------------------------------------------------------------------------
# Settings synchronization
# ---------------------------------------------------------------------------

func _on_setting_changed(key: String, value) -> void:
	"""React to live setting changes from the Settings dialog."""
	if key == "assets/scan_interval_seconds":
		for provider in _providers:
			if provider is FileSystemAssetProvider:
				provider._scan_interval = float(value)
			elif provider is SfzAssetProvider:
				provider._scan_interval = float(value)
