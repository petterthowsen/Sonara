## StepSequencerStrategy.gd
## Step sequencer rules: every parameter that belongs to a numbered step ("Step 3" module, or
## "Step 3 Pitch" / "Pitch 3" in a "Steps" module) goes into that step's group, its controls
## stacked in one column in parameter order, and the steps run left to right one after another.
## Everything else (Length, Rate, Swing, …) is grouped the usual way and sits before the steps.

class_name StepSequencerStrategy extends GenericStrategy

const STEP_ROLE := "step"
## Steps sort after every other group, so the extra controls come first (left of the steps).
const STEP_WEIGHT := 0.05

## "Step 3", "Step03", "step 12 pitch": group 1 is the step number.
static var _step_number := RegEx.create_from_string("(?i)\\bstep\\s*0*(\\d+)\\b")
## "Step 3" / "Step 3 Pitch" with the step words removed: group 1 before, group 2 after.
static var _step_words := RegEx.create_from_string("(?i)^(.*?)\\s*\\bstep\\s*\\d+\\b\\s*(.*)$")
## A module holding all steps ("Steps", "Step"), whose names end in the step number.
static var _steps_module := RegEx.create_from_string("(?i)^steps?$")
static var _trailing_number := RegEx.create_from_string("^(.*\\S)\\s+0*(\\d+)$")


## `{step, label}` for a parameter of a numbered step (1-based `step`, `label` is the name without
## the step words), or {} when it isn't one.
static func step_of(param_name: String, module: String) -> Dictionary:
	var segment := module.get_slice("/", 0).strip_edges()
	var found := _step_number.search(segment)
	if found != null:
		return {"step": int(found.get_string(1)), "label": _without_step_words(param_name)}
	found = _step_number.search(param_name)
	if found != null:
		return {"step": int(found.get_string(1)), "label": _without_step_words(param_name)}
	if _steps_module.search(segment) != null:
		var trailing := _trailing_number.search(param_name.strip_edges())
		if trailing != null:
			return {"step": int(trailing.get_string(2)), "label": trailing.get_string(1)}
	return {}


static func _without_step_words(param_name: String) -> String:
	var found := _step_words.search(param_name)
	if found == null:
		return param_name
	return (found.get_string(1) + " " + found.get_string(2)).strip_edges()


func role_weights() -> Dictionary:
	var weights := super.role_weights()
	weights[STEP_ROLE] = STEP_WEIGHT
	return weights


func role_for(param: DeviceParameter) -> String:
	if not step_of(param.name, param.module).is_empty():
		return STEP_ROLE
	return super.role_for(param)


## A step's controls keep the device's own order (On, Pitch, Velocity, Chance).
func priority_tier(item: Dictionary) -> int:
	if item.get("role", "") == STEP_ROLE:
		return 1
	return super.priority_tier(item)


## Each numbered step gets a group of its own, ahead of module paths and name sections, laid out
## as one column; all steps form the "Steps" family so they stay side by side.
func claimed_group(item: Dictionary) -> Dictionary:
	if item.get("role", "") != STEP_ROLE:
		return {}
	var step := step_of(String(item.get("name", "")), String(item.get("module", "")))
	if step.is_empty():
		return {}
	var def := {"id": "step_%d" % step.step, "title": "Step %d" % step.step, "family": "steps",
		"family_title": "Steps", "column": true}
	if not String(step.label).is_empty():
		def.label = step.label
	return def
