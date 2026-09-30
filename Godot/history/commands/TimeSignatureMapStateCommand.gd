# TimeSignatureMapStateCommand.gd
# Undoable edit of a TimeSignatureMap, stored as before/after snapshots of its changes. Built after
# the edit has been applied, so it is recorded with HistoryUtil.record().
class_name TimeSignatureMapStateCommand extends Command

var signature_map: TimeSignatureMap = null
var before: Array[Dictionary] = []
var after: Array[Dictionary] = []


func _init(p_name: String = "Edit Time Signature", p_map: TimeSignatureMap = null,
		p_before: Array[Dictionary] = [], p_after: Array[Dictionary] = []) -> void:
	name = p_name
	signature_map = p_map
	before = p_before
	after = p_after


func do() -> void:
	if signature_map:
		signature_map.restore(after)


func undo() -> void:
	if signature_map:
		signature_map.restore(before)
