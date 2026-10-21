## Panel view of Multiband FX (`sonara.builtin.multiband`, spec 016). The layout lives in
## `MultibandDefaultView.tscn`; each band row is a `MultibandBandRow.tscn` instance.
##
## Top: six band toggles (positions 1–6) and the Mix / Out knobs. Middle: the crossover strip
## (`MultibandStrip`). Bottom: one row per active band, low to high, with its color, name, Mute and
## Solo toggles and Gain knob. These are device parameters, not Layer slot controls. Clicking a row
## opens that band's slot chain in the device lane.
##
## Behind the crossover strip a faint spectrum of the device's input shows (the `"spectrum"` data
## stream, same frame layout as the EQ's: `[flag, sample_rate, lo_hz, hi_hz, points...]`). The view
## subscribes while shown and unsubscribes when hidden.
##
## Toggling a band goes through `Multiband.toggle_command`; disabling a band that holds devices asks
## for confirmation first.
class_name MultibandDefaultView extends DeviceView

## Spectrum frames start with `[flag, sample_rate, lo_hz, hi_hz]` (multiband.rs `SPECTRUM_HEADER_LEN`).
const SPECTRUM_HEADER_LEN := 4
const BandRowScene := preload("res://devices/builtin/multiband/MultibandBandRow.tscn")
## Preloaded rather than named, so the type resolves before the class cache knows `MultibandBandRow`.
const BandRow := preload("res://devices/builtin/multiband/MultibandBandRow.gd")

## Band toggles for positions 1–6, in order.
@onready var _toggles: Array[Button] = [%Band1, %Band2, %Band3, %Band4, %Band5, %Band6]
@onready var _strip: MultibandStrip = %Strip
@onready var _rows_box: VBoxContainer = %RowsBox
@onready var _mix_knob: LabeledKnob = %MixKnob
@onready var _out_knob: LabeledKnob = %OutKnob
@onready var _confirm: ConfirmationDialog = %Confirm
var _pending_band := 0
## One row per active band, low to high.
var _rows: Array[BandRow] = []
var _shown := false
var _subscribed := false


func _get_minimum_size() -> Vector2:
	return Vector2(380, 0)


## Hook the scene's controls to their handlers, then bind if a device arrived before the tree.
func _ready() -> void:
	for i in _toggles.size():
		_toggles[i].toggled.connect(_on_band_toggled.bind(i + 1))
	_mix_knob.knob.value_changed.connect(_on_knob_changed.bind(Multiband.ID_MIX))
	_out_knob.knob.value_changed.connect(_on_knob_changed.bind(Multiband.ID_OUTPUT))
	_confirm.confirmed.connect(_on_disable_confirmed)
	if device != null:
		_setup()


func _on_bind() -> void:
	if is_node_ready():
		_setup()


## Everything that needs both the scene and the device.
func _setup() -> void:
	_strip.bind(device)
	for sig in [device.slots_changed, device.name_changed]:
		if not sig.is_connected(_refresh_all):
			sig.connect(_refresh_all)
	_configure_knob(_mix_knob.knob, Multiband.ID_MIX, "%.0f", " %")
	_configure_knob(_out_knob.knob, Multiband.ID_OUTPUT, "%.1f", " dB")
	_refresh_all()


func _on_unbind() -> void:
	_shown = false
	_sync_subscription()
	for sig in [device.slots_changed, device.name_changed]:
		if sig.is_connected(_refresh_all):
			sig.disconnect(_refresh_all)


func _on_view_shown() -> void:
	_shown = true
	_sync_subscription()


func _on_view_hidden() -> void:
	_shown = false
	_sync_subscription()
	if _strip != null:
		_strip.clear_spectrum()


## Subscribe to the input spectrum while the view is shown and bound; drop it otherwise.
func _sync_subscription() -> void:
	var want := _shown and device != null
	if want == _subscribed:
		return
	var tree := Engine.get_main_loop() as SceneTree
	var osc: Node = tree.root.get_node_or_null("AudioEngineOSC") if tree != null else null
	if osc == null or device == null:
		return
	if want:
		osc.subscribe_device_data(device.osc_path(), "spectrum")
		osc.device_spectrum_received.connect(_on_spectrum_received)
	else:
		osc.unsubscribe_device_data(device.osc_path(), "spectrum")
		osc.device_spectrum_received.disconnect(_on_spectrum_received)
	_subscribed = want


## `frame`: `[flag, sample_rate, lo_hz, hi_hz, points...]`; the engine appends a second, unused
## signal after the first `SPECTRUM_POINTS` values.
func _on_spectrum_received(osc_path: String, frame: PackedFloat32Array) -> void:
	if device == null or osc_path != device.osc_path() or _strip == null:
		return
	apply_spectrum_frame(frame)


func apply_spectrum_frame(frame: PackedFloat32Array) -> void:
	if _strip == null:
		return
	if frame.size() < SPECTRUM_HEADER_LEN + 2 or frame[2] <= 0.0 or frame[3] <= frame[2]:
		return
	var points := (frame.size() - SPECTRUM_HEADER_LEN) / 2
	_strip.set_spectrum(frame.slice(SPECTRUM_HEADER_LEN, SPECTRUM_HEADER_LEN + points), frame[2], frame[3])


