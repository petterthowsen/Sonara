# ChannelsPropertyCommand.gd
# One property change applied to several channels at once (mixer multi-edit), as one undo step.
# Values are kept per channel, so channels with different starting values undo to their own.
class_name ChannelsPropertyCommand extends Command

## Channel -> value before the change.
var old_values: Dictionary = {}

## Channel -> value after the change.
var new_values: Dictionary = {}

## Called as `apply.call(channel, value)`.
var apply: Callable = Callable()

## Consecutive edits with the same non-empty key over the same channels merge (drag gestures).
var merge_key: String = ""


func _init(p_name: String, p_old_values: Dictionary, p_new_values: Dictionary, p_apply: Callable, p_merge_key: String = "") -> void:
	name = p_name
	old_values = p_old_values
	new_values = p_new_values
	apply = p_apply
	merge_key = p_merge_key


func do() -> void:
	_apply_all(new_values)


func undo() -> void:
	_apply_all(old_values)


func can_merge(other: Command) -> bool:
	if merge_key.is_empty() or not other is ChannelsPropertyCommand:
		return false
	var o := other as ChannelsPropertyCommand
	if o.merge_key != merge_key or o.new_values.size() != new_values.size():
		return false
	for ch in new_values:
		if not o.new_values.has(ch):
			return false
	return true


## Keep the original old values and take the other's new values.
func merge_with(other: Command) -> void:
	new_values = (other as ChannelsPropertyCommand).new_values


func _apply_all(values: Dictionary) -> void:
	for ch in values:
		if is_instance_valid(ch):
			apply.call(ch, values[ch])
