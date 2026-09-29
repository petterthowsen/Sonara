# TempoMapStateCommand.gd
# Undoable edit of a TempoMap, stored as before/after snapshots of its points. Built after the edit
# has been applied, so it is recorded with HistoryUtil.record().
class_name TempoMapStateCommand extends Command

var tempo_map: TempoMap = null
var before: Array[Dictionary] = []
var after: Array[Dictionary] = []


func _init(p_name: String = "Edit Tempo", p_map: TempoMap = null,
		p_before: Array[Dictionary] = [], p_after: Array[Dictionary] = []) -> void:
	name = p_name
	tempo_map = p_map
	before = p_before
	after = p_after


func do() -> void:
	if tempo_map:
		tempo_map.restore(after)


func undo() -> void:
	if tempo_map:
		tempo_map.restore(before)
