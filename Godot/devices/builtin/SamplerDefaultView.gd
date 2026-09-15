## Sampler panel: sample waveform, start/end region, ADSR graph, and knobs.
class_name SamplerDefaultView extends DeviceView

const ENVELOPE_HEIGHT := 56.0
const KNOB_ROW_HEIGHT := 52.0

@onready var _waveform_area: Control = $Waveform
@onready var _envelope_control: EnvelopeControl = $EnvelopeControl
@onready var _knob_attack: RotaryKnob = $KnobRow/Attack/Knob
@onready var _knob_decay: RotaryKnob = $KnobRow/Decay/Knob
@onready var _knob_sustain: RotaryKnob = $KnobRow/Sustain/Knob
@onready var _knob_release: RotaryKnob = $KnobRow/Release/Knob

var _start_id: int = -1
var _end_id: int = -1
var _attack_id: int = -1
var _decay_id: int = -1
var _sustain_id: int = -1
var _release_id: int = -1
var _envelope: Envelope = null
var _syncing_envelope := false


## Wire the scene envelope and knobs as soon as the view enters the tree.
func _ready() -> void:
	_setup_envelope()
	_setup_knobs()
	if _waveform_area and not _waveform_area.resized.is_connected(queue_redraw):
		_waveform_area.resized.connect(queue_redraw)


## Leave room below the waveform for the ADSR graph and knobs.
func _get_minimum_size() -> Vector2:
	return Vector2(220, 72.0 + _adsr_stack_height())


## Bind start/end and ADSR parameters, then refresh waveform and envelope.
func _on_bind() -> void:
	if not is_node_ready():
		await ready
	if device == null:
		return
	_start_id = device.get_parameter_id_by_name("Start")
	_end_id = device.get_parameter_id_by_name("End")
	_attack_id = device.get_parameter_id_by_name("Attack")
	_decay_id = device.get_parameter_id_by_name("Decay")
	_sustain_id = device.get_parameter_id_by_name("Sustain")
	_release_id = device.get_parameter_id_by_name("Release")
	_ensure_waveform()
	_connect_waveform()
	_sync_envelope_from_device()
	queue_redraw()


## Stop listening to the bound instance's waveform.
func _on_unbind() -> void:
	var wf: WaveformPyramid = device.sample_waveform
	if wf == null:
		return
	if wf.waveform_level_updated.is_connected(_on_waveform_changed):
		wf.waveform_level_updated.disconnect(_on_waveform_changed)
	if wf.metadata_changed.is_connected(_on_waveform_changed):
		wf.metadata_changed.disconnect(_on_waveform_changed)


## Reconnect waveform listeners and refresh the envelope when the panel is shown.
func _on_view_shown() -> void:
	_connect_waveform()
	_sync_envelope_from_device()
	queue_redraw()


## Keep the envelope editor and region overlay in sync with parameter changes.
func _on_device_parameter_changed(_param_id: int, _value: float) -> void:
	_sync_envelope_from_device()
	queue_redraw()


## Create a WaveformPyramid on the instance if the engine has not supplied one yet.
func _ensure_waveform() -> void:
	if device and device.sample_waveform == null:
		device.sample_waveform = WaveformPyramid.new()


## Listen for waveform metadata/level updates so the panel redraws.
func _connect_waveform() -> void:
	_ensure_waveform()
	if device == null or device.sample_waveform == null:
		return
	var wf: WaveformPyramid = device.sample_waveform
	if not wf.waveform_level_updated.is_connected(_on_waveform_changed):
		wf.waveform_level_updated.connect(_on_waveform_changed)
	if not wf.metadata_changed.is_connected(_on_waveform_changed):
		wf.metadata_changed.connect(_on_waveform_changed)


## Redraw when a new waveform level arrives.
func _on_waveform_changed(_level: int = 0) -> void:
	queue_redraw()


## Configure the scene envelope resource and listen for handle edits.
func _setup_envelope() -> void:
	if _envelope_control == null:
		push_error("SamplerDefaultView missing EnvelopeControl")
		return
	_envelope = _envelope_control.envelope
	if _envelope == null:
		_envelope = Envelope.new()
		_envelope_control.envelope = _envelope
	_envelope.min_attack = 0.001
	_envelope.max_attack = 2.0
	_envelope.min_decay = 0.001
	_envelope.max_decay = 2.0
	_envelope.min_release = 0.001
	_envelope.max_release = 2.0
	_envelope.set_adsr(0.001, 0.001, 1.0, 0.01)
	_envelope.attack_changed.connect(_on_envelope_attack_changed)
	_envelope.decay_changed.connect(_on_envelope_decay_changed)
	_envelope.sustain_changed.connect(_on_envelope_sustain_changed)
	_envelope.release_changed.connect(_on_envelope_release_changed)


## Height of the envelope graph plus the knob row.
func _adsr_stack_height() -> float:
	return ENVELOPE_HEIGHT + KNOB_ROW_HEIGHT


## Attach formatters and value listeners to the scene ADSR knobs.
func _setup_knobs() -> void:
	if _knob_attack == null:
		push_error("SamplerDefaultView missing ADSR knobs")
		return
	_knob_attack.value_text_callback = _format_envelope_time
	_knob_decay.value_text_callback = _format_envelope_time
	_knob_sustain.value_text_callback = _format_envelope_sustain
	_knob_release.value_text_callback = _format_envelope_time
	_knob_attack.value_changed.connect(_on_attack_knob_changed)
	_knob_decay.value_changed.connect(_on_decay_knob_changed)
	_knob_sustain.value_changed.connect(_on_sustain_knob_changed)
	_knob_release.value_changed.connect(_on_release_knob_changed)


