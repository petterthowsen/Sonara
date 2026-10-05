## Panel view of the built-in Sampler: an interactive `SampleDisplay` (play and loop points,
## live playheads) over rows of controls grouped as Playback, Pitch, Loop, Filter and Amp.
##
## The controls are built in `_build` and bound to parameters by name, so the layout doesn't
## depend on parameter ids. Everything goes through `DeviceInstance` (never OSC directly). Dragging
## a display point applies live and records one undo step when the drag ends.
##
## While shown, the view subscribes to the device's `"playheads"` data stream.
class_name SamplerDefaultView extends DeviceView

static var logger := Log.make("SamplerView")

const ENVELOPE_HEIGHT := 56.0
const GROUP_TITLE_COLOR := Color(0.62, 0.62, 0.68)
const DIMMED := 0.4
const PLAYHEAD_STREAM := "playheads"
## Display points → the parameter that stores them.
const POINT_PARAMS := {
	SampleDisplay.Point.PLAY_START: "Start",
	SampleDisplay.Point.PLAY_END: "End",
	SampleDisplay.Point.LOOP_START: "Loop Start",
	SampleDisplay.Point.LOOP_END: "Loop End",
}
## Knobs: [parameter name, caption]. The format comes from `_knob_text`.
const KNOBS_PLAYBACK := [["Speed", "Speed"], ["Voices", "Voices"], ["Velocity", "Vel"]]
const KNOBS_PITCH := [["Root", "Root"], ["Tune", "Tune"], ["Fine", "Fine"]]
const KNOBS_FILTER := [["Cutoff", "Cutoff"], ["Resonance", "Res"], ["Filter Key Track", "Key"]]
const KNOBS_AMP := [["Attack", "A"], ["Decay", "D"], ["Sustain", "S"], ["Release", "R"], ["Volume", "Vol"]]
const TIME_KNOBS := ["Attack", "Decay", "Release"]

var display: SampleDisplay
var envelope_control: EnvelopeControl

var _knobs: Dictionary[String, LabeledKnob] = {}
var _segments: Dictionary[String, SegmentedControl] = {}
var _checks: Dictionary[String, CheckBox] = {}
var _envelope: Envelope = null
var _syncing := false
var _built := false
var _bound_source: AudioSourceInfo = null
var _shown := false
var _subscribed := false
## Drag in progress on the display: {which, param_id, old}.
var _drag := {}


func _ready() -> void:
	_build()
	if device != null:
		_setup()


func _exit_tree() -> void:
	_set_subscribed(false)


# ============================================================================
# BUILD
# ============================================================================

func _build() -> void:
	if _built:
		return
	_built = true
	display = SampleDisplay.new()
	display.name = "SampleDisplay"
	display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	display.point_drag_started.connect(_on_point_drag_started)
	display.point_dragged.connect(_on_point_dragged)
	display.point_drag_ended.connect(_on_point_drag_ended)
	add_child(display)

	var top := _row()
	top.add_child(_group("Playback", [
		_stack([_segment("Play Mode", ["One-shot", "Gated"]), _check("Reverse")]),
		_knob_row(KNOBS_PLAYBACK),
	]))
	top.add_child(_group("Pitch", [_knob_row(KNOBS_PITCH), _check("Key Track")]))
	top.add_child(_group("Loop", [
		_stack([_segment("Loop Mode", ["Off", "On", "Ping-Pong"])]),
		_knob_row([["Crossfade", "Xfade"]]),
	]))
	add_child(top)

	var bottom := _row()
	var filter := VBoxContainer.new()
	filter.add_child(_segment("Filter Type", ["Off", "LP12", "LP24", "BP12", "BP24", "HP12", "HP24"]))
	filter.add_child(_knob_row(KNOBS_FILTER))
	bottom.add_child(_group("Filter", [filter]))
	envelope_control = (load("res://components/EnvelopeControl.tscn") as PackedScene).instantiate()
	envelope_control.custom_minimum_size = Vector2(110, ENVELOPE_HEIGHT)
	envelope_control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bottom.add_child(_group("Amp", [envelope_control, _knob_row(KNOBS_AMP)]))
	add_child(bottom)
	_setup_envelope()


func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	return row


## A titled group; `children` sit side by side under the title.
func _group(title: String, children: Array) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", GROUP_TITLE_COLOR)
	box.add_child(label)
	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	for child in children:
		inner.add_child(child)
	box.add_child(inner)
	return box


