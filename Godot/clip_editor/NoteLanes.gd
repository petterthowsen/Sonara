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

## Shared scale state (spec 026), handed down by MidiEditor. Null or inactive means the lanes
## look exactly as they did before scale support (REQ-006).
## Theme secondary accent, cached for the out-of-scale tint (see _refresh_theme_colors).
var _secondary_accent := Color("#36d99e")

var scale_context: ScaleContext = null:
	set(c):
		if scale_context == c:
			return
		if scale_context and scale_context.changed.is_connected(queue_redraw):
			scale_context.changed.disconnect(queue_redraw)
		scale_context = c
		if scale_context:
			scale_context.changed.connect(queue_redraw)
		queue_redraw()

## How strongly out-of-scale lanes are tinted with the theme's secondary accent.
@export_range(0.0, 1.0) var out_of_scale_tint_strength := 0.12:
	set(t):
		out_of_scale_tint_strength = t
		queue_redraw()

## Blended over every lane holding the scale root's pitch class; alpha is the blend strength.
@export var root_accent_color := Color(0.3, 0.55, 1.0, 0.18):
	set(c):
		root_accent_color = c
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
	_refresh_theme_colors()
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
	var drum := layout.is_drum()
	var rows := layout.row_count()
	var highlight := scale_context != null and scale_context.highlight_active()

	for row in rows:
		var note := layout.pitch_at_row(row)
		var y := layout.row_to_y(row)
		var bottom := y + h
		var c: Color
		if drum:
			# Drum View has no white/black pattern; alternate rows instead so
			# neighbouring rows stay distinguishable.
			c = note_lane_color_black if row % 2 == 1 else note_lane_color_white
		elif highlight:
			c = lane_color(note, note_lane_color_white, note_lane_color_black,
					scale_context.pitch_classes(), scale_context.scale.root,
					_out_of_scale_tint(), root_accent_color)
		else:
			c = note_lane_color_black if Midi.is_black_key(note) else note_lane_color_white
		c = _tinted(c, note)
		draw_rect(Rect2(0, y, w, h), c, true, -1.0, false)

		if row < rows - 1:
			draw_line(Vector2(0, bottom), Vector2(w, bottom), border_color, 0.5, true)

	if folded:
		# Folded rows (Drum View or folded to the scale) are mostly neighbours of one colour,
		# so every row gets a full separator instead of the E/F and B/C semitone borders.
		for row in rows - 1:
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


## Lane colour for `pitch` (REQ-005/006). Plain white/black key colour when `scale_pcs` is empty
## (no scale). Otherwise out-of-scale pitch classes are blended towards `out_tint`, and the root's
## pitch class (`root` 0..11, -1 for none) towards `accent`; each colour's alpha is its strength.
static func lane_color(pitch: int, base_white: Color, base_black: Color,
		scale_pcs: PackedInt32Array, root: int, out_tint: Color, accent: Color) -> Color:
	var base := base_black if Midi.is_black_key(pitch) else base_white
	if scale_pcs.is_empty():
		return base
	var pc := posmod(pitch, 12)
	if not scale_pcs.has(pc):
		return base.lerp(Color(out_tint.r, out_tint.g, out_tint.b, base.a), out_tint.a)
	if pc == root:
		return base.lerp(Color(accent.r, accent.g, accent.b, base.a), accent.a)
	return base


## The secondary accent with `out_of_scale_tint_strength` as alpha, for lane_color.
func _out_of_scale_tint() -> Color:
	return Color(_secondary_accent, out_of_scale_tint_strength)


## Cached theme role (UiColors.role must not run in the draw loop); refreshed on theme change.
func _refresh_theme_colors() -> void:
	var theme := ThemeDB.get_project_theme()
	if theme != null and theme.has_color(&"accent_secondary", &"Sonara"):
		_secondary_accent = UiColors.role(&"accent_secondary")
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_refresh_theme_colors()
