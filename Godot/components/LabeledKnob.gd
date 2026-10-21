@tool
## RotaryKnob with a caption above or below it. A caption too long for `label_width` ends in an
## ellipsis; hovering the knob or caption shows the full caption on top (`LabelOverlay`). The
## value tooltip goes on the side away from the caption so the two never overlap.
class_name LabeledKnob extends VBoxContainer

enum LabelPosition { TOP, BOTTOM }
## What the text under the knob shows. BOTH stacks the knob, the value (small font) and the
## caption (normal font).
enum DisplayMode { LABEL, VALUE, BOTH }

const VALUE_FONT_SIZE := 12

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

## LABEL (default) shows the caption only. VALUE and BOTH show the value text under the knob
## and drop the hover tooltip, which would repeat it; VALUE keeps the caption as the knob's
## native tooltip.
@export var display_mode := DisplayMode.LABEL:
	set(m):
		display_mode = m
		_apply_display_mode()

var knob: RotaryKnob
var label: Label
var value_label: Label
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

	value_label = Label.new()
	value_label.name = "ValueLabel"
	value_label.custom_minimum_size.x = label_width
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value_label.add_theme_font_size_override("font_size", VALUE_FONT_SIZE)
	value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value_label.visible = false
	add_child(value_label)
	knob.value_set.connect(refresh_value_text)

	overlay = LabelOverlay.attach(label, [knob])
	_apply_label_position()


## Caption before or after the knob, and the value tooltip on the other side. The value text
## sits between the knob and the caption.
func _apply_label_position() -> void:
	if knob == null or label == null:
		return
	var top := label_position == LabelPosition.TOP
	move_child(label, 0 if top else -1)
	if value_label != null:
		move_child(value_label, 2 if top else 1)
	knob.tooltip_side = RotaryKnob.TooltipSide.BELOW if top else RotaryKnob.TooltipSide.ABOVE


## Re-read the knob's value text. Call it after changing the knob's format, unit or callback.
func refresh_value_text() -> void:
	if value_label != null and display_mode != DisplayMode.LABEL:
		value_label.text = knob.get_value_text()


func _apply_display_mode() -> void:
	if knob == null or label == null or value_label == null:
		return
	var show_value := display_mode != DisplayMode.LABEL
	label.visible = display_mode != DisplayMode.VALUE
	value_label.visible = show_value
	knob.show_value_tooltip = not show_value
	knob.tooltip_text = text if display_mode == DisplayMode.VALUE else ""
	refresh_value_text()
