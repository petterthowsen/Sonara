## Sampler panel: sample waveform with a shaded start/end region.
class_name SamplerDefaultView extends DeviceView

var _start_id: int = -1
var _end_id: int = -1


func _get_minimum_size() -> Vector2:
	return Vector2(220, 72)


func _on_bind() -> void:
	if device == null:
		return
	_start_id = device.get_parameter_id_by_name("Start")
	_end_id = device.get_parameter_id_by_name("End")
	_ensure_waveform()
	_connect_waveform()
	queue_redraw()


func _on_view_shown() -> void:
	_connect_waveform()
	queue_redraw()


func _on_device_parameter_changed(_param_id: int, _value: float) -> void:
	queue_redraw()


func _ensure_waveform() -> void:
	if device and device.sample_waveform == null:
		device.sample_waveform = DeviceWaveform.new()


func _connect_waveform() -> void:
	_ensure_waveform()
	if device == null or device.sample_waveform == null:
		return
	var wf: DeviceWaveform = device.sample_waveform
	if not wf.waveform_level_updated.is_connected(_on_waveform_changed):
		wf.waveform_level_updated.connect(_on_waveform_changed)
	if not wf.metadata_changed.is_connected(_on_waveform_changed):
		wf.metadata_changed.connect(_on_waveform_changed)


func _on_waveform_changed(_level: int = 0) -> void:
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.08, 0.08, 0.1, 1.0), true)
	var waveform := _ready_waveform()
	if waveform == null:
		var msg := "Drop an audio file" if device == null or device.loaded_file_path.is_empty() else "Loading…"
		draw_string(
			ThemeDB.fallback_font,
			Vector2(8, size.y * 0.5 + 4),
			msg,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			13,
			Color(0.7, 0.7, 0.75, 0.85)
		)
		return
	var start_n := device.get_parameter_normalized(_start_id) if _start_id >= 0 else 0.0
	var end_n := device.get_parameter_normalized(_end_id) if _end_id >= 0 else 1.0
	_draw_peaks(waveform, rect)
	var x0 := rect.position.x + rect.size.x * start_n
	var x1 := rect.position.x + rect.size.x * end_n
	if start_n > 0.001:
		draw_rect(Rect2(rect.position, Vector2(x0 - rect.position.x, rect.size.y)), Color(0, 0, 0, 0.45), true)
	if end_n < 0.999:
		draw_rect(Rect2(Vector2(x1, rect.position.y), Vector2(rect.end.x - x1, rect.size.y)), Color(0, 0, 0, 0.45), true)
	draw_line(Vector2(x0, rect.position.y), Vector2(x0, rect.end.y), Color(0.95, 0.85, 0.4, 0.9), 1.0)
	draw_line(Vector2(x1, rect.position.y), Vector2(x1, rect.end.y), Color(0.95, 0.85, 0.4, 0.9), 1.0)


func _ready_waveform() -> Waveform:
	if device == null or device.sample_waveform == null:
		return null
	return device.sample_waveform.get_ready_level()


func _draw_peaks(waveform: Waveform, rect: Rect2) -> void:
	var peaks := waveform.peak_data_left
	if peaks.is_empty():
		return
	var n := peaks.size()
	var mid := rect.position.y + rect.size.y * 0.5
	var amp := rect.size.y * 0.45
	var fill := Color(0.35, 0.7, 0.95, 0.55)
	var pts: PackedVector2Array = PackedVector2Array()
	for i in range(n):
		var x := rect.position.x + rect.size.x * (float(i) / float(maxi(n - 1, 1)))
		pts.append(Vector2(x, mid - peaks[i].y * amp))
	for i in range(n - 1, -1, -1):
		var x := rect.position.x + rect.size.x * (float(i) / float(maxi(n - 1, 1)))
		pts.append(Vector2(x, mid - peaks[i].x * amp))
	if pts.size() >= 3:
		draw_colored_polygon(pts, fill)
