# ClipRenameCommand.gd
# Undoable manual clip rename. The typed name is custom, so automatic track-based renaming
# stops for this clip; undo brings back the previous name and its automatic state.
class_name ClipRenameCommand extends Command

var clip: Clip = null
var old_name: String = ""
var old_auto_track: String = ""
var new_name: String = ""


func _init(p_clip: Clip = null, p_new_name: String = "") -> void:
	name = "Rename Clip"
	clip = p_clip
	new_name = p_new_name
	if clip != null:
		old_name = clip.name
		old_auto_track = clip.auto_name_track


func do() -> void:
	if clip != null:
		clip.set_naming(new_name, "")


func undo() -> void:
	if clip != null:
		clip.set_naming(old_name, old_auto_track)
