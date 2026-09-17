# DeviceViewFactory.gd
# Instantiates DeviceView scenes for a DeviceInstance, so data/ never builds UI.
class_name DeviceViewFactory extends RefCounted

## Built-in device ID → view scenes, per view type.
const BUILTIN_PANEL_SCENES := {
	"sonara.builtin.spectrum_analyzer": preload("res://devices/builtin/SpectrumAnalyzerDefaultView.tscn"),
	"sonara.builtin.layer": preload("res://devices/builtin/LayerDefaultView.tscn"),
	"sonara.builtin.sampler": preload("res://devices/builtin/SamplerDefaultView.tscn"),
	"sonara.builtin.drum_machine": preload("res://devices/builtin/DrumMachineDefaultView.tscn"),
}
const BUILTIN_WINDOW_SCENES := {
	"sonara.builtin.spectrum_analyzer": preload("res://devices/builtin/SpectrumAnalyzerDefaultView.tscn"),
}
const BUILTIN_COMPANION_SCENES := {}
const BUILTIN_COMPACT_SCENES := {}

## The generated Simple View (`devices/simple_view/`), used for the Panel view of any device
## without a registered Panel view, and of devices whose "Simple" toggle is on (T-013).
const SIMPLE_VIEW_SCENE := preload("res://devices/simple_view/SimpleView.tscn")


## Attach the built-in view scenes for `device`. Connected to DeviceRegistry.device_registered,
## so views are in place before any panel binds to an instance of the device.
static func register_builtin_views(device: Device) -> void:
	if device == null or device.device_type != Device.DeviceType.BuiltIn:
		return
	var id := device.device_id
	if BUILTIN_PANEL_SCENES.has(id):
		device.register_panel_view(BUILTIN_PANEL_SCENES[id])
	if BUILTIN_WINDOW_SCENES.has(id):
		device.register_window_view(BUILTIN_WINDOW_SCENES[id])
	if BUILTIN_COMPANION_SCENES.has(id):
		device.register_companion_view(BUILTIN_COMPANION_SCENES[id])
	if BUILTIN_COMPACT_SCENES.has(id):
		device.register_compact_view(BUILTIN_COMPACT_SCENES[id])


## Create a view of `view_type` from the Device's registered scenes, or the generated Simple View
## for a Panel view when the device qualifies for one (see `_use_simple_view`). Returns null if
## unsupported.
static func create(instance: DeviceInstance, view_type: Device.ViewType) -> DeviceView:
	if instance == null or instance.device == null:
		return null

	var scene: PackedScene = SIMPLE_VIEW_SCENE if view_type == Device.ViewType.Panel and _use_simple_view(instance) \
			else _scene_for(instance.device, view_type)
	if scene == null:
		return null

	var node := scene.instantiate()
	var view := node as DeviceView
	if view == null:
		push_error("[DeviceViewFactory] View scene for %s must extend DeviceView" % instance.device.name)
		node.queue_free()
		return null

	view.set_view_type(view_type)
	return view


## True when `instance`'s Panel view should be the generated Simple View rather than a registered
## Panel view: the device has no Panel view of its own and qualifies for one (`uses_simple_view`),
## or it has one but the per-device "Simple" toggle (`devices/simple_view/<id>`) is on.
static func _use_simple_view(instance: DeviceInstance) -> bool:
	var device := instance.device
	if not device.uses_simple_view(instance.get_parameters()):
		return false
	if not device.has_panel_view():
		return true
	return bool(Sonara.get_config("devices/simple_view/%s" % device.device_id, false))


static func _scene_for(device: Device, view_type: Device.ViewType) -> PackedScene:
	match view_type:
		Device.ViewType.Panel:
			return device.panel_view_scene
		Device.ViewType.Window:
			return device.window_view_scene
		Device.ViewType.Companion:
			return device.companion_view_scene
		Device.ViewType.Compact:
			return device.compact_view_scene
	return null
