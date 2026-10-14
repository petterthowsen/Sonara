# ParameterChangeCommand.gd
# User edits of a device's parameters (normalized values), undone and redone through
# DeviceInstance.set_parameter_normalized so the model syncs the engine (ADR-0006).
# Edits of one device made during one drag gesture (same non-zero `gesture`) merge into a single
# step, including gestures that move several parameters at once (EQ node: freq + gain).
# Plugin parameters (CLAP/VST3, #124) use the same command.
class_name ParameterChangeCommand extends Command

## The DeviceInstance (untyped so this script compiles without the autoloads it references).
var instance: Object = null

## param_id -> [value before the gesture, latest value], in the order first touched.
var changes: Dictionary = {}

## Gesture token from ParameterActions.current_gesture(); 0 = a discrete edit that never merges.
var gesture: int = 0


func _init(p_label: String, p_instance: Object, p_param_id: int, p_old: float, p_new: float, p_gesture: int = 0) -> void:
	name = p_label
	instance = p_instance
	changes[p_param_id] = [p_old, p_new]
	gesture = p_gesture


func do() -> void:
	for id in changes:
		_apply(id, changes[id][1])


func undo() -> void:
	var ids := changes.keys()
	ids.reverse()
	for id in ids:
		_apply(id, changes[id][0])


func can_merge(other: Command) -> bool:
	if gesture == 0 or not other is ParameterChangeCommand:
		return false
	var o := other as ParameterChangeCommand
	return o.gesture == gesture and o.instance == instance


## Keep the original old values and take the other's latest values.
func merge_with(other: Command) -> void:
	var o := other as ParameterChangeCommand
	for id in o.changes:
		if changes.has(id):
			changes[id][1] = o.changes[id][1]
		else:
			changes[id] = o.changes[id].duplicate()


func _apply(param_id: int, value: float) -> void:
	if instance == null or not is_instance_valid(instance):
		push_warning("[ParameterChangeCommand] Device instance is gone: %s" % name)
		return
	instance.set_parameter_normalized(param_id, value)
