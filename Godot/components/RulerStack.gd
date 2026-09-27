# RulerStack.gd
# The arranger's ruler rows as one component: a real-time (clock) ruler above a
# bar/beat ruler, sharing a GridHelper, offset, start arrow, selection band and
# context regions. Both rows carry BaseRuler's interaction (click-drag scrubs the
# start position, Ctrl/Cmd click or drag sets a time range), and their signals are
# forwarded from whichever row was used.
@tool
class_name RulerStack extends VBoxContainer

signal start_position_requested(ticks: int)
signal selection_start_requested(ticks: int)
signal box_select_started(content_x: float)

@export var show_time_ruler := true:
	set(v):
		show_time_ruler = v
		if time_ruler:
			time_ruler.visible = v

@export var show_beats_ruler := true:
	set(v):
		show_beats_ruler = v
		if beats_ruler:
			beats_ruler.visible = v

@export var time_ruler_height := 22.0
@export var beats_ruler_height := 26.0

## Horizontal draw offset applied to every row (see BaseRuler.offset_x).
var offset_x: float = 0.0:
	set(v):
		offset_x = v
		for r in rulers():
			r.offset_x = v

var time_ruler: RealTimeRuler
var beats_ruler: Ruler


func _init() -> void:
	add_theme_constant_override("separation", 0)

	# Colours match the arranger's rows (Arranger.tscn).
	time_ruler = RealTimeRuler.new()
	time_ruler.name = "TimeRuler"
	time_ruler.custom_minimum_size.y = time_ruler_height
	time_ruler.bg_color = Color(0.149, 0.149, 0.149)
	time_ruler.text_color = Color(0.675, 0.675, 0.675)
	time_ruler.vertical_alignment = BaseRuler.VerticalAlignment.TOP
	time_ruler.font_size = 11
	time_ruler.show_start_position = false
	add_child(time_ruler, false, INTERNAL_MODE_FRONT)

	beats_ruler = Ruler.new()
	beats_ruler.name = "BeatsRuler"
	beats_ruler.custom_minimum_size.y = beats_ruler_height
	beats_ruler.bg_color = Color(0.107, 0.107, 0.107)
	beats_ruler.text_color = Color(0.7, 0.7, 0.7)
	beats_ruler.start_position_color = Color(0.328, 0.382, 1.0)
	add_child(beats_ruler, false, INTERNAL_MODE_FRONT)

	for r in rulers():
		r.enable_time_range_gestures = true
		r.clip_contents = true
		r.start_position_requested.connect(start_position_requested.emit)
		r.selection_start_requested.connect(selection_start_requested.emit)
		r.box_select_started.connect(box_select_started.emit)


func _ready() -> void:
	time_ruler.custom_minimum_size.y = time_ruler_height
	beats_ruler.custom_minimum_size.y = beats_ruler_height
	time_ruler.visible = show_time_ruler
	beats_ruler.visible = show_beats_ruler


func rulers() -> Array[BaseRuler]:
	var out: Array[BaseRuler] = []
	if time_ruler:
		out.append(time_ruler)
	if beats_ruler:
		out.append(beats_ruler)
	return out


func set_grid_helper(gh: GridHelper) -> void:
	for r in rulers():
		r.set_grid_helper(gh)


func set_start_position(ticks: int) -> void:
	for r in rulers():
		r.set_start_position(ticks)


## Hide the start arrow when there is nothing meaningful to point at.
func set_start_position_visible(on: bool) -> void:
	# The clock row never shows the arrow; the beat row carries it, as in the arranger.
	beats_ruler.show_start_position = on


func set_selection_range(start: int, end: int) -> void:
	for r in rulers():
		r.set_selection_range(start, end)


func set_regions(regions: Array) -> void:
	for r in rulers():
		r.set_regions(regions)
