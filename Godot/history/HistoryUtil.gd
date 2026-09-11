# HistoryUtil.gd
# Small helpers for recording document commands through Sonara.editor.history.
class_name HistoryUtil extends RefCounted


## Return the editor command history, or null if unavailable.
static func history() -> CommandHistory:
	if Sonara and Sonara.editor and Sonara.editor.history:
		return Sonara.editor.history
	return null


## Execute a command (do + push) via the editor, marking the project dirty.
static func execute(cmd: Command) -> void:
	if Sonara and Sonara.editor:
		Sonara.editor.execute_command(cmd)
	else:
		cmd.do()


## Record an already-applied gesture via the editor, marking the project dirty.
static func record(cmd: Command) -> void:
	if Sonara and Sonara.editor:
		Sonara.editor.record_command(cmd)


## Record a mergeable property change that was already applied via the setter.
static func record_property(
	label: String,
	target: Object,
	setter_name: String,
	old_value,
	new_value,
	mergeable: bool = true
) -> void:
	if old_value == new_value:
		return
	var cmd := PropertyCommand.new(label, target, setter_name, old_value, new_value)
	cmd.set_mergeable(mergeable)
	record(cmd)


## Execute a non-mergeable property change (calls setter via command.do).
static func execute_property(
	label: String,
	target: Object,
	setter_name: String,
	old_value,
	new_value
) -> void:
	if old_value == new_value:
		return
	var cmd := PropertyCommand.new(label, target, setter_name, old_value, new_value)
	execute(cmd)
