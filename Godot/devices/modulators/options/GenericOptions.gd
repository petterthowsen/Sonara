## Fallback options for a kind without its own scene (an orphan XY slot, a kind added to the
## engine before the UI has a scene for it): one row of generated slots, a knob per float
## parameter and a dropdown per enum, or "No settings" when the kind has none. A row never wraps,
## so it widens the pane instead of growing taller.
class_name GenericOptions extends ModulatorOptions

const KNOB_SIDE := 44
const DROPDOWN_MIN_WIDTH := 96

@onready var _row: HBoxContainer = %Row
@onready var _none: Label = %NoSettings


func setup(mod: Modulator) -> void:
	for param in mod.get_parameters():
		_row.add_child(_make_slot(param))
	_none.visible = _row.get_child_count() == 0
	super.setup(mod)


func _make_slot(param: DeviceParameter) -> ModParamSlot:
	var slot := ModParamSlot.new()
	slot.vertical = true
	slot.param_id = param.id
	slot.alignment = BoxContainer.ALIGNMENT_CENTER
	var caption := Label.new()
	caption.theme_type_variation = &"Caption"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot.add_child(caption)
	var control: Control
	if param.param_type == "enum":
		var dropdown := OptionButton.new()
		dropdown.fit_to_longest_item = false
		dropdown.clip_text = true
		dropdown.custom_minimum_size.x = DROPDOWN_MIN_WIDTH
		control = dropdown
	elif param.param_type == "bool":
		control = CheckButton.new()
	else:
		control = RotaryKnob.new()
		control.custom_minimum_size = Vector2(KNOB_SIDE, KNOB_SIDE)
	control.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	slot.add_child(control)
	return slot
