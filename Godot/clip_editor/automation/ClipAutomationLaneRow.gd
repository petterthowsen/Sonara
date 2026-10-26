# ClipAutomationLaneRow.gd
# One automation lane drawn and edited inside the MIDI editor's automation pane (spec 055). It is
# the Arranger's AutomationLaneRow with the Timeline taken out: ticks map to x through the MIDI
# editor's grid helper and horizontal scroll, exactly as the note area and the value lanes do,
# and the row paints its own fill, grid lines and playhead (the Timeline paints those for
# Arranger rows). It leaves the note selection alone and takes keyboard focus on a press, so the
# pane can route Delete / Copy / Cut / Paste / Duplicate to the points (REQ-013).
class_name ClipAutomationLaneRow extends AutomationLaneRow

var midi_editor: MidiEditor = null
## Mirrors the note area's playhead; drawn above the curve.
var _playhead: TextureRect = null


func _init() -> void:
	hotkey_context = "clip_automation_lane"
	focus_mode = Control.FOCUS_CLICK


func _ready() -> void:
	super._ready()
	size_flags_vertical = Control.SIZE_FILL
	_playhead = TextureRect.new()
	_playhead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_playhead.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_playhead.stretch_mode = TextureRect.STRETCH_SCALE
	_playhead.visible = false
	add_child(_playhead)
	set_process(true)


## Show `p_lane` of `p_track`, laid out like `editor`'s note area. `manager` is the pane's
## point selection (one lane at a time, REQ-014).
func bind_to_clip_editor(p_lane: AutomationLane, p_track: Track, editor: MidiEditor, manager: AutomationPointSelectionManager) -> void:
	midi_editor = editor
	bind_to_lane(p_lane, p_track, null)
	selection_manager = manager
	if editor.grid_helper and not editor.grid_helper.changed.is_connected(queue_redraw):
		editor.grid_helper.changed.connect(queue_redraw)
	var bar := editor.h_scroll.get_h_scroll_bar()
	if not bar.value_changed.is_connected(_on_scrolled):
		bar.value_changed.connect(_on_scrolled)
	if not editor.note_area.item_rect_changed.is_connected(queue_redraw):
		editor.note_area.item_rect_changed.connect(queue_redraw)
	queue_redraw()


## Height of the row itself (the pane lane's entry, not the Arranger height of the lane).
func set_row_height(h: float) -> void:
	custom_minimum_size.y = h
	queue_redraw()


func _on_scrolled(_v: float) -> void:
	queue_redraw()


func _on_lane_height_changed(_new_height: int) -> void:
	# The lane's Arranger height is not this row's height (REQ-010).
	pass


func _redraw_background() -> void:
	queue_redraw()


func _release_other_selection() -> void:
	pass


# ============================================================================
# GEOMETRY
# ============================================================================

## x of the note area's scroll content origin, in this control's coordinates.
func _origin_offset() -> float:
	return midi_editor.h_scroll.global_position.x - global_position.x


func tick_to_x(tick: int) -> float:
	if midi_editor == null or midi_editor.grid_helper == null:
		return 0.0
	return midi_editor.grid_helper.ticks_to_pixels(tick) - midi_editor.h_scroll.scroll_horizontal + _origin_offset()


func x_to_tick(x: float) -> int:
	if midi_editor == null or midi_editor.grid_helper == null:
		return 0
	return midi_editor.grid_helper.pixels_to_ticks(x - _origin_offset() + midi_editor.h_scroll.scroll_horizontal)


func _snap_tick(tick: int) -> int:
	if midi_editor and midi_editor.grid_helper:
		return midi_editor.grid_helper.snap_ticks(tick)
	return tick


func _visible_x_range() -> Vector2:
	return Vector2(0.0, size.x)


# ============================================================================
# DRAWING
# ============================================================================

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), get_lane_color())
	_draw_grid()
	super._draw()


## The note area's grid lines, as ValueLaneStemArea._draw_grid draws them.
func _draw_grid() -> void:
	if midi_editor == null:
		return
	var gh := midi_editor.grid_helper
	var renderer := midi_editor.grid_renderer
	if gh == null or renderer == null or not renderer.visible:
		return
	var off := _origin_offset()
	for line in gh.get_visible_grid_lines(-off, size.x - off):
		var x: float = line.x + off
		if x < 0.0 or x > size.x:
			continue
		var width: float = line.width()
		var color: Color = line.color(renderer.subdivision_line_color, renderer.beat_line_color, renderer.bar_line_color)
		draw_rect(Rect2(roundf(x) - floorf(width * 0.5), 0.0, width, size.y), color, true, -1.0, false)


## Follow the note area's playhead (it moves every frame during playback), then the tooltip.
func _process(delta: float) -> void:
	_mirror_playhead()
	super._process(delta)
	set_process(true)


func _mirror_playhead() -> void:
	if midi_editor == null or _playhead == null:
		return
	var src: TextureRect = midi_editor.playhead
	_playhead.visible = src.visible
	if not src.visible:
		return
	_playhead.texture = src.texture
	_playhead.position = Vector2(src.global_position.x - global_position.x, 0.0)
	_playhead.size = Vector2(src.size.x, size.y)


# ============================================================================
# INPUT
# ============================================================================

## A press makes this lane the target of the keyboard shortcuts (until the note area or a
## value lane is pressed).
func _on_lane_pressed(pos: Vector2) -> void:
	grab_focus()
	super._on_lane_pressed(pos)
