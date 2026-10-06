## The Sampler's interactive waveform: the whole file with draggable play (blue, top) and loop
## (pink, bottom) points, the loop overlay with its crossfade ramp, and live playheads.
##
## A `WaveformView` child always shows the whole file; an overlay child above it draws everything
## else (the waveform renders through a shader, so overlays can't go in this control's own draw).
## Every point is a normalized 0..1 position over the file, as the engine stores them. The control
## knows nothing about `DeviceInstance`: the owner sets the properties and listens to
## `point_drag_started` / `point_dragged` / `point_drag_ended`.
##
## Drag constraints mirror the engine's `resolve_regions`: `play_start < play_end`; with a loop on,
## the loop handles stay inside the play region and the play handles can't cross a loop handle
## that lies strictly inside it (one sitting on the play point, like the default 0..1 loop, or
## outside it is clamped by the engine and doesn't block). Shift drags finely, a double click resets a point to its default.
##
## Spec 023 adds a clickable `title` (the focused zone's name, `title_clicked`), an optional
## placeholder action button (`placeholder_action`, `placeholder_action_pressed`), a right-click
## request (`context_menu_requested`) and audio-asset drops (`assets_dropped`).
class_name SampleDisplay extends Control

signal point_drag_started(which: int)
## `value` is the new normalized position, already constrained.
signal point_dragged(which: int, value: float)
signal point_drag_ended(which: int)
## The title label was clicked.
signal title_clicked()
## The placeholder action button was pressed.
signal placeholder_action_pressed()
## Right click on the display, at `position` (local).
signal context_menu_requested(position: Vector2)
## One audio Asset or several were dropped; always an Array.
signal assets_dropped(assets: Array)

enum Point { PLAY_START, PLAY_END, LOOP_START, LOOP_END }
enum LoopMode { OFF, ON, PING_PONG }

const PLAY_COLOR := Color(0.35, 0.62, 1.0)
const LOOP_COLOR := Color(1.0, 0.45, 0.7)
const PLAYHEAD_COLOR := Color(1.0, 1.0, 1.0)
const BACKGROUND := Color(0.08, 0.08, 0.1)
const DIM_COLOR := Color(0, 0, 0, 0.45)
const LOOP_FILL_ALPHA := 0.12
const PLACEHOLDER_COLOR := Color(0.7, 0.7, 0.75, 0.85)
const TITLE_COLOR := Color(0.92, 0.92, 0.95)
const TITLE_BG := Color(0, 0, 0, 0.55)
const TITLE_FONT_SIZE := 11
## The title sits clear of the Play Start handle at the left edge.
const TITLE_MARGIN := Vector2(12, 3)
const TITLE_PAD := 4.0

const HANDLE_SIZE := 8.0
const HIT_BAND := 5.0
## Playheads vanish when no packet arrives for this long (a lost `count = 0` frame).
const PLAYHEAD_TIMEOUT_MS := 250
const DEFAULTS := {
	Point.PLAY_START: 0.0,
	Point.PLAY_END: 1.0,
	Point.LOOP_START: 0.0,
	Point.LOOP_END: 1.0,
}
## Smallest region/loop in normalized units when the file length is unknown.
const MIN_GAP := 0.001
const MIN_GAP_FRAMES := 4.0

var play_start := 0.0:
	set(v):
		play_start = v
		_redraw()
var play_end := 1.0:
	set(v):
		play_end = v
		_redraw()
var loop_start := 0.0:
	set(v):
		loop_start = v
		_redraw()
var loop_end := 1.0:
	set(v):
		loop_end = v
		_redraw()
var loop_mode := LoopMode.OFF:
	set(v):
		loop_mode = v
		_redraw()
## Crossfade as a fraction of the loop length (the engine's Crossfade %, divided by 100).
var xfade := 0.0:
	set(v):
		xfade = v
		_redraw()
var reverse := false:
	set(v):
		reverse = v
		_redraw()
