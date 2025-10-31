## SpectrumAnalyzerVisual
## Visual display for spectrum analyzer device
## Shows frequency spectrum as vertical bars with log-scale X axis
##
## Engine sends dBFS values with floor at -160 and max at 0.
## db_range_min/max define the visible rendering window (zoom).
class_name SpectrumAnalyzerVisual extends DeviceView

@onready var renderer : SpectrumRenderer = $SpectrumRenderer

var _smoothing_param_id: int = -1
var _resolution_param_id: int = -1

func _get_minimum_size() -> Vector2:
	return Vector2(200, 50)

func _ready() -> void:
	renderer.db_range_min = -100.0
	renderer.db_range_max = 0.0
	renderer.frequency_range = SpectrumRenderer.FrequencyRange.HumanEar
	renderer.freq_scale = SpectrumRenderer.FrequencyScale.Log
	renderer.style = SpectrumRenderer.Style.BARS


func _on_bind() -> void:
	# Resolve smoothing parameter if present and initialize current smoothing/speed
	_smoothing_param_id = device.get_parameter_id_by_name("Speed")
	print("smoothing param id = ", _smoothing_param_id)
	
	if _smoothing_param_id >= 0 and device:
		var normalized := device.get_parameter_normalized(_smoothing_param_id)
		_set_smoothing_from_parameter(normalized)

	# Resolve resolution (FFT Size) parameter
	_resolution_param_id = device.get_parameter_id_by_name("FFT Size")
	print("fft size param id: ", _resolution_param_id)
	if _resolution_param_id >= 0 and device:
		_update_resolution_from_param(device.get_parameter_normalized(_resolution_param_id))


func _on_view_shown() -> void:
	# Subscribe to spectrum data
	AudioEngineOSC.subscribe_device_data(channel_id, device_position, "spectrum")
	AudioEngineOSC.device_spectrum_received.connect(_on_spectrum_received)


func _on_view_hidden() -> void:
	# Unsubscribe
	AudioEngineOSC.unsubscribe_device_data(channel_id, device_position, "spectrum")
	if AudioEngineOSC.device_spectrum_received.is_connected(_on_spectrum_received):
		AudioEngineOSC.device_spectrum_received.disconnect(_on_spectrum_received)


func _on_device_parameter_changed(param_id: int, value: float) -> void:
	# Called by DeviceView when engine echoes parameter changes (normalized 0..1)
	if param_id == _smoothing_param_id:
		_set_smoothing_from_parameter(value)
		#queue_redraw()
	elif param_id == _resolution_param_id:
		_update_resolution_from_param(value)


func _set_smoothing_from_parameter(normalized: float) -> void:
	var n = clamp(normalized, 0.0, 1.0)
	# Set UI smoothing directly from device param
	renderer.smoothing = n


func _update_resolution_from_param(normalized: float) -> void:
	var n = clamp(normalized, 0.0, 1.0)
	# Mirror engine thresholds
	if n < 0.25:
		print("using tiny")
		renderer.resolution = SpectrumRenderer.Resolution.Tiny  # 512
	elif n < 0.5:
		print("using small")
		renderer.resolution = SpectrumRenderer.Resolution.Small # 1024
	elif n < 0.75:
		print("using medium")
		renderer.resolution = SpectrumRenderer.Resolution.Medium # 2048
	else:
		print("using large")
		renderer.resolution = SpectrumRenderer.Resolution.Large # 4096


func _on_spectrum_received(ch_id: int, dev_pos: int, spectrum: PackedFloat32Array) -> void:
	if ch_id == channel_id and dev_pos == device_position:
		renderer.update_spectrum(spectrum)


func _draw() -> void:
	pass
