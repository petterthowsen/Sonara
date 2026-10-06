## Binds a `SampleDisplay` to a Sampler `DeviceInstance`: the sample source and its waveform, the
## Start/End/Loop parameters shown on the display, live playheads and point drags (one undo step
## each). Shared by the Panel and Window views so they behave the same (spec 023, REQ-003).
##
## In multisample mode the display follows the focused zone instead: its source, name (the title),
## points, loop mode, crossfade and reverse, and point drags edit that zone. The binder also owns
## what both views do with the display: the title's zone focus menu (REQ-021), the empty Sampler's
## "Create Multisample" button (REQ-010), dropped files (`SamplerActions.drop_files`) and the
## right-click "Convert to …" menu (REQ-013, REQ-014).
##
## Everything goes through `DeviceInstance` and `SamplerActions`, never OSC. While active,
## subscribes to the device's `"playheads"` data stream (the engine reports only the focused
## zone's voices in multisample mode).
class_name SampleDisplayBinder extends RefCounted

const PLAYHEAD_STREAM := "playheads"
## Binders subscribed per device path. The engine keeps one flag for the stream, so the Panel and
## Window views of one Sampler must not switch it off for each other: it is switched off with the
## last binder.
static var _subscribers := {}
## Display points → the parameter that stores them.
const POINT_PARAMS := {
	SampleDisplay.Point.PLAY_START: "Start",
	SampleDisplay.Point.PLAY_END: "End",
	SampleDisplay.Point.LOOP_START: "Loop Start",
	SampleDisplay.Point.LOOP_END: "Loop End",
}
## Display points → the zone field that stores them in multisample mode.
const POINT_FIELDS := {
	SampleDisplay.Point.PLAY_START: "start",
	SampleDisplay.Point.PLAY_END: "end",
	SampleDisplay.Point.LOOP_START: "loop_start",
	SampleDisplay.Point.LOOP_END: "loop_end",
}
const DROP_PLACEHOLDER := "Drop sample(s) here"
const CREATE_MULTISAMPLE := "Create Multisample"
enum MenuId { TO_MULTISAMPLE, TO_SINGLE }

var display: SampleDisplay
var device: DeviceInstance

var _model: SamplerMultisample = null
var _bound_source: AudioSourceInfo = null
var _shown := false
var _subscribed := false
var _subscribed_path := ""
## Drag in progress on the display: {which, param_id, old} or, on a zone, {which, zone_id, old}.
var _drag := {}
var _focus_menu: PopupMenu = null
var _mode_menu: PopupMenu = null


func _init(p_display: SampleDisplay) -> void:
	display = p_display
	display.point_drag_started.connect(_on_point_drag_started)
	display.point_dragged.connect(_on_point_dragged)
	display.point_drag_ended.connect(_on_point_drag_ended)
	display.title_clicked.connect(open_focus_menu)
	display.placeholder_action_pressed.connect(_on_placeholder_action)
	display.context_menu_requested.connect(open_mode_menu)
	display.assets_dropped.connect(_on_assets_dropped)


## Follow `p_device`. Call `unbind` before dropping the binder.
func bind(p_device: DeviceInstance) -> void:
	unbind()
	device = p_device
	device.sample_source_changed.connect(_bind_source)
	device.loading_state_changed.connect(_on_loading_state_changed)
	_model = device.ensure_multisample()
	_model.mode_changed.connect(_on_model_switched)
	_model.zones_changed.connect(_on_model_switched)
	_model.focus_changed.connect(_on_focus_changed)
	_model.zone_changed.connect(_on_zone_changed)
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
	if _model != null:
		_model.mode_changed.disconnect(_on_model_switched)
		_model.zones_changed.disconnect(_on_model_switched)
		_model.focus_changed.disconnect(_on_focus_changed)
		_model.zone_changed.disconnect(_on_zone_changed)
	_model = null
	device = null
	if _display_valid():
		display.clear_playheads()


func _display_valid() -> bool:
	return display != null and is_instance_valid(display)


func multisample_active() -> bool:
	return _model != null and _model.active


