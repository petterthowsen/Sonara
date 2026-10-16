# VisibilityPresetsStateCommand.gd
# Undoable edit of a VisibilityPresets (the list, its order, and the active index), stored as
# before/after snapshots. Pass it to HistoryUtil.record() once the edit has been applied, or to
# execute() with `after` prepared beforehand (do() restores it).
class_name VisibilityPresetsStateCommand extends Command

var presets: VisibilityPresets = null
var before: Dictionary = {}
var after: Dictionary = {}


func _init(p_name: String = "Edit Visibility Presets", p_presets: VisibilityPresets = null,
		p_before: Dictionary = {}, p_after: Dictionary = {}) -> void:
	name = p_name
	presets = p_presets
	before = p_before
	after = p_after


func do() -> void:
	if presets:
		presets.restore(after)


func undo() -> void:
	if presets:
		presets.restore(before)
