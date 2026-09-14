# MarkerCreateCommand.gd
# Undoable creation of a song marker on the project marker lane.
class_name MarkerCreateCommand extends Command

var project: Project = null
var marker: SongMarker = null


## Record adding `marker` to `project`.
func _init(p_project: Project = null, p_marker: SongMarker = null) -> void:
	name = "Create Marker"
	project = p_project
	marker = p_marker


func do() -> void:
	if project == null or marker == null:
		return
	project.add_marker(marker)


func undo() -> void:
	if project == null or marker == null:
		return
	project.remove_marker(marker)
