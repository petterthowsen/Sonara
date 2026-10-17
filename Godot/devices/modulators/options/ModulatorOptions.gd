## A modulator kind's options, shown in the Modulators pane's detail column. Each kind with
## settings has its own scene in this folder, laid out in the editor from `ModParamSlot`s;
## `setup` binds every slot to the modulator and `sync` pushes the model's values back into them.
## Kinds with extra controls (envelope, XY pad, sidechain source) extend this script.
##
## Layout contract: the pane gives an options scene the device panel's fixed height and as much
## width as it asks for. Lay controls out sideways rather than stacking them, never scroll, and
## keep the scene's minimum height well under `DevicePanel.HEIGHT` (see `MAX_HEIGHT`). The root is
## a VBox with centered alignment, so content is vertically centered unless a child expands to
## fill the height; give the content `SHRINK_CENTER` horizontally to center it sideways.
class_name ModulatorOptions extends VBoxContainer

## Tallest an options scene may be: what's left of `DevicePanel.HEIGHT` below the panel header,
## the pane margins and the detail title. Checked by test_modulators_ui.gd for every scene.
const MAX_HEIGHT := 240.0

## Every kind but the sidechain (which has its own Amount slot) carries this parameter.
const AMOUNT_PARAM_ID := 90
const AMOUNT_KNOB_SIDE := 44

var modulator: Modulator = null
## Slot controls by parameter id (knobs and dropdowns).
var controls: Dictionary = {}


func setup(mod: Modulator) -> void:
	modulator = mod
	_ensure_amount_slot(mod)
	_bind_slots(mod)
	sync()


## Push the model's values into the controls. Never rebuilds: every edit echoes back as
## `modulator_changed`, and rebuilding would free the control being dragged.
func sync() -> void:
	for slot in slots():
		slot.refresh()


## Every `ModParamSlot` in the scene, in tree order.
func slots() -> Array[ModParamSlot]:
	var found: Array[ModParamSlot] = []
	_collect_slots(self, found)
	return found


## Adds the Amount knob to a scene that doesn't lay it out itself, so every modulator offers it
## without editing each kind's scene. It joins the scene's first row when there is one.
func _ensure_amount_slot(mod: Modulator) -> void:
	if mod.get_parameter(AMOUNT_PARAM_ID) == null:
		return
	for slot in slots():
		if slot.param_id == AMOUNT_PARAM_ID:
			return
	var slot := ModParamSlot.new()
	slot.vertical = true
	slot.param_id = AMOUNT_PARAM_ID
	slot.alignment = BoxContainer.ALIGNMENT_CENTER
	slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var caption := Label.new()
	caption.theme_type_variation = &"Caption"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slot.add_child(caption)
	var knob := RotaryKnob.new()
	knob.custom_minimum_size = Vector2(AMOUNT_KNOB_SIDE, AMOUNT_KNOB_SIDE)
	knob.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	slot.add_child(knob)
	var row: Node = self
	for child in get_children():
		if child is HBoxContainer:
			row = child
			break
	row.add_child(slot)


func _bind_slots(mod: Modulator) -> void:
	for slot in slots():
		slot.bind(mod)
		if slot.visible and slot.control != null:
			controls[slot.param_id] = slot.control


func _collect_slots(node: Node, found: Array[ModParamSlot]) -> void:
	for child in node.get_children():
		if child is ModParamSlot:
			found.append(child)
		_collect_slots(child, found)
