# Renders start/end marker of current NoteSelections
# and marquee box when box-selecting
class_name MidiEditorOverlays extends Control

# Box selection (set by MidiEditor when actively selecting)
var is_box_selecting: bool = false
var box_selection_rect: Rect2 = Rect2()

# Selection range markers (set by MidiEditor when notes are selected)
var show_selection_markers: bool = false
var selection_start_x: float = 0.0
var selection_end_x: float = 0.0

# Alt+right-click scrub line (x in this control's space, < 0 when off) and the notes it has
# sounded, which flash in the theme accent and fade out.
const GLOW_SECONDS := 1.0
var _scrub_x := -1.0
var _accent := Color(0.3, 0.55, 1.0)
var _glows: Array = []  # [{note: VisualNote, age: float}]


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	# Markers are positioned in this control's space, which follows horizontal scroll but
	# not the ScrollContainer's clipping. Without this, a selection start scrolled left of
	# the note area paints over the piano keys / outside the editor.
	clip_contents = true
	set_process(false)
	_refresh_theme_colors()


func set_scrub_x(x: float) -> void:
	_scrub_x = x
	set_process(_scrub_x >= 0.0 or not _glows.is_empty())
	queue_redraw()


## Flash `note` (a VisualNote) in the accent colour; re-sounding it restarts the fade.
func add_glow(note: Control) -> void:
	for g in _glows:
		if g.note == note:
			g.age = 0.0
			return
	_glows.append({"note": note, "age": 0.0})
	set_process(true)


func _process(delta: float) -> void:
	for g in _glows:
		g.age += delta
	_glows = _glows.filter(func(g): return g.age < GLOW_SECONDS and is_instance_valid(g.note))
	if _scrub_x < 0.0 and _glows.is_empty():
		set_process(false)
	queue_redraw()


func _refresh_theme_colors() -> void:
	var theme := ThemeDB.get_project_theme()
	if theme != null and theme.has_color(&"accent_primary", &"Sonara"):
		_accent = UiColors.role(&"accent_primary")
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_refresh_theme_colors()


func _draw() -> void:
	"""Draw selection box and range markers."""
	# Draw box selection while actively selecting
	if is_box_selecting and box_selection_rect.size.length() > 0:
		draw_rect(box_selection_rect, Color(1.0, 1.0, 1.0, 0.1))
		draw_rect(box_selection_rect, Color(1.0, 1.0, 1.0, 0.5), false, 2.0)

	# Draw selection range markers (vertical lines)
	if show_selection_markers:
		var line_color = Color(0.4, 0.8, 1.0, 0.6)
		var line_width = 2.0
		var height = size.y

		# Inset each line by half its width so it sits inside the selected range.
		# Centred on the edge, a start marker at the clip start (x = 0) lost half
		# its width to clip_contents and the rest vanished against the grid line.
		var start_x = selection_start_x + line_width * 0.5
		var end_x = selection_end_x - line_width * 0.5

		# Draw start marker
		draw_line(Vector2(start_x, 0), Vector2(start_x, height), line_color, line_width)

		# Draw end marker
		draw_line(Vector2(end_x, 0), Vector2(end_x, height), line_color, line_width)

	# Notes the scrub line has sounded: a soft halo plus a bright fill that fade together.
	for g in _glows:
		var note: Control = g.note
		var rect := Rect2(make_canvas_position_local(note.get_global_rect().position), note.get_global_rect().size)
		var k: float = 1.0 - float(g.age) / GLOW_SECONDS
		k *= k
		draw_rect(rect.grow(4.0), Color(_accent, 0.2 * k))
		draw_rect(rect.grow(2.0), Color(_accent, 0.25 * k))
		draw_rect(rect, Color(_accent, 0.3 * k))

	# The scrub line itself.
	if _scrub_x >= 0.0:
		draw_line(Vector2(_scrub_x, 0), Vector2(_scrub_x, size.y), Color(_accent, 0.35), 5.0)
		draw_line(Vector2(_scrub_x, 0), Vector2(_scrub_x, size.y), _accent, 2.0)
