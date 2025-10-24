## Device.gd
## Represents an audio device (instrument or effect) that can be added to a channel.
## This is metadata about the device type, not an instance on a channel.

class_name Device extends RefCounted

enum DeviceType { BuiltIn, LV2, CLAP }
enum DeviceCategory { Instrument, Effect, Utility }

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


## Get all parameters
func get_parameters() -> Array[DeviceParameter]:
	return parameters


## ============================================================================
## HELPER METHODS
## ============================================================================

## Check if this device has a native GUI
## Returns true for CLAP plugins (which may have native GUIs)
## Returns false for built-in devices (which use DeviceLane UI)
func has_gui() -> bool:
	return device_type == DeviceType.CLAP

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
static func create_builtin_oscillator() -> Device:
	var device = Device.new("sonara.builtin.oscillator", "Oscillator", DeviceCategory.Instrument)
	device.title = "Polysynth"
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
