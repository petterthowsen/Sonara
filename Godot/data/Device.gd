## Device.gd
## Represents an audio device (instrument or effect) that can be added to a channel.
## This is metadata about the device type, not an instance on a channel.

class_name Device extends RefCounted

enum DeviceType { BuiltIn, LV2, CLAP }
enum DeviceCategory { Instrument, Effect, Utility }
## Panel = device custom UI (not the parameter list). Window = popup view (for devices without a native GUI); Companion = shown in the panel while the window or plugin GUI is open.
## Immediate UI (plugin-drawn in-device controls) is a planned right-pane view, separate from ParameterList.
enum ViewType { Panel, Window, Companion, Compact }

## ============================================================================
## PROPERTIES
## ============================================================================

## Unique device identifier (e.g., "sonara.builtin.oscillator", "clap:path/to/plugin")
var device_id: String = ""
var id : String:
	get:
		return device_id
	set(id):
		device_id = id


## Human-readable device name (e.g., "Oscillator", "Delay")
var name: String = ""

## Longer, more readable title for display (e.g., "Multi-Waveform Synthesizer", "Stereo Delay with Feedback")
var title: String = ""

## File path to plugin (for CLAP/LV2/VST3 plugins, empty for built-in)
var plugin_path: String = ""

## Device type (BuiltIn, LV2, CLAP)
var device_type: DeviceType = DeviceType.BuiltIn

## Device category (Instrument, Effect, Utility)
var category: DeviceCategory = DeviceCategory.Effect

## Version string for compatibility checking
var version: String = "1.0"

## List of parameter metadata
var parameters: Array[DeviceParameter] = []

## Device description/documentation
var description: String = ""

## Manufacturer/author name
var author: String = "Sonara"

## Whether this device accepts MIDI input
var accepts_midi: bool = false

## Number of audio input channels
var audio_in_channels: int = 2

## Number of audio output channels
var audio_out_channels: int = 2

## Whether this device can own nested child devices (Chain, Layer).
var is_container: bool = false

## Whether this device supports loading files (e.g., SFZ, samples)
var supports_file_loading: bool = false

## Supported file extensions for file loading (e.g., [".sfz", ".SFZ"])
var supported_file_extensions: Array[String] = []

## Description of supported file types (e.g., "SFZ Sample Files")
var file_type_description: String = ""

## CLAP feature tags (e.g., ["audio-effect", "reverb"]). Empty for builtins.
var features: Array[String] = []

## PackedScene references (null when unsupported)
var panel_view_scene: PackedScene = null
var window_view_scene: PackedScene = null
var companion_view_scene: PackedScene = null
var compact_view_scene: PackedScene = null


## ============================================================================
## INITIALIZATION
## ============================================================================

func _init(p_device_id: String, p_name: String, p_category: DeviceCategory, p_device_type: DeviceType = DeviceType.BuiltIn) -> void:
	device_id = p_device_id
	name = p_name
	category = p_category
	device_type = p_device_type


## ============================================================================
## PARAMETER MANAGEMENT
## ============================================================================

## Add a parameter to this device
func add_parameter(param: DeviceParameter) -> void:
	parameters.append(param)


## Get parameter by ID
func get_parameter(param_id: int) -> DeviceParameter:
	for param in parameters:
		if param.id == param_id:
			return param
	return null


## Get parameter by name (case-insensitive). Returns null if not found
func get_parameter_by_name(param_name: String) -> DeviceParameter:
	var target = param_name.strip_edges().to_lower()
	for param in parameters:
		if String(param.name).to_lower() == target:
			return param
	return null


## Get all parameters
func get_parameters() -> Array[DeviceParameter]:
	return parameters


## Parameters belonging to a UI group (`"param"` or `"cc"`). Empty group counts as `"param"`.
func get_parameters_in_group(group: String) -> Array[DeviceParameter]:
	var result: Array[DeviceParameter] = []
	for param in parameters:
		var param_group = param.group if param.group != "" else "param"
		if param_group == group:
			result.append(param)
	return result


## True when this device advertises at least one CC-tab parameter.
func has_cc_parameters() -> bool:
	return not get_parameters_in_group("cc").is_empty()


## ============================================================================
## VISUAL & CONTROLS SCENE REGISTRATION
## ============================================================================

## Registration (PackedScene only)
func register_panel_view(scene: PackedScene) -> void:
	panel_view_scene = scene


func register_window_view(scene: PackedScene) -> void:
	window_view_scene = scene


func register_companion_view(scene: PackedScene) -> void:
	companion_view_scene = scene


func register_compact_view(scene: PackedScene) -> void:
	compact_view_scene = scene


## Availability checks
func has_panel_view() -> bool:
	return panel_view_scene != null


func has_window_view() -> bool:
	return window_view_scene != null


func has_companion_view() -> bool:
	return companion_view_scene != null


func has_compact_view() -> bool:
	return compact_view_scene != null


## ============================================================================
## HELPER METHODS
## ============================================================================

## Check if this device has a native GUI
## Returns true for CLAP plugins (which may have native GUIs)
## Returns false for built-in devices (which use DeviceLane UI)
func has_gui() -> bool:
	return device_type == DeviceType.CLAP


## Extra stereo output buses beyond the main pair (plugin multi-out). Drum pads use slot count instead.
func extra_stereo_bus_count() -> int:
	return maxi(0, audio_out_channels / 2 - 1)


## True when dropping this device on an empty tracklist/mixer should create an instrument track.
func creates_instrument_track() -> bool:
	return category == DeviceCategory.Instrument or is_container


## True when expanding this container should show one focused child at a time (Layer, Drum Machine).
func container_focuses_one_child() -> bool:
	return is_container and device_id in ["sonara.builtin.layer", "sonara.builtin.drum_machine"]


## Get a human-readable device type string
func get_device_type_string() -> String:
	match device_type:
		DeviceType.BuiltIn:
			return "Built-in"
		DeviceType.LV2:
			return "LV2"
		DeviceType.CLAP:
			return "CLAP"
		_:
			return "Unknown"


## Get a human-readable category string
func get_category_string() -> String:
	match category:
		DeviceCategory.Instrument:
			return "Instrument"
		DeviceCategory.Effect:
			return "Effect"
		DeviceCategory.Utility:
			return "Utility"
		_:
			return "Unknown"


## Get icon name for this device type
func get_icon() -> String:
	match category:
		DeviceCategory.Instrument:
			return "PlugScript"
		DeviceCategory.Effect:
			return "AudioEffect"
		DeviceCategory.Utility:
			return "Tool"
		_:
			return "AudioBusInput"


## Get a shortened version of the device name for compact displays
## Example: "Dragonfly Hall Reverb" -> "D. Hall Rev"
func get_short_name(max_length: int = 15) -> String:
	return Utils.shorten_text(name, max_length)


## True when this device gets a generated Simple View (`devices/simple_view/`, REQ-001): never
## for a container, and only once there's at least one visible parameter (`ParamClassifier.is_visible`).
## Pass `params` for an instance's own advertised list (CLAP/SFZ devices, whose parameters live on
## `DeviceInstance` rather than this shared registry object) when it's non-empty; otherwise this
## falls back to `parameters`, so a plugin with no params advertised yet correctly reports false.
func uses_simple_view(params: Array = []) -> bool:
	if is_container:
		return false
	var list: Array = params if not params.is_empty() else parameters
	for param in list:
		if ParamClassifier.is_visible(param):
			return true
	return false
