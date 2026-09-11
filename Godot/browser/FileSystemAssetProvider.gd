# FileSystemAssetProvider.gd
# Scans configured directories for audio and MIDI files
# Supports hot-reload by monitoring file modification times

class_name FileSystemAssetProvider extends AssetProvider

# ============================================================================
# PROPERTIES
# ============================================================================

# Supported file extensions
var AUDIO_EXTENSIONS = ["wav", "mp3", "ogg"]
var MIDI_EXTENSIONS = ["mid", "midi"]

# All assets discovered by this provider
var _assets: Array[Asset] = []

# Track file modification times for hot-reload detection
var _file_mod_times: Dictionary[String, int] = {}

# Hot-reload monitoring
var _scan_interval: float = 5.0
var _tree: SceneTree
var _first_scan: bool = true  # Track if this is the first scan


# ============================================================================
# LIFECYCLE
# ============================================================================

func _init() -> void:
	provider_name = "FileSystemAssetProvider"
	supports_hot_reload = true


func initialize(tree: SceneTree) -> void:
	print("[FileSystemAssetProvider] Initializing...")
	_tree = tree
	_scan_interval = Sonara.get_config("assets/scan_interval_seconds", 30.0)
	_load_cache()
	_setup_hot_reload()
	print("[FileSystemAssetProvider] Initialized with %.1f second scan interval" % _scan_interval)


func _setup_hot_reload() -> void:
	if not _tree:
		return

	# Schedule recurring scans using get_tree().create_timer()
	_schedule_next_scan()


func _schedule_next_scan() -> void:
	if not _tree:
		return

	await _tree.create_timer(_scan_interval).timeout
	scan()
	_schedule_next_scan()  # Schedule the next scan


func scan() -> void:
	if _first_scan:
		print("[FileSystemAssetProvider] Starting initial asset scan...")
	
	var scan_paths = Sonara.get_config("assets/samples/paths", [])
	var new_assets: Array[Asset] = []

	for path in scan_paths:
		var expanded_path = _expand_path(path)
		_scan_directory(expanded_path, new_assets)

	# Detect changes (logs only if assets added/removed/changed)
	_detect_changes(new_assets)
	_assets = new_assets
	
	if _first_scan:
		print("[FileSystemAssetProvider] Initial scan complete: %d assets found" % _assets.size())
		_first_scan = false
	
	# Save cache after scan
	_save_cache()


func get_assets() -> Array[Asset]:
	return _assets


## Expand path variables (e.g., ~ to home directory)
func _expand_path(path: String) -> String:
	if path.begins_with("~/"):
		# Replace ~ with user home directory
		var home = OS.get_environment("HOME")
		if home:
			return path.replace("~/", home + "/")
	return path


# ============================================================================
# DIRECTORY SCANNING
# ============================================================================

func _scan_directory(dir_path: String, results: Array[Asset]) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		print("[FileSystemAssetProvider] Directory not found: %s" % dir_path)
		return

	var dir = DirAccess.open(dir_path)
	if dir == null:
		print("[FileSystemAssetProvider] Failed to open directory: %s" % dir_path)
		return

	# List all files and directories
	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		# Skip hidden files/directories
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue

		var full_path = dir_path.path_join(file_name)

		# Recursively scan subdirectories
		if dir.current_is_dir():
			_scan_directory(full_path, results)
		else:
			# Check if file is supported
			var asset = _try_create_asset(full_path)
			if asset:
				results.append(asset)

		file_name = dir.get_next()


func _try_create_asset(file_path: String) -> Asset:
	var extension = file_path.get_extension().to_lower()

	# Determine asset type based on extension
	var asset_type: Asset.TYPE
	if extension in AUDIO_EXTENSIONS:
		asset_type = Asset.TYPE.Audio
	elif extension in MIDI_EXTENSIONS:
		asset_type = Asset.TYPE.Midi
	else:
		return null

	# Create asset
	var asset = Asset.new()
	asset.type = asset_type
	asset.path = file_path
	asset.name = file_path.get_file().trim_suffix("." + extension)

	# Get file info
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file:
		asset.file_size_bytes = file.get_length()
		asset.file_modified_time = FileAccess.get_modified_time(file_path)
		_file_mod_times[file_path] = asset.file_modified_time

	return asset