## The zone the display shows in multisample mode, or null.
func focused_zone() -> SamplerZone:
	return _model.focused_zone() if multisample_active() else null


func _real(param_name: String, fallback: float) -> float:
	var id := device.get_parameter_id_by_name(param_name)
	return device.get_parameter_real(id) if id >= 0 else fallback


## Copy the playback and loop settings (parameters, or the focused zone's) onto the display.
func refresh() -> void:
	if device == null or not _display_valid():
		return
	if multisample_active():
		var zone := focused_zone()
		display.title = zone.name if zone else ""
		# While a point is dragged the display is ahead of the model; leave it alone.
		if zone and _drag.is_empty():
			display.play_start = zone.start
			display.play_end = zone.end
			display.loop_start = zone.loop_start
			display.loop_end = zone.loop_end
		display.gain = zone.gain if zone else 1.0
		display.loop_mode = (zone.loop_mode if zone else 0) as SampleDisplay.LoopMode
		display.xfade = zone.crossfade if zone else 0.0
		display.reverse = zone.reverse if zone else false
		return
	display.title = ""
	display.gain = _real("Volume", 1.0)
	if _drag.is_empty():
		display.play_start = _real("Start", 0.0)
		display.play_end = _real("End", 1.0)
		display.loop_start = _real("Loop Start", 0.0)
		display.loop_end = _real("Loop End", 1.0)
	display.loop_mode = int(_real("Loop Mode", 0.0)) as SampleDisplay.LoopMode
	display.xfade = _real("Crossfade", 0.0) / 100.0
	display.reverse = _real("Reverse", 0.0) >= 0.5


func _on_model_switched() -> void:
	_bind_source()
	refresh()


func _on_focus_changed(_zone_id: int) -> void:
	if _display_valid():
		display.clear_playheads()
	_on_model_switched()


func _on_zone_changed(zone_id: int) -> void:
	var zone := focused_zone()
	if zone != null and zone.id == zone_id:
		refresh()
		_update_waveform()


# ============================================================================
# DISPLAY POINTS
# ============================================================================

func _on_point_drag_started(which: int) -> void:
	if device == null:
		return
	if multisample_active():
		var zone := focused_zone()
		if zone:
			_drag = {"which": which, "zone_id": zone.id, "old": _model.snapshot_zone(zone.id)}
		return
	var id := device.get_parameter_id_by_name(POINT_PARAMS[which])
	_drag = {"which": which, "param_id": id, "old": device.get_parameter_normalized(id)}


func _on_point_dragged(which: int, value: float) -> void:
	if device == null:
		return
	if _drag.has("zone_id"):
		_model.set_zone_fields(int(_drag["zone_id"]), {POINT_FIELDS[which]: value})
		return
	if multisample_active():
		return
	var id := device.get_parameter_id_by_name(POINT_PARAMS[which])
	if id >= 0:
		device.set_parameter_normalized(id, value)


## One undo step for the whole drag.
func _on_point_drag_ended(_which: int) -> void:
	var drag := _drag
	_drag = {}
	if device == null or drag.is_empty():
		return
	if drag.has("zone_id"):
		_record_zone_drag(drag)
		return
	if int(drag["param_id"]) < 0:
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


func _record_zone_drag(drag: Dictionary) -> void:
	var zone := _model.get_zone(int(drag["zone_id"]))
	if zone == null:
		return
	var new_snap := _model.snapshot_zone(zone.id)
	if new_snap == drag["old"]:
		return
	var cmd := PropertyCommand.new("Move Sample Point", zone, "", drag["old"], new_snap)
	cmd.set_callable(_model.restore_zone)
	HistoryUtil.record(cmd)


# ============================================================================
# WAVEFORM
# ============================================================================