## Linear gain the waveform is drawn at, so a louder sample looks taller (the view clips at full scale).
var gain := 1.0:
	set(v):
		gain = v
		if _wave:
			_wave.gain = v
## Length of the file in seconds, for the drag read-out. 0 hides the time.
var duration := 0.0
## Length of the file in frames (at the playback rate), for the minimum gaps. 0 when unknown.
var frames := 0
## Drawn centered while there is no waveform ("Drop sample(s) here", "Loading…").
var placeholder := "":
	set(v):
		placeholder = v
		_update_action_button()
		_redraw()
## Text of a button shown under the placeholder ("Create Multisample"); empty hides it.
var placeholder_action := "":
	set(v):
		placeholder_action = v
		_update_action_button()
## Label drawn at the top left (the focused zone's name); empty hides it. Clicking it emits
## `title_clicked`.
var title := "":
	set(v):
		title = v
		_redraw()
## Whether audio assets dropped here emit `assets_dropped`.
var accepts_drops := true

var data: WaveformData = null:
	set(d):
		if data != null and data.loaded.is_connected(_on_data_loaded):
			data.loaded.disconnect(_on_data_loaded)
		data = d
		if data != null and not data.is_ready():
			data.loaded.connect(_on_data_loaded)
		if _wave:
			_wave.data = d
		_fit_waveform()
		_update_action_button()
		_redraw()

## Current playhead positions (normalized) and levels (0..1), after extrapolation.
var playheads := PackedFloat32Array()
var playhead_levels := PackedFloat32Array()

var _wave: WaveformView
var _overlay: Control
var _action_button: Button
var _hover := -1
var _dragging := -1
var _fine := FineDrag.new()
var _packet_positions := PackedFloat32Array()
var _packet_velocities := PackedFloat32Array()
var _packet_time_ms := 0


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(120, 64)
	_wave = WaveformView.new()
	_wave.name = "WaveformView"
	_wave.placeholder_text = ""
	_wave.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wave.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wave.gain = gain
	add_child(_wave)
	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	_action_button = Button.new()
	_action_button.name = "PlaceholderAction"
	_action_button.visible = false
	_action_button.focus_mode = Control.FOCUS_NONE
	_action_button.pressed.connect(func() -> void: placeholder_action_pressed.emit())
	add_child(_action_button)
	resized.connect(_fit_waveform)
	resized.connect(_place_action_button)
	set_process(false)


func _ready() -> void:
	_fit_waveform()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND)


func _on_data_loaded(_ok := true) -> void:
	_fit_waveform()
	_update_action_button()
	_redraw()


func is_waveform_ready() -> bool:
	return data != null and data.is_ready()


## The placeholder action button shows only while the placeholder does.
func _update_action_button() -> void:
	if _action_button == null:
		return
	_action_button.text = placeholder_action
	_action_button.visible = not placeholder_action.is_empty() and not placeholder.is_empty() and not is_waveform_ready()
	_place_action_button()


func is_placeholder_action_visible() -> bool:
	return _action_button != null and _action_button.visible


func _place_action_button() -> void:
	if _action_button == null or not _action_button.visible:
		return
	_action_button.reset_size()
	var button_size := _action_button.get_combined_minimum_size()
	_action_button.size = button_size
	_action_button.position = Vector2(
		roundf((size.x - button_size.x) * 0.5), roundf(size.y * 0.5 + 6.0))


func waveform_view() -> WaveformView:
	return _wave


func _redraw() -> void:
	queue_redraw()
	if _overlay:
		_overlay.queue_redraw()


## Show the whole sample: frame 0 at the left edge, the last frame at the right.
func _fit_waveform() -> void:
	if _wave == null:
		return
	if _wave.is_data_ready() and size.x > 0.0:
		_wave.start_frame = 0.0
		_wave.frames_per_pixel = float(data.frames) / size.x


# ============================================================================
# GEOMETRY AND CONSTRAINTS
# ============================================================================

func loop_visible() -> bool:
	return loop_mode != LoopMode.OFF