# ============================================================================
# HOT-RELOAD DETECTION
# ============================================================================

func _detect_changes(new_assets: Array[Asset]) -> void:
	var added: Array[Asset] = []
	var removed: Array[Asset] = []
	var modified: Array[Asset] = []

	# Find added/modified assets
	for asset in new_assets:
		var old_mod_time = _file_mod_times.get(asset.path, 0)

		if old_mod_time == 0:
			# New asset
			added.append(asset)
		elif asset.file_modified_time != old_mod_time:
			# Modified asset
			modified.append(asset)

	# Find removed assets (in old list but not in new list)
	var new_paths = new_assets.map(func(a): return a.path)
	for old_asset in _assets:
		if not old_asset.path in new_paths:
			removed.append(old_asset)
			_file_mod_times.erase(old_asset.path)

	# Emit signal if changes detected
	if added.size() > 0 or removed.size() > 0 or modified.size() > 0:
		print("[FileSystemAssetProvider] Assets changed: +%d, -%d, ~%d" % [added.size(), removed.size(), modified.size()])
		assets_changed.emit(added, removed, modified)


# ============================================================================
# CACHING
# ============================================================================

func _get_cache_path() -> String:
	return Sonara.get_config_dir() + "/samples_cache.json"


func _load_cache() -> void:
	var cache_path = _get_cache_path()
	if not FileAccess.file_exists(cache_path):
		print("[FileSystemAssetProvider] No cache found")
		return
	
	var file = FileAccess.open(cache_path, FileAccess.READ)
	if not file:
		push_error("[FileSystemAssetProvider] Failed to open cache: %s" % cache_path)
		return
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(json_string)
	if error != OK:
		push_error("[FileSystemAssetProvider] Failed to parse cache: %s" % json.get_error_message())
		return
	
	var cache_data = json.data
	if not cache_data is Dictionary:
		push_error("[FileSystemAssetProvider] Invalid cache format")
		return
	
	# Load assets from cache
	var cached_assets = cache_data.get("assets", [])
	for asset_data in cached_assets:
		if not asset_data is Dictionary:
			continue
		
		var asset = Asset.new()
		asset.type = asset_data.get("type", Asset.TYPE.Audio)
		asset.path = asset_data.get("path", "")
		asset.name = asset_data.get("name", "")
		asset.file_size_bytes = asset_data.get("file_size_bytes", 0)
		asset.file_modified_time = asset_data.get("file_modified_time", 0)
		
		_assets.append(asset)
		_file_mod_times[asset.path] = asset.file_modified_time
	
	print("[FileSystemAssetProvider] Loaded %d assets from cache" % _assets.size())
	
	# Emit assets_changed for cached assets
	if not _assets.is_empty():
		assets_changed.emit(_assets, [] as Array[Asset], [] as Array[Asset])


func _save_cache() -> void:
	var cache_path = _get_cache_path()
	
	# Convert assets to cache data
	var cached_assets = []
	for asset in _assets:
		cached_assets.append({
			"type": asset.type,
			"path": asset.path,
			"name": asset.name,
			"file_size_bytes": asset.file_size_bytes,
			"file_modified_time": asset.file_modified_time
		})
	
	var cache_data = {
		"version": 1,
		"assets": cached_assets
	}
	
	var file = FileAccess.open(cache_path, FileAccess.WRITE)
	if not file:
		push_error("[FileSystemAssetProvider] Failed to save cache: %s" % cache_path)
		return
	
	var json_string = JSON.stringify(cache_data, "\t")
	file.store_string(json_string)
	file.close()
