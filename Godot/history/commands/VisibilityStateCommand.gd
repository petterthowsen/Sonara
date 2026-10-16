# VisibilityStateCommand.gd
# Undoable change of the hidden flag on a set of visibility targets (a track's linked channel, or the
# track itself when it has none; see TrackVisibility.target_of). Applied inside
# Project.batch_visibility so the views re-filter once. Targets freed since (a deleted channel) are
# skipped. Pass it to HistoryUtil.execute() (not yet applied) or HistoryUtil.record() (already
# applied while painting).
class_name VisibilityStateCommand extends Command

var project: Project = null
## target Object -> bool hidden, before the change.
var old_values: Dictionary = {}
## target Object -> bool hidden, after the change.
var new_values: Dictionary = {}


func _init(p_name: String = "Change Track Visibility", p_project: Project = null,
		p_old_values: Dictionary = {}, p_new_values: Dictionary = {}) -> void:
	name = p_name
	project = p_project
	old_values = p_old_values
	new_values = p_new_values


func do() -> void:
	_apply(new_values)


func undo() -> void:
	_apply(old_values)


func _apply(values: Dictionary) -> void:
	var run := func() -> void:
		for target in values:
			if is_instance_valid(target):
				target.set_hidden(bool(values[target]))
	if project:
		project.batch_visibility(run)
	else:
		run.call()