## The point's current value.
func point_value(which: int) -> float:
	match which:
		Point.PLAY_START:
			return play_start
		Point.PLAY_END:
			return play_end
		Point.LOOP_START:
			return loop_start
		_:
			return loop_end


func point_x(which: int) -> float:
	return point_value(which) * size.x


func _set_point(which: int, v: float) -> void:
	match which:
		Point.PLAY_START:
			play_start = v
		Point.PLAY_END:
			play_end = v
		Point.LOOP_START:
			loop_start = v
		_:
			loop_end = v


func _gap() -> float:
	return MIN_GAP_FRAMES / float(frames) if frames > 0 else MIN_GAP


## The loop clamped into the play region, as the engine resolves it.
func effective_loop() -> Vector2:
	var gap := _gap()
	var a := clampf(minf(loop_start, loop_end), play_start, play_end)
	var b := clampf(maxf(loop_start, loop_end), play_start, play_end)
	if b - a < gap:
		b = minf(a + gap, play_end)
		a = maxf(b - gap, play_start)
	return Vector2(a, b)


## The allowed [min, max] of `which` given the other points.
func point_limits(which: int) -> Vector2:
	var gap := _gap()
	var loop := effective_loop()
	match which:
		Point.PLAY_START:
			var hi := play_end - gap
			if loop_visible() and loop_start > play_start and loop_start < play_end:
				hi = minf(hi, loop_start)
			return Vector2(0.0, maxf(hi, 0.0))
		Point.PLAY_END:
			var lo := play_start + gap
			if loop_visible() and loop_end > play_start and loop_end < play_end:
				lo = maxf(lo, loop_end)
			return Vector2(minf(lo, 1.0), 1.0)
		Point.LOOP_START:
			return Vector2(play_start, maxf(loop.y - gap, play_start))
		_:
			return Vector2(minf(loop.x + gap, play_end), play_end)


func constrain(which: int, v: float) -> float:
	var limits := point_limits(which)
	return clampf(v, limits.x, limits.y)


## The point under `pos`, or -1. Play handles win in the top half, loop handles in the bottom.
func hit_test(pos: Vector2) -> int:
	var top_half := pos.y < size.y * 0.5
	var order: Array[int] = [Point.PLAY_START, Point.PLAY_END, Point.LOOP_START, Point.LOOP_END]
	if not top_half:
		order = [Point.LOOP_START, Point.LOOP_END, Point.PLAY_START, Point.PLAY_END]
	var best := -1
	var best_distance := INF
	var best_preferred := false
	for which in order:
		var is_loop := which >= Point.LOOP_START
		if is_loop and not loop_visible():
			continue
		var distance := _hit_distance(which, pos)
		if distance < 0.0:
			continue
		var preferred := is_loop != top_half
		if best == -1 or (preferred and not best_preferred) or (preferred == best_preferred and distance < best_distance):
			best = which
			best_distance = distance
			best_preferred = preferred
	return best


## Horizontal distance to the handle when `pos` is on its triangle or line band, else -1.
func _hit_distance(which: int, pos: Vector2) -> float:
	var x := point_x(which)
	var distance := absf(pos.x - x)
	var on_triangle := false
	if which >= Point.LOOP_START:
		on_triangle = pos.y >= size.y - HANDLE_SIZE - 1.0
	else:
		on_triangle = pos.y <= HANDLE_SIZE + 1.0
	if distance <= HANDLE_SIZE * 0.5 + 1.0 and on_triangle:
		return distance
	if distance <= HIT_BAND:
		var in_half := pos.y >= size.y * 0.5 if which >= Point.LOOP_START else pos.y < size.y * 0.5
		if in_half:
			return distance
	return -1.0


