# PresetAssetProvider.gd
# Scans the presets folder (`presets/path`) for device presets (.sonpreset). Only the header is
# read, so the browser can list, search and grey out presets without opening each file twice.

class_name PresetAssetProvider extends FileScanAssetProvider


func _init() -> void:
	super()
	provider_name = "PresetAssetProvider"


func _scan_paths_setting() -> String:
	return "presets/path"


func _scan_roots() -> Array:
	# The root is created on first save, so a missing folder is normal and not worth a warning.
	var root := PresetLibrary.root_dir()
	return [root] if DirAccess.dir_exists_absolute(root) else []


func _cache_file_name() -> String:
	return "preset_cache.json"


func _asset_type_for_extension(extension: String) -> int:
	return Asset.TYPE.Preset if extension == "sonpreset" else -1


func _try_create_asset(file_path: String) -> Asset:
	var asset := super(file_path)
	if asset == null:
		return null
	var header := DevicePreset.read_header(file_path)
	if header == null:
		logger.warn("[%s] Skipping unreadable preset: %s" % [provider_name, file_path])
		return null
	asset.name = header.name
	asset.device_id = header.device_id
	asset.device_name = header.device_name
	asset.author = header.author
	for tag in header.tags:
		asset.tags.append(tag)
	return asset


func _cache_extra(asset: Asset) -> Dictionary:
	return {
		"device_id": asset.device_id,
		"device_name": asset.device_name,
		"author": asset.author,
		"tags": asset.tags,
	}


func _restore_extra(asset: Asset, data: Dictionary) -> void:
	asset.device_id = str(data.get("device_id", ""))
	asset.device_name = str(data.get("device_name", ""))
	asset.author = str(data.get("author", ""))
	for tag in data.get("tags", []):
		asset.tags.append(str(tag))
