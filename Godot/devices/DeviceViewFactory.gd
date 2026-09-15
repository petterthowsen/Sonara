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
const BUILTIN_LARGE_SCENES := {
	"sonara.builtin.spectrum_analyzer": preload("res://devices/builtin/SpectrumAnalyzerDefaultView.tscn"),
}
const BUILTIN_AUXILIARY_SCENES := {}
const BUILTIN_COMPACT_SCENES := {}


## Attach the built-in view scenes for `device`. Connected to DeviceRegistry.device_registered,
## so views are in place before any panel binds to an instance of the device.
static func register_builtin_views(device: Device) -> void:
	if device == null or device.device_type != Device.DeviceType.BuiltIn:
		return
	var id := device.device_id
	if BUILTIN_PANEL_SCENES.has(id):
		device.register_panel_view(BUILTIN_PANEL_SCENES[id])
	if BUILTIN_LARGE_SCENES.has(id):
		device.register_large_view(BUILTIN_LARGE_SCENES[id])
	if BUILTIN_AUXILIARY_SCENES.has(id):
		device.register_auxiliary_view(BUILTIN_AUXILIARY_SCENES[id])
	if BUILTIN_COMPACT_SCENES.has(id):
		device.register_compact_view(BUILTIN_COMPACT_SCENES[id])


## Create a view of `view_type` from the Device's registered scenes. Returns null if unsupported.
static func create(instance: DeviceInstance, view_type: Device.ViewType) -> DeviceView:
	if instance == null or instance.device == null:
		return null

	var scene := _scene_for(instance.device, view_type)
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


static func _scene_for(device: Device, view_type: Device.ViewType) -> PackedScene:
	match view_type:
		Device.ViewType.Panel:
			return device.panel_view_scene
		Device.ViewType.Large:
			return device.large_view_scene
		Device.ViewType.Auxiliary:
			return device.auxiliary_view_scene
		Device.ViewType.Compact:
			return device.compact_view_scene
	return null