# ============================================================================
# INTERACTION
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_RIGHT and button.pressed and _dragging < 0:
			accept_event()
			context_menu_requested.emit(button.position)
			return
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			var which := hit_test(button.position)
			if which < 0:
				if title_rect().has_point(button.position):
					accept_event()
					title_clicked.emit()
				return
			accept_event()
			if button.double_click:
				_set_and_emit(which, constrain(which, DEFAULTS[which]))
				return
			_begin_drag(which, button.position)
		elif _dragging >= 0:
			accept_event()
			_end_drag()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging >= 0:
			accept_event()
			drag_to(motion.position, motion.shift_pressed)
		else:
			_set_hover(hit_test(motion.position))
			if _hover < 0:
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
						if title_rect().has_point(motion.position) else Control.CURSOR_ARROW


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _dragging < 0:
		_set_hover(-1)


func _begin_drag(which: int, mouse: Vector2) -> void:
	_dragging = which
	_hover = which
	_fine.begin_at(Vector2(point_x(which), 0.0), mouse)
	point_drag_started.emit(which)
	_redraw()


## Move the dragged point to the tracked pointer. Public so tests can drive a drag.
func drag_to(mouse: Vector2, fine := false) -> void:
	if _dragging < 0 or size.x <= 0.0:
		return
	var point := _fine.update(mouse, fine)
	_set_and_emit(_dragging, constrain(_dragging, point.x / size.x))


func _end_drag() -> void:
	var which := _dragging
	_dragging = -1
	point_drag_ended.emit(which)
	_set_hover(hit_test(get_local_mouse_position()))
	_redraw()


func _set_and_emit(which: int, v: float) -> void:
	if is_equal_approx(point_value(which), v):
		return
	var starting := _dragging < 0
	if starting:
		point_drag_started.emit(which)
	_set_point(which, v)
	point_dragged.emit(which, v)
	if starting:
		point_drag_ended.emit(which)


func _set_hover(which: int) -> void:
	if which == _hover:
		return
	_hover = which
	mouse_default_cursor_shape = Control.CURSOR_MOVE if which >= 0 else Control.CURSOR_ARROW
	_redraw()


## Test hooks: start, move and end a drag without going through input events.
func begin_drag(which: int, mouse: Vector2) -> void:
	_begin_drag(which, mouse)


func end_drag() -> void:
	if _dragging >= 0:
		_end_drag()


func is_dragging() -> bool:
	return _dragging >= 0


# ============================================================================
# PLAYHEADS
# ============================================================================

## Decode a `"playheads"` blob: {count, position, velocity, level}. An empty or malformed blob
## decodes to count 0.
static func decode_playheads(blob: PackedByteArray) -> Dictionary:
	var result := {
		"count": 0,
		"position": PackedFloat32Array(),
		"velocity": PackedFloat32Array(),
		"level": PackedFloat32Array(),
	}
	if blob.size() < 4:
		return result
	var count := int(blob.decode_u32(0))
	if count <= 0 or blob.size() < 4 + count * 12:
		return result
	var positions := PackedFloat32Array()
	var velocity := PackedFloat32Array()
	var level := PackedFloat32Array()
	positions.resize(count)
	velocity.resize(count)
	level.resize(count)
	for i in count:
		var base := 4 + i * 12
		positions[i] = blob.decode_float(base)
		velocity[i] = blob.decode_float(base + 4)
		level[i] = blob.decode_float(base + 8)
	result["count"] = count
	result["position"] = positions
	result["velocity"] = velocity
	result["level"] = level
	return result


## Snap to a decoded packet; `step` then extrapolates from it.
func apply_playhead_packet(decoded: Dictionary, now_ms: int = Time.get_ticks_msec()) -> void:
	_packet_time_ms = now_ms
	_packet_positions = decoded["position"]
	_packet_velocities = decoded["velocity"]
	playheads = _packet_positions.duplicate()
	playhead_levels = decoded["level"]
	set_process(not playheads.is_empty())
	_overlay.queue_redraw()


## Extrapolate each playhead with its velocity, clamped to the play region; clear them when no
## packet arrived for `PLAYHEAD_TIMEOUT_MS`.
func step(now_ms: int = Time.get_ticks_msec()) -> void:
	if playheads.is_empty():
		set_process(false)
		return
	if now_ms - _packet_time_ms > PLAYHEAD_TIMEOUT_MS:
		clear_playheads()
		return
	var elapsed := float(now_ms - _packet_time_ms) / 1000.0
	var lo := minf(play_start, play_end)
	var hi := maxf(play_start, play_end)
	for i in _packet_positions.size():
		playheads[i] = clampf(_packet_positions[i] + _packet_velocities[i] * elapsed, lo, hi)
	_overlay.queue_redraw()


