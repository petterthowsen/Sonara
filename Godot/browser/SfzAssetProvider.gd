# SfzAssetProvider.gd
# Scans `assets/sfz/paths` for SFZ sampler instruments.

class_name SfzAssetProvider extends FileScanAssetProvider


func _init() -> void:
	super()
	provider_name = "SfzAssetProvider"


func _scan_paths_setting() -> String:
	return "assets/sfz/paths"


func _cache_file_name() -> String:
	return "sfz_cache.json"


func _asset_type_for_extension(extension: String) -> int:
	return Asset.TYPE.SFZ if extension == "sfz" else -1