## Follow the shown source: `device.sample_source` in single mode (including when the object is
## replaced and not just refilled), the focused zone's in multisample mode.
func _bind_source() -> void:
	_unbind_source()
	if device == null:
		return
	if multisample_active():
		var zone := focused_zone()
		_bound_source = zone.source if zone else null
	else:
		if device.sample_source == null:
			device.sample_source = AudioSourceInfo.new()
			return # the assignment emitted sample_source_changed, which rebinds
		_bound_source = device.sample_source
	if _bound_source != null:
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
	var multi := multisample_active()
	var empty := device == null or (focused_zone() == null if multi else device.loaded_file_path.is_empty())
	display.placeholder_action = CREATE_MULTISAMPLE if empty and not multi and device != null else ""
	if ready:
		display.placeholder = ""
	elif empty:
		display.placeholder = DROP_PLACEHOLDER
	elif multi and focused_zone().is_missing():
		display.placeholder = "Missing: %s" % focused_zone().missing_reason()
	else:
		display.placeholder = "Loading…"


# ============================================================================
# MENUS, DROPS AND THE PLACEHOLDER ACTION
# ============================================================================

func _on_placeholder_action() -> void:
	if device != null:
		SamplerActions.convert_to_multisample(device)


func _on_assets_dropped(assets: Array) -> void:
	if device != null:
		SamplerActions.drop_files(device, assets.map(func(a: Asset): return a.path))


func _make_menu(menu_name: String) -> PopupMenu:
	var menu := PopupMenu.new()
	menu.name = menu_name
	menu.theme_type_variation = &"ContextMenuList"
	display.add_child(menu, false, Node.INTERNAL_MODE_BACK)
	return menu


## Fill the zone focus menu: every zone sorted by root key, the focused one checked. Item ids are
## zone ids. Returns the menu (built on first use).
func fill_focus_menu() -> PopupMenu:
	if _focus_menu == null:
		_focus_menu = _make_menu("ZoneFocusMenu")
		_focus_menu.id_pressed.connect(func(zone_id: int) -> void:
			if multisample_active():
				_model.set_focus(zone_id))
	_focus_menu.clear()
	if multisample_active():
		for zone in _model.zones_by_root():
			_focus_menu.add_radio_check_item("%s   %s" % [zone.name, Midi.midi_to_note_name(zone.root)], zone.id)
			_focus_menu.set_item_checked(_focus_menu.item_count - 1, zone.id == _model.focused_zone_id)
	return _focus_menu


## The title was clicked: choose the focused zone from a menu (REQ-021).
func open_focus_menu() -> void:
	if not multisample_active() or not _display_valid():
		return
	var menu := fill_focus_menu()
	var rect := display.title_rect()
	menu.popup(Rect2i(Vector2i(display.get_screen_position() + rect.position + Vector2(0, rect.size.y)), Vector2i.ZERO))


## Fill the right-click menu: the mode conversion that applies.
func fill_mode_menu() -> PopupMenu:
	if _mode_menu == null:
		_mode_menu = _make_menu("SampleModeMenu")
		_mode_menu.id_pressed.connect(_on_mode_menu_id)
	_mode_menu.clear()
	if multisample_active():
		_mode_menu.add_item("Convert to Single Sample", MenuId.TO_SINGLE)
	else:
		_mode_menu.add_item("Convert to Multisample", MenuId.TO_MULTISAMPLE)
	return _mode_menu


func open_mode_menu(at: Vector2) -> void:
	if device == null or not _display_valid():
		return
	fill_mode_menu().popup(Rect2i(Vector2i(display.get_screen_position() + at), Vector2i.ZERO))


func _on_mode_menu_id(id: int) -> void:
	if device == null:
		return
	match id:
		MenuId.TO_MULTISAMPLE:
			SamplerActions.convert_to_multisample(device)
		MenuId.TO_SINGLE:
			SamplerActions.convert_to_single(device)


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
	var path := device.osc_path() if want else _subscribed_path
	if want:
		_subscribed_path = path
		_subscribers[path] = int(_subscribers.get(path, 0)) + 1
		osc.subscribe_device_data(path, PLAYHEAD_STREAM)
		if not osc.device_data_received.is_connected(_on_data_received):
			osc.device_data_received.connect(_on_data_received)
	else:
		var remaining := int(_subscribers.get(path, 0)) - 1
		if remaining > 0:
			_subscribers[path] = remaining
		else:
			_subscribers.erase(path)
			osc.unsubscribe_device_data(path, PLAYHEAD_STREAM)
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
