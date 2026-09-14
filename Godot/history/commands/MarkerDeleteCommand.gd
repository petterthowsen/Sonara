# MarkerDeleteCommand.gd
# Undoable removal of a song marker.
class_name MarkerDeleteCommand extends Command

var project: Project = null
var marker: SongMarker = null


func _init(p_project: Project = null, p_marker: SongMarker = null) -> void:
	name = "Delete Marker"
	project = p_project
	marker = p_marker


func do() -> void:
	if project == null or marker == null:
		return
	project.remove_marker(marker)


func undo() -> void:
	if project == null or marker == null:
		return
	project.add_marker(marker)
