## Binds a `SampleDisplay` to a Sampler `DeviceInstance`: the sample source and its waveform, the
## Start/End/Loop parameters shown on the display, live playheads and point drags (one undo step
## each). Shared by the Panel and Window views so they behave the same (spec 023, REQ-003).
##
## Everything goes through `DeviceInstance`, never OSC. While active, subscribes to the device's
## `"playheads"` data stream.
class_name SampleDisplayBinder extends RefCounted

const PLAYHEAD_STREAM := "playheads"
## Display points → the parameter that stores them.
const POINT_PARAMS := {
	SampleDisplay.Point.PLAY_START: "Start",
	SampleDisplay.Point.PLAY_END: "End",
	SampleDisplay.Point.LOOP_START: "Loop Start",
	SampleDisplay.Point.LOOP_END: "Loop End",
}

var display: SampleDisplay
var device: DeviceInstance

var _bound_source: AudioSourceInfo = null
var _shown := false
var _subscribed := false
## Drag in progress on the display: {which, param_id, old}.
var _drag := {}


func _init(p_display: SampleDisplay) -> void:
	display = p_display
	display.point_drag_started.connect(_on_point_drag_started)
	display.point_dragged.connect(_on_point_dragged)
	display.point_drag_ended.connect(_on_point_drag_ended)


## Follow `p_device`. Call `unbind` before dropping the binder.
func bind(p_device: DeviceInstance) -> void:
	unbind()
	device = p_device
	device.sample_source_changed.connect(_bind_source)
	device.loading_state_changed.connect(_on_loading_state_changed)
	_bind_source()
	refresh()


func unbind() -> void:
	_set_subscribed(false)
	_unbind_source()
	if device != null:
		if device.sample_source_changed.is_connected(_bind_source):
			device.sample_source_changed.disconnect(_bind_source)
		if device.loading_state_changed.is_connected(_on_loading_state_changed):
			device.loading_state_changed.disconnect(_on_loading_state_changed)
	device = null
	if _display_valid():
		display.clear_playheads()


func _display_valid() -> bool:
	return display != null and is_instance_valid(display)


func _real(param_name: String, fallback: float) -> float:
	var id := device.get_parameter_id_by_name(param_name)
	return device.get_parameter_real(id) if id >= 0 else fallback


## Copy the playback and loop parameters onto the display.
func refresh() -> void:
	if device == null or not _display_valid():
		return
	# While a point is dragged the display is ahead of the (echoing) device; leave it alone.
	if _drag.is_empty():
		display.play_start = _real("Start", 0.0)
		display.play_end = _real("End", 1.0)
		display.loop_start = _real("Loop Start", 0.0)
		display.loop_end = _real("Loop End", 1.0)
	display.loop_mode = int(_real("Loop Mode", 0.0))
	display.xfade = _real("Crossfade", 0.0) / 100.0
	display.reverse = _real("Reverse", 0.0) >= 0.5


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
	var dev := device
	var cmd := PropertyCommand.new(
		"Move Sample Point", dev, "", [id, drag["old"]], [id, new_value])
	cmd.set_callable(func(pid, v): dev.set_parameter_normalized(pid, v)).set_unpack_array(true)
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
	if not _display_valid():
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

## The owning view became visible (`true`) or hidden (`false`).
func set_shown(shown: bool) -> void:
	_shown = shown
	if shown:
		_update_waveform()
	else:
		if _display_valid():
			display.clear_playheads()
	_set_subscribed(shown)


## Drop the data-stream subscription without changing the shown state (the view left the tree).
func release_stream() -> void:
	_set_subscribed(false)


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
	if not _display_valid():
		return
	var decoded := SampleDisplay.decode_playheads(blob)
	if int(decoded["count"]) == 0:
		display.clear_playheads()
	else:
		display.apply_playhead_packet(decoded, now_ms)
