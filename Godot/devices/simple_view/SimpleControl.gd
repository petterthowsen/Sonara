## SimpleControl.gd
## One grid cell of a Simple View: an optional title label plus the inner control for a layout
## control entry (`{kind, params, rect, group?, label?, unit?}`, see `SimpleLayout`). Builds the
## right inner control for the entry's kind (REQ-003) and binds it to the device instance's
## parameters, including the compound kinds (xy, envelope, eq_band).

class_name SimpleControl extends VBoxContainer

static var logger := Log.make("SimpleControl")

const SEGMENT_FONT_SIZE := 11
## Horizontal space a segment button needs beyond its label (stylebox margins + separation).
const SEGMENT_PADDING := 10.0

@onready var _title: Label = $Title
@onready var _body: Control = $Body

var instance: DeviceInstance = null
var control_data: Dictionary = {}

var _param_ids: Array[int] = []
var _inner: Control = null
var _envelope: Envelope = null
## True while pushing device values into the inner control(s), so their signals don't loop back.
var _updating := false


## Bind to `p_instance` and build the inner control for `data` (a layout control dict).
func bind(p_instance: DeviceInstance, data: Dictionary) -> void:
	if not is_node_ready():
		await ready
	instance = p_instance
	control_data = data
	_param_ids.clear()
	for id in data.get("params", []):
		_param_ids.append(int(id))
	clip_contents = true
	_body.custom_minimum_size = Vector2.ZERO
	_title.text = _title_text()
	_title.tooltip_text = _title.text
	_title.clip_text = false
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.custom_minimum_size.x = 0.0
	_title.visible = not _title.text.is_empty()
	_build_inner()
	refresh()


## True when this control shows `param_id` (lets the view skip controls a change doesn't touch).
func handles_param(param_id: int) -> bool:
	return param_id in _param_ids


## Push the current device values into the inner control(s) without emitting their signals.
func refresh() -> void:
	if instance == null or _inner == null:
		return
	_updating = true
	match String(control_data.get("kind", "")):
		SimpleControlKinds.KNOB, SimpleControlKinds.SLIDER:
			_refresh_single(_inner)
		SimpleControlKinds.TOGGLE:
			(_inner as CheckButton).set_pressed_no_signal(_normalized(0) >= 0.5)
		SimpleControlKinds.SEGMENTED, SimpleControlKinds.DROPDOWN:
			_refresh_choice(_inner)
		SimpleControlKinds.XY:
			(_inner as XYSlider).set_values_no_signal(_normalized(0), _normalized(1))
		SimpleControlKinds.ENVELOPE:
			_refresh_envelope()
		SimpleControlKinds.EQ_BAND:
			_refresh_eq_band()
	_updating = false


## The label shown above the control: the layout's override, else the first parameter's name.
func _title_text() -> String:
	var label := String(control_data.get("label", ""))
	if not label.is_empty():
		return label
	var param := _param(0)
	return param.name if param else ""


## Parameter metadata for the `index`-th bound id, or null.
func _param(index: int) -> DeviceParameter:
	if instance == null or index >= _param_ids.size():
		return null
	return instance.get_parameter(_param_ids[index])


## Current normalized value of the `index`-th bound parameter.
func _normalized(index: int) -> float:
	if instance == null or index >= _param_ids.size():
		return 0.0
	return instance.get_parameter_normalized(_param_ids[index])


## Display unit override from the layout, empty for the parameter's own unit.
func _unit_override() -> String:
	return String(control_data.get("unit", ""))


## ============================================================================
## BUILD
## ============================================================================

