# DeviceAssetProvider.gd
# Exposes DeviceRegistry devices (built-in and plugin) as browser Assets.
# Discovery, OSC and the plugin cache live in DeviceRegistry.

class_name DeviceAssetProvider extends AssetProvider

var _registry: DeviceRegistry = null
var _assets: Array[Asset] = []


func _init(registry: DeviceRegistry = null) -> void:
	provider_name = "DeviceAssetProvider"
	supports_hot_reload = false
	_registry = registry


func initialize(_tree: SceneTree) -> void:
	if _registry == null:
		push_error("[DeviceAssetProvider] Created without a DeviceRegistry")
		return
	_registry.devices_changed.connect(_on_devices_changed)
	scan()


## Rebuild the asset list from the registry.
func scan() -> void:
	_assets.clear()
	if _registry == null:
		return
	for device in _registry.get_devices():
		_assets.append(_asset_for(device))


func get_assets() -> Array[Asset]:
	return _assets


## Keep the asset list in step with the registry and forward the change.
func _on_devices_changed(added: Array[Device], removed: Array[Device]) -> void:
	scan()
	var added_assets: Array[Asset] = []
	for device in added:
		added_assets.append(_asset_for(device))
	var removed_assets: Array[Asset] = []
	for device in removed:
		removed_assets.append(_asset_for(device))
	assets_changed.emit(added_assets, removed_assets, [] as Array[Asset])


static func _asset_for(device: Device) -> Asset:
	var asset := Asset.new()
	asset.type = Asset.TYPE.Device
	asset.name = device.name
	asset.path = device.device_id
	return asset
