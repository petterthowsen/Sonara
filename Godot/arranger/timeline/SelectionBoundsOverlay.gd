## Draws arranger time-range start/end lines above clips, distinct from the playhead.
extends Control

var clip_selection_manager: ClipSelectionManager
var grid_helper: GridHelper
var line_color: Color = Color(0.4, 0.8, 1.0, 0.85)
var line_width: float = 2.0


## Ignore mouse so clips and empty-lane clicks still reach the timeline.
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## Bind to selection and grid so zoom, scroll, and range edits redraw the lines.
func bind(manager: ClipSelectionManager, helper: GridHelper) -> void:
	if clip_selection_manager and clip_selection_manager.range_changed.is_connected(queue_redraw):
		clip_selection_manager.range_changed.disconnect(queue_redraw)
	if grid_helper and grid_helper.changed.is_connected(queue_redraw):
		grid_helper.changed.disconnect(queue_redraw)

	clip_selection_manager = manager
	grid_helper = helper

	if clip_selection_manager and not clip_selection_manager.range_changed.is_connected(queue_redraw):
		clip_selection_manager.range_changed.connect(queue_redraw)
	if grid_helper and not grid_helper.changed.is_connected(queue_redraw):
		grid_helper.changed.connect(queue_redraw)
	queue_redraw()


## Draw the blue start line, and the end line when a range exists.
func _draw() -> void:
	if not clip_selection_manager or not clip_selection_manager.range_visible or not grid_helper:
		return

	var start_x := _tick_to_overlay_x(clip_selection_manager.range_start_tick)
	draw_line(Vector2(start_x, 0.0), Vector2(start_x, size.y), line_color, line_width)
	if clip_selection_manager.range_has_end and clip_selection_manager.range_end_tick != clip_selection_manager.range_start_tick:
		var end_x := _tick_to_overlay_x(clip_selection_manager.range_end_tick)
		draw_line(Vector2(end_x, 0.0), Vector2(end_x, size.y), line_color, line_width)


## Convert a song tick to overlay X, matching the playhead's scroll math.
func _tick_to_overlay_x(ticks: int) -> float:
	return grid_helper.ticks_to_pixels(ticks) - grid_helper.scroll_position
