# AssetProvider.gd
# Abstract base class for asset discovery and monitoring
# Concrete providers (FileSystemAssetProvider, DeviceAssetProvider, etc.) extend this

class_name AssetProvider extends RefCounted

# Emitted when assets are discovered/added/removed/modified
signal assets_changed(added: Array[Asset], removed: Array[Asset], modified: Array[Asset])

# Provider metadata
var provider_name: String = "BaseProvider"
var supports_hot_reload: bool = false


## Initialize the provider (called once at startup)
func initialize(tree: SceneTree) -> void:
	push_error("AssetProvider.initialize() is abstract - override in subclass")


## Scan for assets (should return immediately or queue background scan)
func scan() -> void:
	push_error("AssetProvider.scan() is abstract - override in subclass")


## Get all assets managed by this provider
func get_assets() -> Array[Asset]:
	push_error("AssetProvider.get_assets() is abstract - override in subclass")
	return []


## Get assets of a specific type
func get_assets_by_type(type: Asset.TYPE) -> Array[Asset]:
	var result: Array[Asset] = []
	for asset in get_assets():
		if asset.type == type:
			result.append(asset)
	return result


## Check if provider is ready (initialized and scanned)
func is_ready() -> bool:
	return true
