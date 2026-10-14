## A modulator kind's options, shown in the Modulators pane's detail column. Each kind with
## settings has its own scene in this folder, laid out in the editor from `ModParamSlot`s;
## `setup` binds every slot to the modulator and `sync` pushes the model's values back into them.
## Kinds with extra controls (envelope, XY pad, sidechain source) extend this script.
##
## Layout contract: the pane gives an options scene the device panel's fixed height and as much
## width as it asks for. Lay controls out sideways rather than stacking them, never scroll, and
## keep the scene's minimum height well under `DevicePanel.HEIGHT` (see `MAX_HEIGHT`). The root
## centers its content in both directions.
class_name ModulatorOptions extends CenterContainer

## Tallest an options scene may be: what's left of `DevicePanel.HEIGHT` below the panel header,
## the pane margins and the detail title. Checked by test_modulators_ui.gd for every scene.
const MAX_HEIGHT := 240.0

var modulator: Modulator = null
## Slot controls by parameter id (knobs and dropdowns).
var controls: Dictionary = {}


func setup(mod: Modulator) -> void:
	modulator = mod
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
