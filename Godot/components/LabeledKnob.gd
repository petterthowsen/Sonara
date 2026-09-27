## RotaryKnob with a caption above or below it. A caption too long for `label_width` ends in an
## ellipsis; hovering the knob or caption shows the full caption on top (`LabelOverlay`). The
## value tooltip goes on the side away from the caption so the two never overlap.
class_name LabeledKnob extends VBoxContainer

enum LabelPosition { TOP, BOTTOM }

@export var label_position := LabelPosition.BOTTOM:
	set(p):
		label_position = p
		_apply_label_position()

## Caption width in pixels. Longer text is trimmed with an ellipsis.
@export var label_width := 44.0:
	set(w):
		label_width = w
		if label:
			label.custom_minimum_size.x = w

@export var knob_size := Vector2(32, 32):
	set(s):
		knob_size = s
		if knob:
			knob.custom_minimum_size = s

@export var text := "":
	set(t):
		text = t
		if label:
			label.text = t
		if overlay:
			overlay.refresh()

var knob: RotaryKnob
var label: Label
var overlay: LabelOverlay


func _init() -> void:
	add_theme_constant_override("separation", 2)
	knob = RotaryKnob.new()
	knob.name = "RotaryKnob"
	knob.custom_minimum_size = knob_size
	knob.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(knob)

	label = Label.new()
	label.name = "Label"
	label.text = text
	label.custom_minimum_size.x = label_width
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(label)

	overlay = LabelOverlay.attach(label, [knob])
	_apply_label_position()


## Caption before or after the knob, and the value tooltip on the other side.
func _apply_label_position() -> void:
	if knob == null or label == null:
		return
	var top := label_position == LabelPosition.TOP
	move_child(label, 0 if top else -1)
	knob.tooltip_side = RotaryKnob.TooltipSide.BELOW if top else RotaryKnob.TooltipSide.ABOVE
