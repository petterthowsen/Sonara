# PluginHosting.gd
# How CLAP plugins are grouped into plugin_host processes (engine-stability-plan Phase 5).
# The global mode is the "plugins/hosting_mode" setting; per-plugin overrides ("always host
# this plugin individually", set from the device context menu) are stored by plugin id in the
# "plugins/hosting_overrides" config key. Both go to the engine as one message:
#   /plugins/hosting <mode:s> [plugin_id:s mode:s]*
# The engine moves already-loaded plugins to their new host live, restoring their state.
# Owned by AssetService next to the DeviceRegistry. UI calls this model; it sends the OSC.
class_name PluginHosting extends RefCounted

static var logger := Log.make("PluginHosting")

const SETTING_KEY := "plugins/hosting_mode"
const OVERRIDES_KEY := "plugins/hosting_overrides"

## Setting choice label -> engine mode name.
const MODES := {
	"Individually": "individually",
	"By plug-in": "by_plugin",
	"By vendor": "by_vendor",
	"Together": "together",
}

## Engine mode name -> short label for tooltips.
const MODE_LABELS := {
	"individually": "Individually",
	"by_plugin": "By plug-in",
	"by_vendor": "By vendor",
	"together": "Together",
}

## Emitted when a plugin's override changed.
signal overrides_changed()


## Listen for setting changes and engine (re)connects, then send the current policy.
func start() -> void:
	if not Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.connect(_on_setting_changed)
	if not AudioEngineOSC.engine_connected.is_connected(sync_to_engine):
		AudioEngineOSC.engine_connected.connect(sync_to_engine)
	sync_to_engine()


## Engine mode name of the global setting.
func global_mode() -> String:
	return MODES.get(str(Settings.get_value(SETTING_KEY)), "individually")


## True when `plugin_id` always gets a host process of its own.
func is_hosted_individually(plugin_id: String) -> bool:
	return _overrides().get(plugin_id, "") == "individually"


## Always host `plugin_id` individually (or follow the global mode again). Applies live.
func set_hosted_individually(plugin_id: String, individually: bool) -> void:
	var overrides := _overrides()
	if individually == (overrides.get(plugin_id, "") == "individually"):
		return
	if individually:
		overrides[plugin_id] = "individually"
	else:
		overrides.erase(plugin_id)
	Sonara.set_config(OVERRIDES_KEY, overrides)
	Sonara.save_config()
	logger.info("%s: %s" % [plugin_id, "always hosted individually" if individually else "follows the global mode"])
	overrides_changed.emit()
	sync_to_engine()


## The /plugins/hosting arguments: the global mode, then (plugin_id, mode) pairs.
func build_message() -> Array:
	var args: Array = [global_mode()]
	var overrides := _overrides()
	var ids := overrides.keys()
	ids.sort()
	for plugin_id in ids:
		args.append(str(plugin_id))
		args.append(str(overrides[plugin_id]))
	return args


## Send the policy. Safe to repeat: the engine only moves plugins whose host changed.
func sync_to_engine() -> void:
	AudioEngineOSC.send("/plugins/hosting", build_message())


func _overrides() -> Dictionary:
	var stored = Sonara.get_config(OVERRIDES_KEY, {})
	return (stored as Dictionary).duplicate() if stored is Dictionary else {}


func _on_setting_changed(key: String, _value) -> void:
	if key == SETTING_KEY:
		sync_to_engine()
