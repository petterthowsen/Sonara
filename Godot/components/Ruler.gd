# Draws a ruler with vertical lines at grid positions (beats, bars, ticks)
# Shows bar numbers and beat markers
@tool
class_name Ruler extends BaseRuler

## Ctrl/Cmd click without drag: set the arranger time-range start.
signal selection_start_requested(ticks: int)
## Ctrl/Cmd drag: begin a full-height box select at timeline content X.
signal box_select_started(content_x: float)

const ADDITIVE_DRAG_THRESHOLD := 6.0
## When true, Ctrl/Cmd click-drag on this ruler drives arranger time-range selection.
@export var enable_time_range_gestures: bool = false
var _additive_pending: bool = false
var _additive_press_pos: Vector2 = Vector2.ZERO
var _scrubbing: bool = false
var _last_scrub_ticks: int = -1


## Bar lines with numbers, then half-height beat and quarter-height subdivision ticks.
func _draw_ruler() -> void:
	var bar_line_color = get_theme_color("bar_line_color", "Ruler")
	var beat_line_color = get_theme_color("beat_line_color", "Ruler")
	var subdivision_line_color = get_theme_color("subdivision_line_color", "Ruler")

	# GridHelper accounts for scroll, so line.x is already in ruler space
	var grid_lines = grid_helper.get_visible_grid_lines(0.0, size.x - offset_x, offset_x)
	for line in grid_lines:
		var x = line.x
		if x < offset_x or x > size.x:
			continue
		match line.type:
			GridHelper.GridLineType.BAR:
				draw_line(Vector2(x, 0), Vector2(x, size.y), bar_line_color, 2.0, true)
				draw_string(ThemeDB.fallback_font, Vector2(x + 4, size.y - 4), str(line.bar_number), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)
			GridHelper.GridLineType.BEAT:
				_draw_tick_line(x, 0.5, beat_line_color)
			GridHelper.GridLineType.SUBDIVISION:
				_draw_tick_line(x, 0.25, subdivision_line_color)


## Handle ruler clicks to set start position, or Ctrl/Cmd for time-range gestures.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not grid_helper:
			return

		if enable_time_range_gestures and (event.ctrl_pressed or event.meta_pressed):
			_additive_pending = true
			_additive_press_pos = event.position
			get_tree().root.set_input_as_handled()
			return

		_begin_scrub(event.position.x)
		get_tree().root.set_input_as_handled()


## Finish a pending Ctrl/Cmd click, hand a drag to box-select, or scrub playhead/start.
func _input(event: InputEvent) -> void:
	if _additive_pending:
		_handle_additive_input(event)
		return

	if _scrubbing:
		_handle_scrub_input(event)


## Resolve a pending Ctrl/Cmd click or start a full-height box select after a drag.
func _handle_additive_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		selection_start_requested.emit(_snapped_ticks_from_local(_additive_press_pos.x))
		_additive_pending = false
		get_tree().root.set_input_as_handled()
		return

	if not is_visible_in_tree():
		_additive_pending = false
		return

	if event is InputEventMouseMotion:
		var local_pos := get_local_mouse_position()
		if local_pos.distance_to(_additive_press_pos) > ADDITIVE_DRAG_THRESHOLD:
			box_select_started.emit(_content_x_from_local(_additive_press_pos.x))
			_additive_pending = false
			get_tree().root.set_input_as_handled()


## Update start/playhead while the mouse is held, then end the scrub on release.
func _handle_scrub_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_scrubbing = false
		_last_scrub_ticks = -1
		get_tree().root.set_input_as_handled()
		return

	if not is_visible_in_tree():
		_scrubbing = false
		_last_scrub_ticks = -1
		return

	if event is InputEventMouseMotion:
		_emit_scrub_ticks(get_local_mouse_position().x)
		get_tree().root.set_input_as_handled()


## Start a click-drag that moves start position and playhead together.
func _begin_scrub(local_x: float) -> void:
	_scrubbing = true
	_last_scrub_ticks = -1
	_emit_scrub_ticks(local_x)


## Emit start_position_requested only when snapped ticks change.
func _emit_scrub_ticks(local_x: float) -> void:
	var ticks := _snapped_ticks_from_local(local_x)
	if ticks == _last_scrub_ticks:
		return
	_last_scrub_ticks = ticks
	start_position_requested.emit(ticks)


## Snap a ruler-local X to the nearest grid tick, never before 0.
func _snapped_ticks_from_local(local_x: float) -> int:
	if not grid_helper:
		return 0
	return maxi(grid_helper.snap_ticks(grid_helper.pixels_to_ticks(_content_x_from_local(local_x))), 0)
