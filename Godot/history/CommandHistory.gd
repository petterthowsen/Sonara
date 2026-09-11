# CommandHistory.gd
# Undo/redo stack for document mutations.
# execute() runs do() then pushes; record() pushes an already-applied gesture.
class_name CommandHistory extends RefCounted

## Emitted whenever undo/redo availability or stack contents change.
signal history_changed()

## Emitted after a successful undo (command name).
signal undone(command_name: String)

## Emitted after a successful redo (command name).
signal redone(command_name: String)

## Maximum number of undo entries retained.
var max_depth: int = 200

## Undo stack (most recent at the end).
var _undo_stack: Array[Command] = []

## Redo stack (most recent undone at the end).
var _redo_stack: Array[Command] = []

## Index into undo stack after last save (-1 = never saved / cleared).
## When undo_stack.size() == save_point_index, project is clean.
var save_point_index: int = 0

## Macro currently being assembled (null when not in a macro).
var _active_macro: MacroCommand = null

## Depth of nested begin_macro calls.
var _macro_depth: int = 0

## When true, execute/record do not push (used during undo/redo apply).
var _is_applying: bool = false


## Whether undo is available.
func can_undo() -> bool:
	return not _undo_stack.is_empty()


## Whether redo is available.
func can_redo() -> bool:
	return not _redo_stack.is_empty()


## Name of the next undo command, or empty string.
func undo_name() -> String:
	if _undo_stack.is_empty():
		return ""
	return _undo_stack.back().name


## Name of the next redo command, or empty string.
func redo_name() -> String:
	if _redo_stack.is_empty():
		return ""
	return _redo_stack.back().name


## Run command.do() then push onto the undo stack (clears redo).
func execute(cmd: Command) -> void:
	if cmd == null:
		return
	if _is_applying:
		cmd.do()
		return
	if _active_macro != null:
		cmd.do()
		_active_macro.add(cmd)
		return
	cmd.do()
	_push(cmd)


## Push an already-applied mutation (gesture commit) without calling do().
func record(cmd: Command) -> void:
	if cmd == null:
		return
	if _is_applying:
		return
	if _active_macro != null:
		_active_macro.add(cmd)
		return
	_push(cmd)


## Start collecting child commands into a single MacroCommand.
func begin_macro(macro_name: String = "Macro") -> void:
	if _macro_depth == 0:
		_active_macro = MacroCommand.new(macro_name)
	_macro_depth += 1


## Finish the active macro and push it as one history entry.
func end_macro() -> void:
	if _macro_depth <= 0:
		push_warning("[CommandHistory] end_macro called with no active macro")
		return
	_macro_depth -= 1
	if _macro_depth > 0:
		return
	var macro := _active_macro
	_active_macro = null
	if macro == null or macro.commands.is_empty():
		return
	_push(macro)


## Cancel the active macro without pushing (does not undo already-run children).
func cancel_macro() -> void:
	_macro_depth = 0
	_active_macro = null


## Undo the most recent command.
func undo() -> bool:
	if not can_undo() or _is_applying:
		return false
	_is_applying = true
	var cmd: Command = _undo_stack.pop_back()
	cmd.undo()
	_redo_stack.append(cmd)
	_is_applying = false
	history_changed.emit()
	undone.emit(cmd.name)
	return true


## Redo the most recently undone command.
func redo() -> bool:
	if not can_redo() or _is_applying:
		return false
	_is_applying = true
	var cmd: Command = _redo_stack.pop_back()
	cmd.do()
	_undo_stack.append(cmd)
	_is_applying = false
	history_changed.emit()
	redone.emit(cmd.name)
	return true


## Clear both stacks and reset the save point (e.g. on new/open project).
func clear() -> void:
	_undo_stack.clear()
	_redo_stack.clear()
	_active_macro = null
	_macro_depth = 0
	save_point_index = 0
	history_changed.emit()


## Mark the current undo depth as the last-saved state.
func mark_save_point() -> void:
	save_point_index = _undo_stack.size()
	history_changed.emit()


## True when undo depth matches the last save point (document is clean).
func is_at_save_point() -> bool:
	return _undo_stack.size() == save_point_index


## Number of undoable entries.
func undo_count() -> int:
	return _undo_stack.size()


## Number of redoable entries.
func redo_count() -> int:
	return _redo_stack.size()


## Push onto undo stack, optionally merging with the previous entry.
func _push(cmd: Command) -> void:
	_redo_stack.clear()
	# If we were past the save point and redo cleared, save point may be invalid
	# only when undoing below it; clearing redo after a new edit past save is fine.
	if not _undo_stack.is_empty():
		var top: Command = _undo_stack.back()
		if top.can_merge(cmd):
			top.merge_with(cmd)
			history_changed.emit()
			return
	_undo_stack.append(cmd)
	# Cap depth
	while _undo_stack.size() > max_depth:
		_undo_stack.pop_front()
		# Shifting the stack invalidates absolute save_point if > 0
		if save_point_index > 0:
			save_point_index -= 1
		elif save_point_index == 0:
			# Dropped the entry that was the save point; mark dirty forever until next save
			save_point_index = -1
	history_changed.emit()