func _build_inner() -> void:
	for child in _body.get_children():
		child.queue_free()
	_inner = null
	_envelope = null
	var kind := String(control_data.get("kind", ""))
	if kind == SimpleControlKinds.SEGMENTED and not _segments_fit():
		kind = SimpleControlKinds.DROPDOWN
	match kind:
		SimpleControlKinds.KNOB:
			_inner = _build_knob()
		SimpleControlKinds.SLIDER:
			_inner = _build_slider()
		SimpleControlKinds.TOGGLE:
			_inner = _build_toggle()
		SimpleControlKinds.SEGMENTED:
			_inner = _build_segmented()
		SimpleControlKinds.DROPDOWN:
			_inner = _build_dropdown()
		SimpleControlKinds.XY:
			_inner = _build_xy()
		SimpleControlKinds.ENVELOPE:
			_inner = _build_envelope()
		SimpleControlKinds.EQ_BAND:
			_inner = _build_eq_band()
		_:
			logger.warning("Unknown control kind '%s'" % control_data.get("kind"))
	if _inner:
		_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_body.add_child(_inner)
		_inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _build_knob() -> RotaryKnob:
	var knob := RotaryKnob.new()
	knob.min_value = 0.0
	knob.max_value = 1.0
	knob.value_default = _param(0).value_to_normalized(_param(0).default_value) if _param(0) else 0.5
	knob.value_text_callback = _format_value
	knob.value_changed.connect(func(v): _commit(0, v))
	return knob


func _build_slider() -> HorSlider:
	var slider := HorSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.bidirectional = false
	slider.default_value = _param(0).value_to_normalized(_param(0).default_value) if _param(0) else 0.5
	slider.value_changed.connect(func(v): _commit(0, v))
	return slider


func _build_toggle() -> CheckButton:
	var toggle := CheckButton.new()
	toggle.text = ""
	toggle.toggled.connect(func(pressed): _commit(0, 1.0 if pressed else 0.0))
	return toggle


## True when every segment label fits in this control's width at the segment font size; otherwise
## `_build_inner` falls back to a dropdown so the buttons never spill into neighbouring cells.
func _segments_fit() -> bool:
	var param := _param(0)
	if param == null or param.enum_values.is_empty():
		return true
	var font := get_theme_default_font()
	var per_button := size.x / float(param.enum_values.size())
	for value in param.enum_values:
		var text_width := font.get_string_size(String(value), HORIZONTAL_ALIGNMENT_LEFT, -1, SEGMENT_FONT_SIZE).x
		if text_width + SEGMENT_PADDING > per_button:
			return false
	return true


func _build_segmented() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	var group := ButtonGroup.new()
	var values := _param(0).enum_values if _param(0) else []
	for i in range(values.size()):
		var btn := Button.new()
		btn.text = values[i]
		btn.tooltip_text = values[i]
		btn.clip_text = true
		btn.add_theme_font_size_override("font_size", SEGMENT_FONT_SIZE)
		btn.toggle_mode = true
		btn.button_group = group
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_commit.bind(0, 0.0 if values.size() <= 1 else float(i) / float(values.size() - 1)))
		row.add_child(btn)
	return row


func _build_dropdown() -> OptionButton:
	var dropdown := OptionButton.new()
	dropdown.fit_to_longest_item = false
	dropdown.clip_text = true
	dropdown.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var values := _param(0).enum_values if _param(0) else []
	for i in range(values.size()):
		dropdown.add_item(values[i], i)
	dropdown.item_selected.connect(func(index):
		var n: int = maxi(1, values.size())
		_commit(0, 0.0 if n <= 1 else float(index) / float(n - 1)))
	return dropdown


func _build_xy() -> XYSlider:
	var xy := XYSlider.new()
	xy.x_min = 0.0
	xy.x_max = 1.0
	xy.y_min = 0.0
	xy.y_max = 1.0
	xy.values_changed.connect(func(x, y):
		if _updating:
			return
		_commit(0, x)
		_commit(1, y))
	return xy


