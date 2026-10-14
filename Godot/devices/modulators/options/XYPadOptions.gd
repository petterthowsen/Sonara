## An XY pad's options (spec 036 REQ-005): one XY slider bound to both slots, with X and Y knobs
## beside it. The knobs write the same Position parameter and, unlike the slider, are modulator
## targets, so another modulator can route into a single axis.
class_name XYPadOptions extends ModulatorOptions

@onready var slider: XYSlider = %XYSlider
@onready var x_slot: ModParamSlot = %X
@onready var y_slot: ModParamSlot = %Y

var pad: XYPad = null


func setup_pair(p_pad: XYPad) -> void:
	pad = p_pad
	modulator = pad.x
	x_slot.bind(pad.x)
	y_slot.bind(pad.y)
	slider.values_changed.connect(func(x: float, y: float): pad.set_position(Vector2(x, y)))
	sync()


## Follow the model without echoing a `values_changed` back through `set_position`.
func sync() -> void:
	super.sync()
	if pad == null:
		return
	var pos := pad.position()
	slider.set_values_no_signal(pos.x, pos.y)
