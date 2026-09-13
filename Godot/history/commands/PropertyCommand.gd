# PropertyCommand.gd
# Generic command that calls a named setter (or Callable) with old/new values.
# Used for volume, mute, tempo, device params, and other scalar properties.
class_name PropertyCommand extends Command

## Target object that owns the property setter.
var target: Object = null

## Setter method name on target (e.g. "set_volume"), ignored if callable is set.
var setter_name: String = ""

## Optional Callable used instead of call(setter_name, ...).
var setter_callable: Callable = Callable()

## Value before the change (restored on undo).
var old_value = null

## Value after the change (applied on do / redo).
var new_value = null

## When true, call setter with two args unpacked from Array values (e.g. pan).
var unpack_array: bool = false

## When true, consecutive edits of the same target/setter merge into one undo step.
## Enable for continuous gestures (fader/param drag); leave false for toggles.
var mergeable: bool = false


## Create a property command. Pass either setter_name or a Callable via set_callable().
func _init(
	p_name: String = "Set Property",
	p_target: Object = null,
	p_setter_name: String = "",
	p_old_value = null,
	p_new_value = null
) -> void:
	name = p_name
	target = p_target
	setter_name = p_setter_name
	old_value = p_old_value
	new_value = p_new_value


## Use a Callable instead of a method name for applying values.
func set_callable(callable: Callable) -> PropertyCommand:
	setter_callable = callable
	return self


## Treat Array values as multi-arg setter calls (e.g. set_pan(l, r)).
func set_unpack_array(enabled: bool = true) -> PropertyCommand:
	unpack_array = enabled
	return self


## Allow consecutive matching property edits to merge (for drag gestures).
func set_mergeable(enabled: bool = true) -> PropertyCommand:
	mergeable = enabled
	return self


## Apply new_value via the configured setter.
func do() -> void:
	_apply(new_value)


## Restore old_value via the configured setter.
func undo() -> void:
	_apply(old_value)


## Merge consecutive property edits on the same target/setter into one step.
func can_merge(other: Command) -> bool:
	if not mergeable:
		return false
	if not other is PropertyCommand:
		return false
	var o := other as PropertyCommand
	if not o.mergeable:
		return false
	if target != o.target:
		return false
	if setter_callable.is_valid() or o.setter_callable.is_valid():
		return setter_callable == o.setter_callable
	return setter_name == o.setter_name and not setter_name.is_empty()


## Keep the original old_value and take the other's new_value.
func merge_with(other: Command) -> void:
	var o := other as PropertyCommand
	new_value = o.new_value


## Invoke the setter with the given value.
func _apply(value) -> void:
	# Callable-based commands may have a null target (lambda captures state).
	if setter_callable.is_valid():
		if unpack_array and value is Array:
			setter_callable.callv(value)
		else:
			setter_callable.call(value)
		return
	if target == null or not is_instance_valid(target):
		push_warning("[PropertyCommand] Target is null or freed: %s" % name)
		return
	if setter_name.is_empty():
		push_warning("[PropertyCommand] No setter configured: %s" % name)
		return
	if unpack_array and value is Array:
		target.callv(setter_name, value)
	else:
		target.call(setter_name, value)
