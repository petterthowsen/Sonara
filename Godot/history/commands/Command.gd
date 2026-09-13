# Command.gd
# Base class for undoable document mutations.
# Subclasses implement do()/undo(); setters on data objects stay free of history logic.
class_name Command extends RefCounted

## Human-readable label shown in Edit menu (e.g. "Move Clip").
var name: String = "Command"


## Apply the mutation (forward).
func do() -> void:
	pass


## Reverse the mutation.
func undo() -> void:
	pass


## Whether this command can absorb `other` into a single history entry.
func can_merge(_other: Command) -> bool:
	return false


## Merge `other` into this command (called only when can_merge is true).
func merge_with(_other: Command) -> void:
	pass
