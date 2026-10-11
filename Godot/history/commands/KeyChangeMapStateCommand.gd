# KeyChangeMapStateCommand.gd
# Undoable edit of a KeyChangeMap, stored as before/after snapshots of its changes. Built after
# the edit has been applied, so it is recorded with HistoryUtil.record().
class_name KeyChangeMapStateCommand extends Command

var key_change_map: KeyChangeMap = null
var before: Array[Dictionary] = []
var after: Array[Dictionary] = []


func _init(p_name: String = "Edit Key Change", p_map: KeyChangeMap = null,
		p_before: Array[Dictionary] = [], p_after: Array[Dictionary] = []) -> void:
	name = p_name
	key_change_map = p_map
	before = p_before
	after = p_after


func do() -> void:
	if key_change_map:
		key_change_map.restore(after)


func undo() -> void:
	if key_change_map:
		key_change_map.restore(before)