## Attack/decay/sustain/release, real seconds on the resource, ranges from the parameters.
func _build_envelope() -> EnvelopeControl:
	var control := EnvelopeControl.new()
	_envelope = Envelope.new()
	var attack := _param(0)
	var decay := _param(1)
	var release := _param(3)
	if attack:
		_envelope.min_attack = maxf(0.001, attack.min_value)
		_envelope.max_attack = maxf(_envelope.min_attack + 0.001, attack.max_value)
	if decay:
		_envelope.min_decay = maxf(0.001, decay.min_value)
		_envelope.max_decay = maxf(_envelope.min_decay + 0.001, decay.max_value)
	if release:
		_envelope.min_release = maxf(0.001, release.min_value)
		_envelope.max_release = maxf(_envelope.min_release + 0.001, release.max_value)
	control.envelope = _envelope
	_envelope.attack_changed.connect(func(v): _commit_real(0, v))
	_envelope.decay_changed.connect(func(v): _commit_real(1, v))
	_envelope.sustain_changed.connect(func(v): _commit_real(2, v))
	_envelope.release_changed.connect(func(v): _commit_real(3, v))
	return control


## Three small knobs (freq, gain, q) in a row. `EQ_BAND`'s 2×1 footprint is too tight for the
## XY-plus-knob layout `design.md` sketches, so this uses the same knob building block instead
## (see the Simple View Phase 3 note in STATUS.md).
func _build_eq_band() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	for i in range(3):
		var knob := RotaryKnob.new()
		knob.min_value = 0.0
		knob.max_value = 1.0
		knob.custom_minimum_size = Vector2(18, 18)
		knob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var param := _param(i)
		knob.value_text_callback = func(v): return SimpleUnits.format(param, v, "") if param else ""
		knob.value_changed.connect(_commit.bind(i))
		row.add_child(knob)
	return row


## ============================================================================
## REFRESH HELPERS
## ============================================================================

func _refresh_single(node: Control) -> void:
	if node is RotaryKnob:
		(node as RotaryKnob).set_value_no_signal(_normalized(0))
	elif node is HorSlider:
		(node as HorSlider).set_value_no_signal(_normalized(0))


func _refresh_choice(node: Control) -> void:
	var param := _param(0)
	if param == null:
		return
	var n := maxi(1, param.enum_values.size())
	var idx := clampi(int(round(_normalized(0) * float(n - 1))), 0, n - 1)
	if node is OptionButton:
		(node as OptionButton).select(idx)
	elif node is HBoxContainer:
		var children := (node as HBoxContainer).get_children()
		if idx < children.size():
			(children[idx] as Button).set_pressed_no_signal(true)


func _refresh_envelope() -> void:
	if _envelope == null:
		return
	_envelope.set_adsr(
		_param(0).normalized_to_value(_normalized(0)) if _param(0) else _envelope.attack,
		_param(1).normalized_to_value(_normalized(1)) if _param(1) else _envelope.decay,
		_param(2).normalized_to_value(_normalized(2)) if _param(2) else _envelope.sustain,
		_param(3).normalized_to_value(_normalized(3)) if _param(3) else _envelope.release
	)


func _refresh_eq_band() -> void:
	if _inner == null:
		return
	for i in range(mini(3, _inner.get_child_count())):
		var knob := _inner.get_child(i) as RotaryKnob
		if knob:
			knob.set_value_no_signal(_normalized(i))


## ============================================================================
## COMMIT (UI → device)
## ============================================================================

## Send the `index`-th bound parameter's normalized value to the device.
func _commit(index: int, normalized: float) -> void:
	if _updating or instance == null or index >= _param_ids.size():
		return
	instance.set_parameter_normalized(_param_ids[index], normalized)


## Send a real (unnormalized) value for the `index`-th bound parameter, e.g. envelope seconds.
func _commit_real(index: int, real_value: float) -> void:
	if _updating or instance == null or index >= _param_ids.size():
		return
	var param := _param(index)
	if param == null:
		return
	instance.set_parameter_normalized(_param_ids[index], param.value_to_normalized(real_value))


## Value text for a single-parameter control's tooltip/inline display.
func _format_value(normalized: float) -> String:
	var param := _param(0)
	return SimpleUnits.format(param, normalized, _unit_override()) if param else ""