func clear_playheads() -> void:
	playheads = PackedFloat32Array()
	playhead_levels = PackedFloat32Array()
	_packet_positions = PackedFloat32Array()
	_packet_velocities = PackedFloat32Array()
	set_process(false)
	_overlay.queue_redraw()


func _process(_delta: float) -> void:
	step()


# ============================================================================
# DRAWING
# ============================================================================

## The crossfade ramp as normalized [from, to] before Loop End (after Loop Start when reversed),
## or an empty vector when there is none. Capped like the engine: half the loop, and the material
## available outside the loop on the blended side. Ping-Pong has none.
func effective_crossfade() -> Vector2:
	if loop_mode != LoopMode.ON or xfade <= 0.0:
		return Vector2.ZERO
	var loop := effective_loop()
	var length := loop.y - loop.x
	var outside := loop.x if not reverse else 1.0 - loop.y
	var width := minf(xfade * length, minf(length * 0.5, outside))
	if width <= 0.0:
		return Vector2.ZERO
	return Vector2(loop.x, loop.x + width) if reverse else Vector2(loop.y - width, loop.y)


func _draw_overlay() -> void:
	var o := _overlay
	if data == null or not data.is_ready():
		if not placeholder.is_empty():
			var font := ThemeDB.fallback_font
			if _action_button.visible:
				o.draw_string(font, Vector2(0, size.y * 0.5 - 4), placeholder, HORIZONTAL_ALIGNMENT_CENTER, size.x, 13, PLACEHOLDER_COLOR)
			else:
				o.draw_string(font, Vector2(8, size.y * 0.5 + 4), placeholder, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, PLACEHOLDER_COLOR)
		_draw_title(o)
		return
	var w := size.x
	var h := size.y
	var x0 := play_start * w
	var x1 := play_end * w
	if x0 > 0.5:
		o.draw_rect(Rect2(0, 0, x0, h), DIM_COLOR)
	if x1 < w - 0.5:
		o.draw_rect(Rect2(x1, 0, w - x1, h), DIM_COLOR)
	if loop_visible():
		_draw_loop(o, w, h)
	_draw_handle(o, Point.PLAY_START, PLAY_COLOR, true)
	_draw_handle(o, Point.PLAY_END, PLAY_COLOR, true)
	if loop_visible():
		_draw_handle(o, Point.LOOP_START, LOOP_COLOR, false)
		_draw_handle(o, Point.LOOP_END, LOOP_COLOR, false)
	for i in playheads.size():
		var alpha := clampf(playhead_levels[i], 0.15, 1.0) if i < playhead_levels.size() else 1.0
		var x := roundf(playheads[i] * w) + 0.5
		o.draw_line(Vector2(x, 0), Vector2(x, h), Color(PLAYHEAD_COLOR, alpha), 1.0)
	if _dragging >= 0:
		_draw_readout(o, _dragging)
	_draw_title(o)


func _draw_loop(o: Control, w: float, h: float) -> void:
	var loop := effective_loop()
	o.draw_rect(Rect2(loop.x * w, 0, (loop.y - loop.x) * w, h), Color(LOOP_COLOR, LOOP_FILL_ALPHA))
	var ramp := effective_crossfade()
	if ramp == Vector2.ZERO:
		return
	# A triangle fading the loop out toward its wrap point.
	var a := ramp.x * w
	var b := ramp.y * w
	var color := Color(LOOP_COLOR, 0.35)
	var points: PackedVector2Array
	if reverse:
		points = PackedVector2Array([Vector2(a, 0), Vector2(a, h), Vector2(b, h)])
	else:
		points = PackedVector2Array([Vector2(b, 0), Vector2(b, h), Vector2(a, h)])
	o.draw_colored_polygon(points, color)


