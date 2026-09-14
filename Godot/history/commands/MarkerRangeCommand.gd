# MarkerRangeCommand.gd
# Undoable move/resize of a song marker (start + duration).
class_name MarkerRangeCommand extends Command

var marker: SongMarker = null
var min_duration_ticks: int = 1
var old_start: int = 0
var old_duration: int = 0
var new_start: int = 0
var new_duration: int = 0


func _init(
	p_name: String = "Resize Marker",
	p_marker: SongMarker = null,
	p_min_duration: int = 1,
	p_old_start: int = 0,
	p_old_duration: int = 0,
	p_new_start: int = 0,
	p_new_duration: int = 0
) -> void:
	name = p_name
	marker = p_marker
	min_duration_ticks = p_min_duration
	old_start = p_old_start
	old_duration = p_old_duration
	new_start = p_new_start
	new_duration = p_new_duration


func do() -> void:
	_apply(new_start, new_duration)


func undo() -> void:
	_apply(old_start, old_duration)


func _apply(start: int, duration: int) -> void:
	if marker == null:
		return
	marker.set_range(start, duration, min_duration_ticks)
