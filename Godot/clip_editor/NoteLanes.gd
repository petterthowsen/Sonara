# Renders horizontal note lines for note/key lanes,
@tool
class_name NoteLanes extends Control

var grid_helper : GridHelper = GridHelper.new()

## Shared pitch <-> row <-> Y math, handed down by MidiEditor. Defaults to its own
## chromatic layout so the @tool preview still renders in the Godot editor.
var layout: LaneLayout = LaneLayout.chromatic():
	set(l):
		if layout == l:
			return
		if layout and layout.changed.is_connected(_on_layout_changed):
			layout.changed.disconnect(_on_layout_changed)
		layout = l if l else LaneLayout.chromatic()
		layout.changed.connect(_on_layout_changed)
		_on_layout_changed()

## Effective note map, for lane tinting (REQ-014). Null means no tinting.
var note_map: NoteMap = null:
	set(m):
		note_map = m
		queue_redraw()

## How strongly a mapped lane is tinted with its entry colour.
@export_range(0.0, 1.0) var map_tint_strength := 0.45:
	set(t):
		map_tint_strength = t
		queue_redraw()

## Row height. Kept as an export so the scene and the @tool preview still set it;
## it simply forwards to the shared layout.
@export var key_height := 20.0:
	get:
		return layout.row_height if layout else 20.0
	set(kh):
		if layout and not is_equal_approx(layout.row_height, kh):
			layout.row_height = kh

@export var note_lane_color_white := Color("666"):
	set(c):
		note_lane_color_white = c
		queue_redraw()

@export var note_lane_color_black := Color("444"):
	set(c):
		note_lane_color_black = c
		queue_redraw()

@export var border_color := Color("#252525"):
	set(c):
		border_color = c
		queue_redraw()

## Line between natural semitone neighbours (E/F and B/C).
@export var semitone_border_color := Color("#3a3a3a"):
	set(c):
		semitone_border_color = c
		queue_redraw()

func _ready() -> void:
	if layout and not layout.changed.is_connected(_on_layout_changed):
		layout.changed.connect(_on_layout_changed)


func _on_layout_changed() -> void:
	update_minimum_size()
	queue_redraw()


func _get_minimum_size() -> Vector2:
	return Vector2(100, layout.total_height())

# returns the top Y value of the given note lane
func note_to_y(note : int) -> float:
	return layout.pitch_to_y(note)

# returns the bottom Y value of the given note lane
func note_to_y_bottom(note : int) -> float:
	return layout.pitch_to_y_bottom(note)

# returns the center Y value of the given note lane
func note_to_y_center(note : int) -> float:
	return layout.pitch_to_y_center(note)

func _draw() -> void:
	_draw_lanes()

func _draw_lanes():
	var w = size.x
	var h := layout.row_height
	var folded := layout.is_folded()
	var rows := layout.row_count()

	for row in rows:
		var note := layout.pitch_at_row(row)
		var y := layout.row_to_y(row)
		var bottom := y + h
		var c: Color
		if folded:
			# Drum View has no white/black pattern; alternate rows instead so
			# neighbouring rows stay distinguishable.
			c = note_lane_color_black if row % 2 == 1 else note_lane_color_white
		else:
			c = note_lane_color_black if Midi.is_black_key(note) else note_lane_color_white
		c = _tinted(c, note)
		draw_rect(Rect2(0, y, w, h), c, true, -1.0, false)

		if row < rows - 1:
			draw_line(Vector2(0, bottom), Vector2(w, bottom), border_color, 0.5, true)

	if folded:
		# One separator per row instead of the E/F and B/C semitone borders.
		for row in rows:
			if row < rows - 1:
				var bottom := layout.row_to_y(row) + h
				draw_line(Vector2(0, bottom), Vector2(w, bottom), semitone_border_color, 1.0, false)
		return

	# E/F and B/C boundaries: the bottom edge of every F and C lane.
	for note in 128:
		var n = Midi.get_note_in_octave(note)
		if note > 0 and (n == 0 or n == 5):
			var bottom = note_to_y_bottom(note)
			draw_line(Vector2(0, bottom), Vector2(w, bottom), semitone_border_color, 1.0, false)


## Blend a lane's base colour towards its note map entry colour (REQ-014).
func _tinted(base: Color, note: int) -> Color:
	if note_map == null or map_tint_strength <= 0.0:
		return base
	var entry := note_map.get_color(note)
	if entry.a <= 0.0:
		return base
	return base.lerp(Color(entry.r, entry.g, entry.b, base.a), map_tint_strength)
