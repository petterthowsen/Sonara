# SongMarker.gd
# A named time-range region on the arranger timeline (marker lane).
class_name SongMarker extends RefCounted

signal name_changed(new_name: String)
signal range_changed(start_ticks: int, duration_ticks: int)
signal color_changed(new_color: Color)
signal marker_modified()

var id: int = -1
var name: String = "Marker"
var start_ticks: int = 0
var duration_ticks: int = 0
var color: Color = Color.DODGER_BLUE


## Update the display name and notify listeners.
func set_name(new_name: String) -> void:
	var trimmed := new_name.strip_edges()
	if trimmed.is_empty():
		trimmed = "Marker"
	if name == trimmed:
		return
	name = trimmed
	name_changed.emit(name)
	marker_modified.emit()


## Move the marker start while keeping the end fixed (left-edge resize).
func set_start_ticks(ticks: int, min_duration_ticks: int) -> void:
	var end_ticks := start_ticks + duration_ticks
	var new_start := maxi(0, ticks)
	var new_duration := end_ticks - new_start
	new_duration = maxi(min_duration_ticks, new_duration)
	new_start = end_ticks - new_duration
	_apply_range(new_start, new_duration)


## Set both edges (right-edge resize or full range replace).
func set_range(start: int, duration: int, min_duration_ticks: int) -> void:
	var new_start := maxi(0, start)
	var new_duration := maxi(min_duration_ticks, duration)
	_apply_range(new_start, new_duration)


## Set marker color.
func set_color(new_color: Color) -> void:
	if color == new_color:
		return
	color = new_color
	color_changed.emit(color)
	marker_modified.emit()


func get_end_ticks() -> int:
	return start_ticks + duration_ticks


func to_json() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"start_ticks": start_ticks,
		"duration_ticks": duration_ticks,
		"color": color.to_html(false),
	}


static func from_json(data: Dictionary) -> SongMarker:
	var marker := SongMarker.new()
	marker.id = int(data.get("id", -1))
	marker.name = str(data.get("name", "Marker"))
	marker.start_ticks = int(data.get("start_ticks", 0))
	marker.duration_ticks = int(data.get("duration_ticks", 0))
	var color_str := str(data.get("color", ""))
	if not color_str.is_empty():
		marker.color = Color.from_string(color_str, marker.color)
	return marker


func _apply_range(new_start: int, new_duration: int) -> void:
	if start_ticks == new_start and duration_ticks == new_duration:
		return
	start_ticks = new_start
	duration_ticks = new_duration
	range_changed.emit(start_ticks, duration_ticks)
	marker_modified.emit()
