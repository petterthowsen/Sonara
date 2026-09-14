## Device.gd
## Represents an audio device (instrument or effect) that can be added to a channel.
## This is metadata about the device type, not an instance on a channel.

class_name Device extends RefCounted

enum DeviceType { BuiltIn, LV2, CLAP }
enum DeviceCategory { Instrument, Effect, Utility }
## Panel = device custom UI (not the parameter list). Large/Auxiliary are extra views.
## Immediate UI (plugin-drawn in-device controls) is a planned right-pane view, separate from ParameterList.
enum ViewType { Panel, Large, Auxiliary, Compact }

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

## DEPRECATED: Path-based visual scene (use PackedScene registrations below)
var visual_scene_path: String = ""

## PackedScene references (null when unsupported)
var panel_view_scene: PackedScene = null
var large_view_scene: PackedScene = null
var auxiliary_view_scene: PackedScene = null
var compact_view_scene: PackedScene = null

## Path to custom controls scene (optional override for parameters)
var controls_scene_path: String = ""


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


func register_large_view(scene: PackedScene) -> void:
	large_view_scene = scene


func register_auxiliary_view(scene: PackedScene) -> void:
	auxiliary_view_scene = scene


func register_compact_view(scene: PackedScene) -> void:
	compact_view_scene = scene


## Back-compat shim (transition only): map old API to Panel view
func register_visual_scene(scene: PackedScene) -> void:
	panel_view_scene = scene


## Register a custom controls scene for this device
func register_controls_scene(path: String) -> void:
	controls_scene_path = path


## Availability checks
func has_panel_view() -> bool:
	return panel_view_scene != null


func has_large_view() -> bool:
	return large_view_scene != null


func has_auxiliary_view() -> bool:
	return auxiliary_view_scene != null


func has_compact_view() -> bool:
	return compact_view_scene != null


## Check if this device has custom controls
func has_custom_controls() -> bool:
	return controls_scene_path != ""


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


## ============================================================================
## FACTORY METHODS
## ============================================================================

## Create a built-in oscillator device
## @deprecated
static func create_builtin_oscillator() -> Device:
	var device = Device.new("sonara.builtin.oscillator", "Oscillator", DeviceCategory.Instrument)
	device.title = "Oscillator"
	device.description = "A polyphonic synthesizer featuring sine, square, sawtooth, and triangle waveforms. Perfect for creating everything from classic synth sounds to experimental textures."
	device.author = "Sonara"
	device.accepts_midi = true
	device.audio_in_channels = 0
	device.audio_out_channels = 2

	var waveform_param = DeviceParameter.new(0, "Waveform", "")
	waveform_param.min_value = 0.0
	waveform_param.max_value = 1.0
	waveform_param.default_value = 0.0
	waveform_param.description = "Waveform type: sine (0.0), square (0.25), sawtooth (0.5), triangle (0.75)"
	device.add_parameter(waveform_param)

	var amplitude_param = DeviceParameter.new(1, "Amplitude", "")
	amplitude_param.min_value = 0.0
	amplitude_param.max_value = 1.0
	amplitude_param.default_value = 0.3
	amplitude_param.description = "Output amplitude / volume"
	device.add_parameter(amplitude_param)

	return device


## Create a built-in delay device
## @deprecated
static func create_builtin_delay() -> Device:
	var device = Device.new("sonara.builtin.delay", "Delay", DeviceCategory.Effect)
	device.title = "Stereo Delay"
	device.description = "A classic stereo delay effect with adjustable time and wet/dry mix. Built-in feedback creates repeating echoes. Perfect for adding depth and space to any track."
	device.author = "Sonara"
	device.accepts_midi = false
	device.audio_in_channels = 2
	device.audio_out_channels = 2

	var delay_time_param = DeviceParameter.new(0, "Delay Time", "ms")
	delay_time_param.min_value = 1.0
	delay_time_param.max_value = 1250.0
	delay_time_param.default_value = 250.0
	delay_time_param.description = "Delay time in milliseconds (1-1250ms)"
	delay_time_param.is_logarithmic = true
	device.add_parameter(delay_time_param)

	var wet_amount_param = DeviceParameter.new(1, "Wet Amount", "")
	wet_amount_param.min_value = 0.0
	wet_amount_param.max_value = 1.0
	wet_amount_param.default_value = 0.5
	wet_amount_param.description = "Mix between dry (0.0) and wet (1.0)"
	device.add_parameter(wet_amount_param)

	return device


## Create a built-in SFZ sampler device
static func create_builtin_sfizz() -> Device:
	var device = Device.new("sonara.builtin.sfizz", "SFZ Sampler", DeviceCategory.Instrument)
	device.title = "SFZ Sampler"
	device.description = "SFZ sample player powered by Sfizz."
	device.author = "Sonara"
	device.accepts_midi = true
	device.audio_in_channels = 0
	device.audio_out_channels = 2
	
	# File loading support
	device.supports_file_loading = true
	device.supported_file_extensions = [".sfz", ".SFZ"] as Array[String]
	device.file_type_description = "SFZ Sample Files"

	return device