func _stack(children: Array) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	for child in children:
		box.add_child(child)
	return box


func _knob_row(entries: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	for entry in entries:
		var knob := LabeledKnob.new()
		knob.text = entry[1]
		knob.label_width = 40.0
		knob.knob_size = Vector2(30, 30)
		knob.label.add_theme_font_size_override("font_size", 10)
		knob.knob.value_changed.connect(_on_knob_changed.bind(entry[0]))
		knob.knob.reset_requested.connect(_on_knob_reset.bind(entry[0]))
		row.add_child(knob)
		_knobs[entry[0]] = knob
	return row


func _segment(param_name: String, labels: Array) -> SegmentedControl:
	var segment := SegmentedControl.new()
	segment.set_items(PackedStringArray(labels))
	segment.font_size = 10
	segment.selected_changed.connect(_on_segment_selected.bind(param_name))
	_segments[param_name] = segment
	return segment


func _check(param_name: String) -> CheckBox:
	var check := CheckBox.new()
	check.text = param_name
	check.add_theme_font_size_override("font_size", 10)
	check.toggled.connect(_on_check_toggled.bind(param_name))
	_checks[param_name] = check
	return check


func _setup_envelope() -> void:
	_envelope = envelope_control.envelope
	if _envelope == null:
		_envelope = Envelope.new()
		envelope_control.envelope = _envelope
	_envelope.min_attack = 0.001
	_envelope.max_attack = 2.0
	_envelope.min_decay = 0.001
	_envelope.max_decay = 2.0
	_envelope.min_release = 0.001
	_envelope.max_release = 2.0
	_envelope.set_adsr(0.001, 0.001, 1.0, 0.01)
	_envelope.attack_changed.connect(_on_envelope_changed.bind("Attack"))
	_envelope.decay_changed.connect(_on_envelope_changed.bind("Decay"))
	_envelope.sustain_changed.connect(_on_envelope_changed.bind("Sustain"))
	_envelope.release_changed.connect(_on_envelope_changed.bind("Release"))


# ============================================================================
# BINDING
# ============================================================================

func _on_bind() -> void:
	if is_node_ready():
		_setup()


## Everything that needs both the scene and the device.
func _setup() -> void:
	_configure_knobs()
	for knob_name in _knobs:
		var id := device.get_parameter_id_by_name(knob_name)
		ModAssign.attach(_knobs[knob_name].knob, device, id)
	device.sample_source_changed.connect(_bind_source)
	device.loading_state_changed.connect(_on_loading_state_changed)
	_bind_source()
	_refresh()


func _on_unbind() -> void:
	_set_subscribed(false)
	_unbind_source()
	if device != null:
		if device.sample_source_changed.is_connected(_bind_source):
			device.sample_source_changed.disconnect(_bind_source)
		if device.loading_state_changed.is_connected(_on_loading_state_changed):
			device.loading_state_changed.disconnect(_on_loading_state_changed)
	if display != null:
		display.clear_playheads()


## Point each knob at its parameter's range, curve and text.
func _configure_knobs() -> void:
	for knob_name in _knobs:
		var param := device.get_parameter(device.get_parameter_id_by_name(knob_name))
		var knob: RotaryKnob = _knobs[knob_name].knob
		if param == null:
			continue
		knob.min_value = param.min_value
		knob.max_value = param.max_value
		knob.logarithmic = param.is_logarithmic or knob_name in TIME_KNOBS
		knob.value_default = param.default_value
		knob.step = 1.0 if knob_name in ["Root", "Voices"] else 0.0
		knob.value_text_callback = _knob_text.bind(knob_name)


## The knob's readout for `value` (real units).
static func _knob_text(value: float, param_name: String) -> String:
	match param_name:
		"Speed", "Crossfade", "Resonance", "Filter Key Track":
			return "%d%%" % roundi(value)
		"Velocity", "Sustain":
			return "%d%%" % roundi(value * 100.0)
		"Tune":
			return "%+.1f st" % value
		"Fine":
			return "%+d ct" % roundi(value)
		"Root":
			return Midi.midi_to_note_name(roundi(value))
		"Voices":
			return "%d" % roundi(value)
		"Cutoff":
			return "%.2f kHz" % (value / 1000.0) if value >= 1000.0 else "%d Hz" % roundi(value)
		"Volume":
			return "-inf dB" if value <= 0.0001 else "%+.1f dB" % (20.0 * log(value) / log(10.0))
		"Attack", "Decay", "Release":
			return "%.1f ms" % (value * 1000.0) if value < 1.0 else "%.2f s" % value
	return "%.2f" % value


func _on_device_parameter_changed(_param_id: int, _value: float) -> void:
	if is_node_ready():
		_refresh()


## Copy every parameter onto the controls and the display, without echoing back.
func _refresh() -> void:
	if device == null or not is_node_ready():
		return
	_syncing = true
	for knob_name in _knobs:
		var id := device.get_parameter_id_by_name(knob_name)
		if id >= 0:
			_knobs[knob_name].knob.set_value_no_signal(device.get_parameter_real(id))
	for param_name in _segments:
		var id := device.get_parameter_id_by_name(param_name)
		if id >= 0:
			_segments[param_name].set_selected_no_signal(int(device.get_parameter_real(id)))
	for param_name in _checks:
		var id := device.get_parameter_id_by_name(param_name)
		if id >= 0:
			_checks[param_name].set_pressed_no_signal(device.get_parameter_real(id) >= 0.5)
	_envelope.set_adsr(
		_real("Attack", 0.001), _real("Decay", 0.001), _real("Sustain", 1.0), _real("Release", 0.01))
	_syncing = false
	_refresh_display()
	_update_enabled()


func _real(param_name: String, fallback: float) -> float:
	var id := device.get_parameter_id_by_name(param_name)
	return device.get_parameter_real(id) if id >= 0 else fallback


func _refresh_display() -> void:
	# While a point is dragged the display is ahead of the (echoing) device; leave it alone.
	if _drag.is_empty():
		display.play_start = _real("Start", 0.0)
		display.play_end = _real("End", 1.0)
		display.loop_start = _real("Loop Start", 0.0)
		display.loop_end = _real("Loop End", 1.0)
	display.loop_mode = int(_real("Loop Mode", 0.0))
	display.xfade = _real("Crossfade", 0.0) / 100.0
	display.reverse = _real("Reverse", 0.0) >= 0.5


## Crossfade only applies to Loop On; the filter knobs only when a filter type is chosen.
func _update_enabled() -> void:
	_set_enabled(_knobs["Crossfade"], int(_real("Loop Mode", 0.0)) == SampleDisplay.LoopMode.ON)
	var filter_on := int(_real("Filter Type", 0.0)) != 0
	for knob_name in ["Cutoff", "Resonance", "Filter Key Track"]:
		_set_enabled(_knobs[knob_name], filter_on)


func _set_enabled(knob: LabeledKnob, enabled: bool) -> void:
	knob.modulate.a = 1.0 if enabled else DIMMED
	knob.knob.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE


# ============================================================================
# CONTROL HANDLERS
# ============================================================================

func _on_knob_changed(value: float, param_name: String) -> void:
	_set_real(param_name, value)


func _on_knob_reset(param_name: String) -> void:
	if device == null:
		return
	var param := device.get_parameter(device.get_parameter_id_by_name(param_name))
	if param != null:
		device.set_parameter_real(param.id, param.default_value)


func _on_segment_selected(index: int, param_name: String) -> void:
	_set_real(param_name, float(index))


func _on_check_toggled(pressed: bool, param_name: String) -> void:
	_set_real(param_name, 1.0 if pressed else 0.0)


func _set_real(param_name: String, value: float) -> void:
	if _syncing or device == null:
		return
	var id := device.get_parameter_id_by_name(param_name)
	if id >= 0:
		device.set_parameter_real(id, value)


## Apply an envelope stage to the device and record a mergeable undo step.
func _on_envelope_changed(value: float, param_name: String) -> void:
	var param_id := device.get_parameter_id_by_name(param_name) if device != null else -1
	if _syncing or param_id < 0:
		return
	var old_value := device.get_parameter_normalized(param_id)
	device.set_parameter_real(param_id, value)
	var new_value := device.get_parameter_normalized(param_id)
	if absf(new_value - old_value) < 0.0001:
		return
	var cmd := PropertyCommand.new("Set Parameter", device, "", [param_id, old_value], [param_id, new_value])
	cmd.set_callable(func(id, v): device.set_parameter_normalized(id, v)).set_unpack_array(true).set_mergeable(true)
	HistoryUtil.record(cmd)


# ============================================================================
# DISPLAY POINTS
# ============================================================================

func _on_point_drag_started(which: int) -> void:
	if device == null:
		return
	var id := device.get_parameter_id_by_name(POINT_PARAMS[which])
	_drag = {"which": which, "param_id": id, "old": device.get_parameter_normalized(id)}


func _on_point_dragged(which: int, value: float) -> void:
	if device == null:
		return
	var id := device.get_parameter_id_by_name(POINT_PARAMS[which])
	if id >= 0:
		device.set_parameter_normalized(id, value)


## One undo step for the whole drag.
func _on_point_drag_ended(_which: int) -> void:
	var drag := _drag
	_drag = {}
	if device == null or drag.is_empty() or int(drag["param_id"]) < 0:
		return
	var id: int = drag["param_id"]
	var new_value := device.get_parameter_normalized(id)
	if absf(new_value - float(drag["old"])) < 0.0001:
		return
	var cmd := PropertyCommand.new(
		"Move Sample Point", device, "", [id, drag["old"]], [id, new_value])
	cmd.set_callable(func(pid, v): device.set_parameter_normalized(pid, v)).set_unpack_array(true)
	HistoryUtil.record(cmd)


# ============================================================================
# WAVEFORM
# ============================================================================

## Follow `device.sample_source`, including when the object is replaced and not just refilled.
func _bind_source() -> void:
	_unbind_source()
	if device == null:
		return
	if device.sample_source == null:
		device.sample_source = AudioSourceInfo.new()
		return # the assignment emitted sample_source_changed, which rebinds
	_bound_source = device.sample_source
	_bound_source.waveform_ready.connect(_update_waveform)
	_bound_source.metadata_changed.connect(_update_waveform)
	_update_waveform()


func _unbind_source() -> void:
	if _bound_source != null:
		if _bound_source.waveform_ready.is_connected(_update_waveform):
			_bound_source.waveform_ready.disconnect(_update_waveform)
		if _bound_source.metadata_changed.is_connected(_update_waveform):
			_bound_source.metadata_changed.disconnect(_update_waveform)
	_bound_source = null


func _on_loading_state_changed(_state: String) -> void:
	_update_waveform()


func _update_waveform() -> void:
	if display == null:
		return
	var source := _bound_source
	display.data = source.data if source != null else null
	display.duration = source.audio_duration_seconds if source != null else 0.0
	display.frames = source.audio_frames if source != null else 0
	var ready := display.data != null and display.data.is_ready()
	if ready:
		display.placeholder = ""
	else:
		var empty := device == null or device.loaded_file_path.is_empty()
		display.placeholder = "Drop an audio file" if empty else "Loading…"


# ============================================================================
# PLAYHEADS
# ============================================================================

func _on_view_shown() -> void:
	_shown = true
	if is_node_ready():
		_update_waveform()
	_set_subscribed(true)


func _on_view_hidden() -> void:
	_shown = false
	_set_subscribed(false)
	if display != null:
		display.clear_playheads()


func _set_subscribed(want: bool) -> void:
	want = want and _shown and device != null
	if want == _subscribed:
		return
	var tree := Engine.get_main_loop() as SceneTree
	var osc: Node = tree.root.get_node_or_null("AudioEngineOSC") if tree != null else null
	if osc == null:
		return
	if want:
		osc.subscribe_device_data(device.osc_path(), PLAYHEAD_STREAM)
		if not osc.device_data_received.is_connected(_on_data_received):
			osc.device_data_received.connect(_on_data_received)
	else:
		if device != null:
			osc.unsubscribe_device_data(device.osc_path(), PLAYHEAD_STREAM)
		if osc.device_data_received.is_connected(_on_data_received):
			osc.device_data_received.disconnect(_on_data_received)
	_subscribed = want


func _on_data_received(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type != PLAYHEAD_STREAM or device == null or osc_path != device.osc_path():
		return
	apply_playheads(blob)


## Feed a `"playheads"` blob to the display (also what the tests call).
func apply_playheads(blob: PackedByteArray, now_ms: int = Time.get_ticks_msec()) -> void:
	var decoded := SampleDisplay.decode_playheads(blob)
	if int(decoded["count"]) == 0:
		display.clear_playheads()
	else:
		display.apply_playhead_packet(decoded, now_ms)
