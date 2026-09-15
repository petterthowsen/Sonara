# FileScanAssetProvider.gd
# Base for providers that walk configured directories for files of known extensions.
# Rescans every `assets/scan_interval_seconds`, reports additions/removals/modifications
# through `assets_changed`, and caches the list as JSON under the config dir.
# Subclasses set `provider_name` and override the three hooks below.

class_name FileScanAssetProvider extends AssetProvider

var logger := Log.make("FileScanAssetProvider")

var _assets: Array[Asset] = []
var _scan_interval: float = 5.0
var _tree: SceneTree
var _first_scan: bool = true


func _init() -> void:
	supports_hot_reload = true


## Settings key holding the directories to scan.
func _scan_paths_setting() -> String:
	push_error("FileScanAssetProvider._scan_paths_setting() is abstract")
	return ""


## Cache file name inside the config dir.
func _cache_file_name() -> String:
	push_error("FileScanAssetProvider._cache_file_name() is abstract")
	return ""


## Asset type for a lower-case file extension, or -1 to skip the file.
func _asset_type_for_extension(_extension: String) -> int:
	return -1


func initialize(tree: SceneTree) -> void:
	_tree = tree
	_scan_interval = Settings.get_value("assets/scan_interval_seconds")
	_load_cache()
	_schedule_next_scan()
	logger.info("[%s] Initialized with %.1f second scan interval" % [provider_name, _scan_interval])


func _schedule_next_scan() -> void:
	if not _tree:
		return
	await _tree.create_timer(_scan_interval).timeout
	scan()
	_schedule_next_scan()


func scan() -> void:
	var new_assets: Array[Asset] = []
	for path in Settings.get_value(_scan_paths_setting()):
		_scan_directory(Utils.expand_path(path), new_assets)

	var changed := _detect_changes(new_assets)
	_assets = new_assets

	if _first_scan:
		logger.info("[%s] Initial scan complete: %d assets found" % [provider_name, _assets.size()])
		_first_scan = false

	if changed:
		_save_cache()


func get_assets() -> Array[Asset]:
	return _assets


# ============================================================================
# DIRECTORY SCANNING
# ============================================================================

func _scan_directory(dir_path: String, results: Array[Asset]) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		logger.warn("[%s] Directory not found: %s" % [provider_name, dir_path])
		return

	var dir := DirAccess.open(dir_path)
	if dir == null:
		logger.error("[%s] Failed to open directory: %s" % [provider_name, dir_path])
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		# Skip hidden files and directories
		if not file_name.begins_with("."):
			var full_path := dir_path.path_join(file_name)
			if dir.current_is_dir():
				_scan_directory(full_path, results)
			else:
				var asset := _try_create_asset(full_path)
				if asset:
					results.append(asset)
		file_name = dir.get_next()


func _try_create_asset(file_path: String) -> Asset:
	var extension := file_path.get_extension().to_lower()
	var asset_type := _asset_type_for_extension(extension)
	if asset_type < 0:
		return null

	var asset := Asset.new()
	asset.type = asset_type as Asset.TYPE
	asset.path = file_path
	asset.name = file_path.get_file().trim_suffix("." + file_path.get_extension())

	var file := FileAccess.open(file_path, FileAccess.READ)
	if file:
		asset.file_size_bytes = file.get_length()
		asset.file_modified_time = FileAccess.get_modified_time(file_path)
	return asset


# ============================================================================
# HOT-RELOAD DETECTION
# ============================================================================

## Emit `assets_changed` for differences against the previous scan. Returns true if anything changed.
func _detect_changes(new_assets: Array[Asset]) -> bool:
	var added: Array[Asset] = []
	var removed: Array[Asset] = []
	var modified: Array[Asset] = []

	var old_by_path: Dictionary[String, Asset] = {}
	for old_asset in _assets:
		old_by_path[old_asset.path] = old_asset

	var new_paths: Dictionary[String, bool] = {}
	for asset in new_assets:
		new_paths[asset.path] = true
		if not old_by_path.has(asset.path):
			added.append(asset)
		elif asset.file_modified_time != old_by_path[asset.path].file_modified_time:
			modified.append(asset)

	for old_asset in _assets:
		if not new_paths.has(old_asset.path):
			removed.append(old_asset)

	if added.is_empty() and removed.is_empty() and modified.is_empty():
		return false
	logger.info("[%s] Assets changed: +%d, -%d, ~%d" % [provider_name, added.size(), removed.size(), modified.size()])
	assets_changed.emit(added, removed, modified)
	return true


# ============================================================================
# CACHING
# ============================================================================

func _cache_path() -> String:
	return Sonara.get_config_dir().path_join(_cache_file_name())


func _load_cache() -> void:
	var cache_path := _cache_path()
	if not FileAccess.file_exists(cache_path):
		logger.info("[%s] No cache found" % provider_name)
		return

	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(cache_path)) != OK:
		push_error("[%s] Failed to parse cache: %s" % [provider_name, json.get_error_message()])
		return
	if not json.data is Dictionary:
		push_error("[%s] Invalid cache format" % provider_name)
		return

	for asset_data in json.data.get("assets", []):
		if not asset_data is Dictionary:
			continue
		var path := str(asset_data.get("path", ""))
		var asset_type := _asset_type_for_extension(path.get_extension().to_lower())
		if asset_type < 0:
			continue
		var asset := Asset.new()
		asset.type = asset_type as Asset.TYPE
		asset.path = path
		asset.name = asset_data.get("name", "")
		asset.file_size_bytes = asset_data.get("file_size_bytes", 0)
		asset.file_modified_time = asset_data.get("file_modified_time", 0)
		_assets.append(asset)

	logger.info("[%s] Loaded %d assets from cache" % [provider_name, _assets.size()])
	if not _assets.is_empty():
		assets_changed.emit(_assets, [] as Array[Asset], [] as Array[Asset])


func _save_cache() -> void:
	var cached_assets: Array = []
	for asset in _assets:
		cached_assets.append({
			"type": asset.type,
			"path": asset.path,
			"name": asset.name,
			"file_size_bytes": asset.file_size_bytes,
			"file_modified_time": asset.file_modified_time
		})

	var cache_path := _cache_path()
	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if not file:
		push_error("[%s] Failed to save cache: %s" % [provider_name, cache_path])
		return
	file.store_string(JSON.stringify({"version": 1, "assets": cached_assets}, "\t"))
	file.close()
