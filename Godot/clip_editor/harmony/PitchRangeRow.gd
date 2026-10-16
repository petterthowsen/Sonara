## A MIDI pitch range control for the harmony dialogs: a dual-handle slider with a note-name
## readout ("C2 - C4"). The handles may cross; `range_value()` always returns lo <= hi.
class_name PitchRangeRow extends HBoxContainer

signal changed(range: Vector2i)

var slider: HDualSlider
var readout: Label


func _init() -> void:
	add_theme_constant_override("separation", 8)
	slider = HDualSlider.new()
	slider.min_value = 0.0
	slider.max_value = 127.0
	slider.custom_minimum_size = Vector2(220, 20)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_child(slider)
	readout = Label.new()
	readout.custom_minimum_size.x = 84
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(readout)
	slider.values_changed.connect(func(_a: float, _b: float):
		_update_readout()
		changed.emit(range_value()))
	set_range(Vector2i(48, 72))


## Show `range` without emitting `changed`.
func set_range(range: Vector2i) -> void:
	slider.set_values_no_signal(float(range.x), float(range.y))
	_update_readout()


func range_value() -> Vector2i:
	var a := roundi(slider.a_value)
	var b := roundi(slider.b_value)
	return Vector2i(mini(a, b), maxi(a, b))


## "C2 - C4" for a range.
static func range_text(range: Vector2i) -> String:
	return "%s - %s" % [Midi.midi_to_note_name(range.x), Midi.midi_to_note_name(range.y)]


func _update_readout() -> void:
	readout.text = range_text(range_value())
