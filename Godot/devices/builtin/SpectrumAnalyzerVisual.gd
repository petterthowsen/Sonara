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
var _spectrum_count: int = 0

func _get_minimum_size() -> Vector2:
	return Vector2(300, 50)

func _ready() -> void:
	if not renderer:
		push_error("[SpectrumVisualizer] Renderer node missing at _ready")
		return

	renderer.db_range_min = -100.0
	renderer.db_range_max = 0.0
	renderer.frequency_range = SpectrumRenderer.FrequencyRange.HumanEar
	renderer.freq_scale = SpectrumRenderer.FrequencyScale.Log
	renderer.style = SpectrumRenderer.Style.BARS


func _on_bind() -> void:
	print("[SpectrumVisualizer] _on_bind channel=", channel_id, " pos=", device_position, " device=", device != null)
	# Resolve smoothing parameter if present and initialize current smoothing/speed
	_smoothing_param_id = device.get_parameter_id_by_name("Speed")
	print("[SpectrumVisualizer] smoothing param id=", _smoothing_param_id)
	# Resolve resolution (FFT Size) parameter
	_resolution_param_id = device.get_parameter_id_by_name("FFT Size")
	print("[SpectrumVisualizer] fft size param id=", _resolution_param_id)


func _on_view_shown() -> void:
	print("[SpectrumVisualizer] _on_view_shown subscribe; renderer_ready=", renderer != null, " ch=", (device.channel_id if device else -1), " pos=", (device.position if device else -1))
	# Subscribe to spectrum data
	if device:
		AudioEngineOSC.subscribe_device_data(device.channel_id, device.position, "spectrum")
	
	if not AudioEngineOSC.device_spectrum_received.is_connected(_on_spectrum_received):
		AudioEngineOSC.device_spectrum_received.connect(_on_spectrum_received)
	
	if _smoothing_param_id >= 0:
		_set_smoothing_from_parameter(device.get_parameter_normalized(_smoothing_param_id))
	
	if _resolution_param_id >= 0:
		_update_resolution_from_param(device.get_parameter_normalized(_resolution_param_id))


func _on_view_hidden() -> void:
	print("[SpectrumVisualizer] _on_view_hidden unsubscribe")
	# Unsubscribe
	if device:
		AudioEngineOSC.unsubscribe_device_data(device.channel_id, device.position, "spectrum")
	
	if AudioEngineOSC.device_spectrum_received.is_connected(_on_spectrum_received):
		AudioEngineOSC.device_spectrum_received.disconnect(_on_spectrum_received)


func _on_device_parameter_changed(param_id: int, value: float) -> void:
	# Called by DeviceView when engine echoes parameter changes (normalized 0..1)
	print("[SpectrumVisualizer] param_changed id=", param_id, " value=", value)
	if param_id == _smoothing_param_id:
		_set_smoothing_from_parameter(value)
	
	elif param_id == _resolution_param_id:
		_update_resolution_from_param(value)


func _set_smoothing_from_parameter(normalized: float) -> void:
	var n = clamp(normalized, 0.0, 1.0)
	# Set UI smoothing directly from device param
	if renderer:
		renderer.smoothing = 1.0 - n # parameter is "speed" so invert it.
		print("[SpectrumVisualizer] smoothing set=", n)
	else:
		push_warning("[SpectrumVisualizer] renderer is null when setting smoothing")


func _update_resolution_from_param(normalized: float) -> void:
	var n = clamp(normalized, 0.0, 1.0)
	# Mirror engine thresholds
	if n < 0.25:
		print("[SpectrumVisualizer] using tiny")
		renderer.resolution = SpectrumRenderer.Resolution.Tiny  # 512
	elif n < 0.5:
		print("[SpectrumVisualizer] using small")
		renderer.resolution = SpectrumRenderer.Resolution.Small # 1024
	elif n < 0.75:
		print("[SpectrumVisualizer] using medium")
		renderer.resolution = SpectrumRenderer.Resolution.Medium # 2048
	else:
		print("[SpectrumVisualizer] using large")
		renderer.resolution = SpectrumRenderer.Resolution.Large # 4096


func _on_spectrum_received(ch_id: int, dev_pos: int, spectrum: PackedFloat32Array) -> void:
	if device and ch_id == device.channel_id and dev_pos == device.position:
		if renderer:
			renderer.update_spectrum(spectrum)
			_spectrum_count += 1
			if (_spectrum_count % 30) == 1:
				print("[SpectrumVisualizer] spectrum update #", _spectrum_count, " len=", spectrum.size())
		else:
			push_warning("[SpectrumVisualizer] renderer is null in _on_spectrum_received")


func _draw() -> void:
	pass