## Format attack/decay/release as milliseconds or seconds.
func _format_envelope_time(seconds: float) -> String:
	if seconds < 1.0:
		return "%.1f ms" % (seconds * 1000.0)
	return "%.2f s" % seconds


## Format sustain as a percentage.
func _format_envelope_sustain(level: float) -> String:
	return "%d%%" % roundi(level * 100.0)


## Copy device ADSR values onto the envelope resource without echoing back.
func _sync_envelope_from_device() -> void:
	if device == null or _envelope == null:
		return
	_syncing_envelope = true
	_envelope.set_adsr(
		device.get_parameter_real(_attack_id) if _attack_id >= 0 else 0.001,
		device.get_parameter_real(_decay_id) if _decay_id >= 0 else 0.001,
		device.get_parameter_real(_sustain_id) if _sustain_id >= 0 else 1.0,
		device.get_parameter_real(_release_id) if _release_id >= 0 else 0.01
	)
	_sync_knobs_from_envelope()
	_syncing_envelope = false


## Push envelope stage values onto the knobs without emitting.
func _sync_knobs_from_envelope() -> void:
	if _envelope == null:
		return
	if _knob_attack:
		_knob_attack.set_value_no_signal(_envelope.attack)
	if _knob_decay:
		_knob_decay.set_value_no_signal(_envelope.decay)
	if _knob_sustain:
		_knob_sustain.set_value_no_signal(_envelope.sustain)
	if _knob_release:
		_knob_release.set_value_no_signal(_envelope.release)


## Apply an envelope stage to the device and record a mergeable undo step.
func _commit_envelope_param(param_id: int, value: float) -> void:
	if _syncing_envelope or device == null or param_id < 0:
		return
	var old_value := device.get_parameter_normalized(param_id)
	device.set_parameter_real(param_id, value)
	var new_value := device.get_parameter_normalized(param_id)
	if abs(new_value - old_value) < 0.0001:
		return
	var cmd := PropertyCommand.new(
		"Set Parameter",
		device,
		"",
		[param_id, old_value],
		[param_id, new_value]
	)
	cmd.set_callable(func(id, v): device.set_parameter_normalized(id, v)).set_unpack_array(true).set_mergeable(true)
	HistoryUtil.record(cmd)


## Push envelope attack time to the sampler Attack parameter.
func _on_envelope_attack_changed(value: float) -> void:
	_commit_envelope_param(_attack_id, value)
	if _knob_attack:
		_knob_attack.set_value_no_signal(value)


## Push envelope decay time to the sampler Decay parameter.
func _on_envelope_decay_changed(value: float) -> void:
	_commit_envelope_param(_decay_id, value)
	if _knob_decay:
		_knob_decay.set_value_no_signal(value)


## Push envelope sustain level to the sampler Sustain parameter.
func _on_envelope_sustain_changed(value: float) -> void:
	_commit_envelope_param(_sustain_id, value)
	if _knob_sustain:
		_knob_sustain.set_value_no_signal(value)


## Push envelope release time to the sampler Release parameter.
func _on_envelope_release_changed(value: float) -> void:
	_commit_envelope_param(_release_id, value)
	if _knob_release:
		_knob_release.set_value_no_signal(value)


## Apply attack from the knob onto the shared envelope resource.
func _on_attack_knob_changed(value: float) -> void:
	if _envelope:
		_envelope.attack = value


## Apply decay from the knob onto the shared envelope resource.
func _on_decay_knob_changed(value: float) -> void:
	if _envelope:
		_envelope.decay = value


## Apply sustain from the knob onto the shared envelope resource.
func _on_sustain_knob_changed(value: float) -> void:
	if _envelope:
		_envelope.sustain = value


## Apply release from the knob onto the shared envelope resource.
func _on_release_knob_changed(value: float) -> void:
	if _envelope:
		_envelope.release = value


## Draw the waveform and start/end region in the waveform slot.
func _draw() -> void:
	var rect := _waveform_rect()
	draw_rect(rect, Color(0.08, 0.08, 0.1, 1.0), true)
	var waveform := _ready_waveform()
	if waveform == null:
		var msg := "Drop an audio file" if device == null or device.loaded_file_path.is_empty() else "Loading…"
		draw_string(
			ThemeDB.fallback_font,
			Vector2(8, rect.position.y + rect.size.y * 0.5 + 4),
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


## Local rect of the scene waveform slot, falling back to the area above ADSR.
func _waveform_rect() -> Rect2:
	if _waveform_area:
		return Rect2(_waveform_area.position, _waveform_area.size)
	return Rect2(Vector2.ZERO, Vector2(size.x, maxf(size.y - _adsr_stack_height(), 1.0)))


## Return the highest ready waveform level, or null while loading/empty.
func _ready_waveform() -> Waveform:
	if device == null or device.sample_waveform == null:
		return null
	return device.sample_waveform.get_ready_level()


## Draw left-channel min/max peaks as a filled polygon in `rect`.
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