func _configure_knob(knob: RotaryKnob, param_id: int, format: String, unit: String) -> void:
	var param := device.get_parameter(param_id)
	if param == null:
		return
	knob.min_value = param.min_value
	knob.max_value = param.max_value
	knob.value_default = param.default_value
	knob.value_format = format
	knob.unit = unit
	ModAssign.attach(knob, device, param_id)


func _on_device_parameter_changed(param_id: int, _value: float) -> void:
	if not is_node_ready() or device == null:
		return
	if param_id >= 10 and param_id % 10 == Multiband.OFFSET_ACTIVE:
		_refresh_all()
	else:
		_refresh_values()
		_strip.queue_redraw()


## Rebuild everything that depends on which bands are active or how they are named.
func _refresh_all(_arg = null) -> void:
	if device == null or not is_node_ready():
		return
	var active := Multiband.active_positions(device)
	var names := Multiband.auto_names(device)
	for p in range(1, Multiband.BAND_COUNT + 1):
		var button := _toggles[p - 1]
		var on := p in active
		button.set_pressed_no_signal(on)
		button.disabled = on and not Multiband.can_disable(device, p)
		var range_text := _range_text(active, p)
		button.tooltip_text = "%s%s" % [names[p - 1] if on else "Band %d (off)" % p, range_text]
	_rebuild_rows(active)
	_refresh_values()
	_strip.queue_redraw()


func _range_text(active: Array[int], p: int) -> String:
	var i := active.find(p)
	if i < 0:
		return ""
	var lo := "0 Hz" if i == 0 else MultibandStrip._format_hz(Multiband.edge_hz(device, p))
	var hi := "Nyquist" if i + 1 >= active.size() else MultibandStrip._format_hz(Multiband.edge_hz(device, active[i + 1]))
	return "  %s – %s" % [lo, hi]


func _rebuild_rows(active: Array[int]) -> void:
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.queue_free()
	_rows.clear()
	for p in active:
		if p > device.children.size():
			continue
		_rows.append(_make_row(p))


func _make_row(position: int) -> BandRow:
	var chain := device.children[position - 1]
	var key := device.slot_key_for(chain)
	var row: BandRow = BandRowScene.instantiate()
	row.band = position
	row.show_band(chain, device.slot_color(key), device.is_slot_open(key))
	row.gui_input.connect(_on_row_gui_input.bind(chain))
	row.mute.toggled.connect(_on_flag_toggled.bind(Multiband.param_id(position, Multiband.OFFSET_MUTE)))
	row.solo.toggled.connect(_on_flag_toggled.bind(Multiband.param_id(position, Multiband.OFFSET_SOLO)))
	var gain_id := Multiband.param_id(position, Multiband.OFFSET_GAIN)
	_configure_knob(row.gain, gain_id, "%.1f", " dB")
	row.gain.value_changed.connect(_on_knob_changed.bind(gain_id))
	_rows_box.add_child(row)
	return row


func _refresh_values() -> void:
	if device == null:
		return
	_mix_knob.knob.set_value_no_signal(device.get_parameter_real(Multiband.ID_MIX))
	_out_knob.knob.set_value_no_signal(device.get_parameter_real(Multiband.ID_OUTPUT))
	for row in _rows:
		var p := row.band
		row.mute.set_pressed_no_signal(device.get_parameter_real(Multiband.param_id(p, Multiband.OFFSET_MUTE)) >= 0.5)
		row.solo.set_pressed_no_signal(device.get_parameter_real(Multiband.param_id(p, Multiband.OFFSET_SOLO)) >= 0.5)
		row.gain.set_value_no_signal(device.get_parameter_real(Multiband.param_id(p, Multiband.OFFSET_GAIN)))


# --- Input ----------------------------------------------------------------------------------------


func _on_knob_changed(value: float, param_id: int) -> void:
	if device == null:
		return
	ParameterActions.set_real(device, param_id, value)


func _on_flag_toggled(on: bool, param_id: int) -> void:
	if device == null:
		return
	ParameterActions.set_normalized(device, param_id, 1.0 if on else 0.0)



func _on_band_toggled(on: bool, position: int) -> void:
	if device == null:
		return
	if not on and Multiband.device_count(device, position) > 0:
		_pending_band = position
		var chain := device.children[position - 1]
		var count := Multiband.device_count(device, position)
		_confirm.dialog_text = "Disable %s? Its %d device%s will be removed." % [chain.get_display_name(), count, "" if count == 1 else "s"]
		_confirm.popup_centered()
		_refresh_all()  # the button snaps back until the user confirms
		return
	_apply_toggle(position, on)


func _on_disable_confirmed() -> void:
	if _pending_band > 0:
		_apply_toggle(_pending_band, false)
	_pending_band = 0


func _apply_toggle(position: int, on: bool) -> void:
	var cmd := Multiband.toggle_command(device, position, on)
	if cmd != null:
		HistoryUtil.execute(cmd)
	_refresh_all()


func _on_row_gui_input(event: InputEvent, chain: DeviceInstance) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		device.toggle_slot(device.slot_key_for(chain))
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		child_context_menu_requested.emit(chain)
