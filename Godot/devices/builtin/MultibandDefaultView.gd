## Panel view of Multiband FX (`sonara.builtin.multiband`, spec 016).
##
## Top: six band toggles (positions 1–6) and the Mix / Out knobs. Middle: the crossover strip
## (`MultibandStrip`). Bottom: one row per active band, low to high, with its color, name, Mute and
## Solo toggles and Gain knob. These are device parameters, not Layer slot controls. Clicking a row
## opens that band's slot chain in the device lane.
##
## Toggling a band goes through `Multiband.toggle_command`; disabling a band that holds devices asks
## for confirmation first.
class_name MultibandDefaultView extends DeviceView

const BandRowHeight := 30.0

var _toggles: Array[Button] = []
var _strip: MultibandStrip
var _rows_box: VBoxContainer
var _mix_knob: LabeledKnob
var _out_knob: LabeledKnob
var _confirm: ConfirmationDialog
var _pending_band := 0
## Per active band row: {band, mute: Button, solo: Button, gain: RotaryKnob, row: PanelContainer}
var _rows: Array[Dictionary] = []
var _built := false


func _get_minimum_size() -> Vector2:
	return Vector2(380, 0)


func _ready() -> void:
	_build()
	if device != null:
		_refresh_all()


func _build() -> void:
	if _built:
		return
	_built = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	root.add_child(top)
	for p in range(1, Multiband.BAND_COUNT + 1):
		var button := Button.new()
		button.text = str(p)
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(26, 26)
		button.toggled.connect(_on_band_toggled.bind(p))
		top.add_child(button)
		_toggles.append(button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	_mix_knob = _make_knob(top, "Mix", Multiband.ID_MIX)
	_out_knob = _make_knob(top, "Out", Multiband.ID_OUTPUT)

	_strip = MultibandStrip.new()
	_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_strip)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 2)
	scroll.add_child(_rows_box)

	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(_on_disable_confirmed)
	add_child(_confirm)


func _make_knob(parent: Control, caption: String, param_id: int) -> LabeledKnob:
	var knob := LabeledKnob.new()
	knob.text = caption
	knob.knob_size = Vector2(30, 30)
	knob.label_width = 30.0
	knob.knob.value_changed.connect(_on_knob_changed.bind(param_id))
	parent.add_child(knob)
	return knob


func _on_bind() -> void:
	if not is_node_ready():
		await ready
	_strip.bind(device)
	for sig in [device.slots_changed, device.name_changed]:
		if not sig.is_connected(_refresh_all):
			sig.connect(_refresh_all)
	_configure_knob(_mix_knob.knob, Multiband.ID_MIX, "%.0f", " %")
	_configure_knob(_out_knob.knob, Multiband.ID_OUTPUT, "%.1f", " dB")
	_refresh_all()


func _on_unbind() -> void:
	for sig in [device.slots_changed, device.name_changed]:
		if sig.is_connected(_refresh_all):
			sig.disconnect(_refresh_all)


func _configure_knob(knob: RotaryKnob, param_id: int, format: String, unit: String) -> void:
	var param := device.get_parameter(param_id)
	if param == null:
		return
	knob.min_value = param.min_value
	knob.max_value = param.max_value
	knob.value_default = param.default_value
	knob.value_format = format
	knob.unit = unit


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


func _make_row(position: int) -> Dictionary:
	var chain := device.children[position - 1]
	var key := device.slot_key_for(chain)
	var color := device.slot_color(key)
	var open := device.is_slot_open(key)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.2, 0.2, 0.95) if open else Color(0.12, 0.12, 0.12, 0.6)
	style.border_width_left = 4
	style.border_color = color if open else color.darkened(0.3)
	style.content_margin_left = 8
	style.content_margin_right = 4
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	style.set_corner_radius_all(3)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(0, BandRowHeight)
	panel.tooltip_text = ("Hide %s" if open else "Show %s") % chain.get_display_name()
	panel.gui_input.connect(_on_row_gui_input.bind(chain))
	_rows_box.add_child(panel)

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var name_label := Label.new()
	name_label.text = "%s%s" % [chain.get_display_name(), "  (%d)" % chain.children.size() if not chain.children.is_empty() else ""]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(name_label)

	var mute := _make_flag_button("M", "Mute", Multiband.param_id(position, Multiband.OFFSET_MUTE))
	var solo := _make_flag_button("S", "Solo", Multiband.param_id(position, Multiband.OFFSET_SOLO))
	box.add_child(mute)
	box.add_child(solo)

	var gain := RotaryKnob.new()
	gain.custom_minimum_size = Vector2(24, 24)
	gain.mouse_filter = Control.MOUSE_FILTER_STOP
	var gain_id := Multiband.param_id(position, Multiband.OFFSET_GAIN)
	_configure_knob(gain, gain_id, "%.1f", " dB")
	gain.tooltip_text = "Band gain"
	gain.value_changed.connect(_on_knob_changed.bind(gain_id))
	box.add_child(gain)
	return {"band": position, "mute": mute, "solo": solo, "gain": gain}


func _make_flag_button(text: String, tip: String, param_id: int) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(24, 22)
	button.add_theme_font_size_override("font_size", 10)
	button.toggled.connect(_on_flag_toggled.bind(param_id))
	return button


func _refresh_values() -> void:
	if device == null:
		return
	_mix_knob.knob.set_value_no_signal(device.get_parameter_real(Multiband.ID_MIX))
	_out_knob.knob.set_value_no_signal(device.get_parameter_real(Multiband.ID_OUTPUT))
	for row in _rows:
		var p := int(row["band"])
		(row["mute"] as Button).set_pressed_no_signal(device.get_parameter_real(Multiband.param_id(p, Multiband.OFFSET_MUTE)) >= 0.5)
		(row["solo"] as Button).set_pressed_no_signal(device.get_parameter_real(Multiband.param_id(p, Multiband.OFFSET_SOLO)) >= 0.5)
		(row["gain"] as RotaryKnob).set_value_no_signal(device.get_parameter_real(Multiband.param_id(p, Multiband.OFFSET_GAIN)))


# --- Input ----------------------------------------------------------------------------------------


func _on_knob_changed(value: float, param_id: int) -> void:
	if device == null:
		return
	var old := device.get_parameter_normalized(param_id)
	device.set_parameter_real(param_id, value)
	_record_param("Set Parameter", param_id, old)


func _on_flag_toggled(on: bool, param_id: int) -> void:
	if device == null:
		return
	var old := device.get_parameter_normalized(param_id)
	device.set_parameter_normalized(param_id, 1.0 if on else 0.0)
	_record_param("Set Parameter", param_id, old, false)


func _record_param(label: String, param_id: int, old: float, mergeable := true) -> void:
	var now := device.get_parameter_normalized(param_id)
	if is_equal_approx(old, now):
		return
	var target := device
	var cmd := PropertyCommand.new(label, null, "", old, now).set_mergeable(mergeable)
	HistoryUtil.record(cmd.set_callable(func(v): target.set_parameter_normalized(param_id, v)))


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
