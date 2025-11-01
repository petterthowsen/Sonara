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
var _scale_param_id: int = -1
var _style_param_id: int = -1

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

	# Resolve UI-only parameters
	_scale_param_id = device.get_parameter_id_by_name("Scale")
	_style_param_id = device.get_parameter_id_by_name("Style")

	# Debug: dump parameter metadata we rely on
	if _smoothing_param_id >= 0:
		var p = device.device.get_parameter(_smoothing_param_id)
		if p:
			print("[SpectrumVisualizer] Speed enum_values=", p.enum_values)
		else:
			print("[SpectrumVisualizer] Speed param metadata missing")
	if _resolution_param_id >= 0:
		var pr = device.device.get_parameter(_resolution_param_id)
		if pr:
			print("[SpectrumVisualizer] FFT Size enum_values=", pr.enum_values)
		else:
			print("[SpectrumVisualizer] FFT Size param metadata missing")


func _on_view_shown() -> void:
	print("[SpectrumVisualizer] _on_view_shown subscribe; renderer_ready=", renderer != null, " ch=", (device.channel_id if device else -1), " pos=", (device.position if device else -1))
	# Subscribe to spectrum data
	if device:
		AudioEngineOSC.subscribe_device_data(device.channel_id, device.position, "spectrum")
	
	if not AudioEngineOSC.device_spectrum_received.is_connected(_on_spectrum_received):
		AudioEngineOSC.device_spectrum_received.connect(_on_spectrum_received)
	
	if _smoothing_param_id >= 0:
		var n = device.get_parameter_normalized(_smoothing_param_id)
		print("[SpectrumVisualizer] applying initial speed normalized=", n)
		_apply_speed_from_param(n)
	
	if _resolution_param_id >= 0:
		var rn = device.get_parameter_normalized(_resolution_param_id)
		print("[SpectrumVisualizer] applying initial resolution normalized=", rn)
		_apply_resolution_enum(rn)

	# Apply UI-only params on show
	if _scale_param_id >= 0:
		_apply_scale_from_param(device.get_parameter_normalized(_scale_param_id))
	if _style_param_id >= 0:
		_apply_style_from_param(device.get_parameter_normalized(_style_param_id))


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
		print("[SpectrumVisualizer] speed change received normalized=", value)
		_apply_speed_from_param(value)
	
	elif param_id == _resolution_param_id:
		print("[SpectrumVisualizer] resolution change received normalized=", value)
		_apply_resolution_enum(value)
	elif param_id == _scale_param_id:
		_apply_scale_from_param(value)
	elif param_id == _style_param_id:
		_apply_style_from_param(value)


func _apply_speed_from_param(normalized: float) -> void:
	# Enum mapping: 0 Freeze, 1 Slow, 2 Medium, 3 Fast (use enum length from metadata)
	if not renderer:
		return
	var param := device.device.get_parameter(_smoothing_param_id)
	var enum_len: int = param.enum_values.size() if param else 4
	var idx: int = int(round(clamp(normalized, 0.0, 1.0) * float(max(1, enum_len - 1))))
	print("[SpectrumVisualizer] _apply_speed_from_param normalized=", normalized, " enum_len=", enum_len, " idx=", idx)
	match idx:
		0:
			renderer.smoothing = 1.0
			print("[SpectrumVisualizer] speed=Freeze smoothing=", renderer.smoothing)
		1:
			renderer.smoothing = 0.85
			print("[SpectrumVisualizer] speed=Slow smoothing=", renderer.smoothing)
		2:
			renderer.smoothing = 0.5
			print("[SpectrumVisualizer] speed=Medium smoothing=", renderer.smoothing)
		_:
			renderer.smoothing = 0.1
			print("[SpectrumVisualizer] speed=Fast smoothing=", renderer.smoothing)


func _apply_resolution_enum(normalized: float) -> void:
	var idx: int = int(round(clamp(normalized, 0.0, 1.0) * 3.0))
	print("[SpectrumVisualizer] _apply_resolution_enum normalized=", normalized, " idx=", idx)
	match idx:
		0:
			print("[SpectrumVisualizer] using tiny")
			renderer.resolution = SpectrumRenderer.Resolution.Tiny  # 512
		1:
			print("[SpectrumVisualizer] using small")
			renderer.resolution = SpectrumRenderer.Resolution.Small # 1024
		2:
			print("[SpectrumVisualizer] using medium")
			renderer.resolution = SpectrumRenderer.Resolution.Medium # 2048
		_:
			print("[SpectrumVisualizer] using large")
			renderer.resolution = SpectrumRenderer.Resolution.Large # 4096


func _apply_scale_from_param(normalized: float) -> void:
	if not renderer:
		return
	# Enum index from normalized (2 values: Log, Linear)
	var idx := 0 if normalized < 0.5 else 1
	renderer.freq_scale = SpectrumRenderer.FrequencyScale.Log if idx == 0 else SpectrumRenderer.FrequencyScale.Linear
	print("[SpectrumVisualizer] scale set=", ("Log" if idx == 0 else "Linear"))


func _apply_style_from_param(normalized: float) -> void:
	if not renderer:
		return
	# Enum index from normalized (2 values: Bars, Line)
	var idx := 0 if normalized < 0.5 else 1
	renderer.style = SpectrumRenderer.Style.BARS if idx == 0 else SpectrumRenderer.Style.LINE
	print("[SpectrumVisualizer] style set=", ("BARS" if idx == 0 else "LINE"))


## Hold/Freeze behavior is now part of the Speed enum (index 0)


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