func _draw_handle(o: Control, which: int, base: Color, top: bool) -> void:
	var active := which == _hover or which == _dragging
	var color := base.lightened(0.35) if active else base
	var x := roundf(point_x(which)) + 0.5
	o.draw_line(Vector2(x, 0), Vector2(x, size.y), Color(color, 0.9 if active else 0.75), 1.0)
	var s := HANDLE_SIZE
	var points: PackedVector2Array
	if top:
		points = PackedVector2Array([Vector2(x - s * 0.5, 0), Vector2(x + s * 0.5, 0), Vector2(x, s)])
	else:
		points = PackedVector2Array([Vector2(x - s * 0.5, size.y), Vector2(x + s * 0.5, size.y), Vector2(x, size.y - s)])
	o.draw_colored_polygon(points, color)


func _draw_readout(o: Control, which: int) -> void:
	if duration <= 0.0:
		return
	var text := format_time(point_value(which) * duration)
	var font := ThemeDB.fallback_font
	var font_size := 11
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 8.0
	var x := clampf(point_x(which) - width * 0.5, 0.0, maxf(size.x - width, 0.0))
	var y := HANDLE_SIZE + 4.0 if which < Point.LOOP_START else size.y - HANDLE_SIZE - 20.0
	o.draw_rect(Rect2(x, y, width, 16), Color(0, 0, 0, 0.75))
	o.draw_string(font, Vector2(x + 4, y + 12), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


## Where the title label is drawn (and clicked), clipped to the display. Empty without a title.
func title_rect() -> Rect2:
	if title.is_empty():
		return Rect2()
	var font := ThemeDB.fallback_font
	var text_width := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, TITLE_FONT_SIZE).x
	var width := minf(text_width + TITLE_PAD * 2.0, maxf(size.x - TITLE_MARGIN.x * 2.0, 0.0))
	return Rect2(TITLE_MARGIN, Vector2(width, TITLE_FONT_SIZE + 6.0))


func _draw_title(o: Control) -> void:
	var rect := title_rect()
	if rect.size.x <= TITLE_PAD * 2.0:
		return
	var font := ThemeDB.fallback_font
	o.draw_rect(rect, TITLE_BG)
	var text := fit_text(title, font, TITLE_FONT_SIZE, rect.size.x - TITLE_PAD * 2.0)
	o.draw_string(font, rect.position + Vector2(TITLE_PAD, TITLE_FONT_SIZE + 1.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, TITLE_FONT_SIZE, TITLE_COLOR)


## `text` cut to fit `max_width` pixels, ending in an ellipsis when cut; "" when not even one
## character fits. Canvas draws can't clip, so labels trim themselves (also the zone map's).
static func fit_text(text: String, font: Font, font_size: int, max_width: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_width:
		return text
	var lo := 0
	var hi := text.length()
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		var candidate := text.left(mid) + "…"
		if font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_width:
			lo = mid
		else:
			hi = mid - 1
	return text.left(lo) + "…" if lo > 0 else ""


# ============================================================================
# DROPS
# ============================================================================

## The audio Assets in `data` (one Asset or an Array of them), or [] when anything else is in it.
static func audio_assets_in(data: Variant) -> Array:
	var items: Array = data if data is Array else [data]
	if items.is_empty():
		return []
	for item in items:
		if not (item is Asset) or (item as Asset).type != Asset.TYPE.Audio:
			return []
	return items.duplicate()


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return accepts_drops and not audio_assets_in(data).is_empty()


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var assets := audio_assets_in(data)
	if not assets.is_empty():
		assets_dropped.emit(assets)


## `seconds` as mm:ss.mmm.
static func format_time(seconds: float) -> String:
	var total_ms := roundi(maxf(seconds, 0.0) * 1000.0)
	@warning_ignore("integer_division")
	return "%02d:%02d.%03d" % [total_ms / 60000, (total_ms / 1000) % 60, total_ms % 1000]
