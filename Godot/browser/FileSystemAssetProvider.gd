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
	_scan_interval = Sonara.get_config("assets/scan_interval_seconds", 5.0)
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
	
	var scan_paths = Sonara.get_config("assets/scan_paths", [])
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
