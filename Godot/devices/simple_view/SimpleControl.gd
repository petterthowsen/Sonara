## SimpleControl.gd
## One grid cell of a Simple View: an optional title label plus the inner control for a layout
## control entry (`{kind, params, rect, group?, label?, unit?}`, see `SimpleLayout`). Builds the
## right inner control for the entry's kind (REQ-003) and binds it to the device instance's
## parameters, including the compound kinds (xy, envelope, eq_band).

class_name SimpleControl extends VBoxContainer

static var logger := Log.make("SimpleControl")

const SEGMENT_FONT_SIZE := 13
## Horizontal space a segment button needs beyond its label (stylebox margins + separation).
const SEGMENT_PADDING := 10.0
## Font size of the value readout (knob tooltip, spin box).
const VALUE_FONT_SIZE := 13

## Color of the control's title (dimmer than group titles, so groups read first).
@export var title_color := Color(1, 1, 1, 0.6)

@onready var _title: Label = $Title
@onready var _body: Control = $Body

var instance: DeviceInstance = null
var control_data: Dictionary = {}

var _param_ids: Array[int] = []
var _inner: Control = null
var _envelope: Envelope = null
## Full title on hover when it's trimmed; created on the first bind.
var _title_overlay: LabelOverlay = null
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
	_title.add_theme_color_override("font_color", title_color)
	if _title_overlay == null:
		_title_overlay = LabelOverlay.attach(_title)
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
		SimpleControlKinds.SPINBOX:
			_refresh_spinbox()
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
		SimpleControlKinds.SPINBOX:
			_inner = _build_spinbox()
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
		# Single-parameter controls reveal their full title while hovered, like the title itself.
		if kind in [SimpleControlKinds.KNOB, SimpleControlKinds.SLIDER]:
			_title_overlay.add_hover_source(_inner)


func _build_knob() -> RotaryKnob:
	var knob := RotaryKnob.new()
	knob.min_value = 0.0
	knob.max_value = 1.0
	knob.value_default = _param(0).value_to_normalized(_param(0).default_value) if _param(0) else 0.5
	knob.value_text_callback = _format_value
	# the title sits above, so keep the value readout from covering it
	knob.tooltip_side = RotaryKnob.TooltipSide.BELOW
	knob.value_font_size = VALUE_FONT_SIZE
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


## An enum whose labels are consecutive integers (e.g. an octave, -2…+2), shown as the number.
## The spin box counts in label values; the enum index is `value - first`.
func _build_spinbox() -> SpinBox:
	var spin := SpinBox.new()
	var param := _param(0)
	var first := _spinbox_first()
	spin.min_value = first
	spin.max_value = first + maxi(0, param.enum_values.size() - 1) if param else first
	spin.step = 1.0
	spin.rounded = true
	spin.alignment = HORIZONTAL_ALIGNMENT_CENTER
	spin.select_all_on_focus = true
	spin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	spin.get_line_edit().add_theme_font_size_override("font_size", VALUE_FONT_SIZE)
	spin.value_changed.connect(func(v):
		var n: int = maxi(1, param.enum_values.size()) if param else 1
		var index := int(round(v)) - first
		_commit(0, 0.0 if n <= 1 else float(index) / float(n - 1)))
	return spin


## Value of the first label of an integer enum (0 when it isn't one).
func _spinbox_first() -> int:
	var param := _param(0)
	if param == null or param.enum_values.is_empty():
		return 0
	var first: Variant = ParamClassifier.integer_label_value(param.enum_values[0])
	return int(first) if first != null else 0


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


## Any subset of attack/decay/sustain/release (`stages`, default "adsr"). Times are real seconds
## with the parameters' ranges; sustain is the parameter's normalized value (plugins use 0–1,
## percent or dB), shown as a 0–1 level.
func _build_envelope() -> EnvelopeControl:
	var control := EnvelopeControl.new()
	_envelope = Envelope.new()
	_envelope.stages = _envelope_stages()
	for stage in 4:
		var param := _envelope_param(stage)
		if param == null or stage == Envelope.Stage.SUSTAIN:
			continue
		var lo := maxf(0.0, param.min_value)
		_envelope.set_stage_range(stage, lo, maxf(lo + 0.001, param.max_value))
	control.envelope = _envelope
	_envelope.attack_changed.connect(_commit_envelope.bind(Envelope.Stage.ATTACK))
	_envelope.decay_changed.connect(_commit_envelope.bind(Envelope.Stage.DECAY))
	_envelope.sustain_changed.connect(_commit_envelope.bind(Envelope.Stage.SUSTAIN))
	_envelope.release_changed.connect(_commit_envelope.bind(Envelope.Stage.RELEASE))
	return control


func _envelope_stages() -> String:
	return String(control_data.get("stages", "adsr"))


## Index into the bound params for an envelope stage, or -1 when the envelope lacks it.
func _envelope_index(stage: int) -> int:
	return _envelope_stages().find(Envelope.STAGE_LETTERS[stage])


func _envelope_param(stage: int) -> DeviceParameter:
	var index := _envelope_index(stage)
	return _param(index) if index >= 0 else null


func _commit_envelope(value: float, stage: int) -> void:
	var index := _envelope_index(stage)
	if index < 0:
		return
	if stage == Envelope.Stage.SUSTAIN:
		_commit(index, value)
	else:
		_commit_real(index, value)


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


func _refresh_spinbox() -> void:
	var param := _param(0)
	if param == null:
		return
	var n := maxi(1, param.enum_values.size())
	var idx := clampi(int(round(_normalized(0) * float(n - 1))), 0, n - 1)
	# Not set_value_no_signal: that leaves the spin box text stale. `_updating` stops the echo.
	(_inner as SpinBox).value = _spinbox_first() + idx


func _refresh_envelope() -> void:
	if _envelope == null:
		return
	var values: Array[float] = []
	for stage in 4:
		var index := _envelope_index(stage)
		var param := _param(index) if index >= 0 else null
		if param == null:
			values.append(_envelope.get_stage_value(stage))
		elif stage == Envelope.Stage.SUSTAIN:
			values.append(_normalized(index))
		else:
			values.append(param.normalized_to_value(_normalized(index)))
	_envelope.set_adsr(values[0], values[1], values[2], values[3])


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
