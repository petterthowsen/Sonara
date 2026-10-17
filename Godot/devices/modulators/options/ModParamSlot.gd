## One modulator parameter in an options scene: a box holding an optional caption `Label` and one
## value control (`RotaryKnob`, `CompactSlider`, `OptionButton` or `CheckButton`), bound to parameter `param_id`
## of a modulator. Lay it out in the editor as an HBox (caption beside a dropdown) or a VBox
## (caption above a knob); `bind` configures whichever control it finds. A caption left empty takes the parameter
## name. The slot hides itself when the modulator has no such parameter (e.g. Sustain on AD).
class_name ModParamSlot extends BoxContainer

@export var param_id := 0
## Shows a float parameter holding a MIDI controller number as a dropdown of `Midi.cc_option_label`
## entries, one per whole number in the parameter's range.
@export var midi_cc := false

var modulator: Modulator = null
var param: DeviceParameter = null
## The value control (RotaryKnob, CompactSlider, OptionButton or CheckButton), or null.
var control: Control = null


func bind(mod: Modulator) -> void:
	modulator = mod
	param = mod.get_parameter(param_id) if mod != null else null
	control = _find_control()
	visible = param != null
	if param == null or control == null:
		return
	var caption := _find_caption()
	if caption != null and caption.text.is_empty():
		caption.text = param.name
	if control is RotaryKnob:
		_bind_knob(control as RotaryKnob)
	elif control is CompactSlider:
		_bind_slider(control as CompactSlider)
	elif control is OptionButton:
		_bind_dropdown(control as OptionButton)
	elif control is CheckButton:
		var id := param_id
		(control as CheckButton).toggled.connect(func(pressed: bool): mod.set_param(id, 1.0 if pressed else 0.0))
	refresh()


## Push the model's value into the control without echoing it back.
func refresh() -> void:
	if param == null or control == null:
		return
	var value := modulator.get_param(param_id)
	if control is RotaryKnob:
		(control as RotaryKnob).set_value_no_signal(value)
	elif control is CompactSlider:
		(control as CompactSlider).set_value_no_signal(value)
	elif control is OptionButton:
		var n := _dropdown_count()
		(control as OptionButton).select(clampi(int(round(value * float(n - 1))), 0, n - 1))
	elif control is CheckButton:
		(control as CheckButton).set_pressed_no_signal(value >= 0.5)


## A normalized knob, attached through `ModAssign` so other modulators can route into it like
## into any device knob.
func _bind_knob(knob: RotaryKnob) -> void:
	var p := param
	var mod := modulator
	knob.min_value = 0.0
	knob.max_value = 1.0
	knob.value_default = p.value_to_normalized(p.default_value)
	knob.value_text_callback = func(v: float) -> String: return SimpleUnits.format(p, v, "")
	knob.value_changed.connect(func(v: float): mod.set_param(p.id, v))
	ModAssign.attach_modulator(knob, mod.owner(), mod.mod_id, p.id)


## A normalized value slider, bound like the knob (range 0..1, default, text, `ModAssign`).
func _bind_slider(slider: CompactSlider) -> void:
	var p := param
	var mod := modulator
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.default_value = p.value_to_normalized(p.default_value)
	slider.value_text_callback = func(v: float) -> String: return SimpleUnits.format(p, v, "")
	slider.value_changed.connect(func(v: float): mod.set_param(p.id, v))
	ModAssign.attach_modulator(slider, mod.owner(), mod.mod_id, p.id)


func _bind_dropdown(dropdown: OptionButton) -> void:
	var p := param
	var mod := modulator
	dropdown.clear()
	for i in _dropdown_count():
		dropdown.add_item(Midi.cc_option_label(i) if midi_cc else p.enum_values[i], i)
	dropdown.item_selected.connect(func(index: int):
		var n := _dropdown_count()
		mod.set_param(p.id, 0.0 if n <= 1 else float(index) / float(n - 1)))


func _dropdown_count() -> int:
	if midi_cc:
		return int(param.max_value - param.min_value) + 1
	return maxi(1, param.enum_values.size())


func _find_control() -> Control:
	for child in get_children():
		if child is RotaryKnob or child is CompactSlider or child is OptionButton or child is CheckButton:
			return child
	return null


func _find_caption() -> Label:
	for child in get_children():
		if child is Label:
			return child
	return null
