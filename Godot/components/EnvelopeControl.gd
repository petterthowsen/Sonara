## Envelope editor for an `Envelope` resource: any subset of attack, decay, sustain and release
## (`Envelope.stages`).
##
## Layout, left to right: attack rises to the peak, decay falls to the sustain level, a sustain
## plateau stands in for the held note, and release falls to zero. Stages are drawn end to end.
## Every time stage gets an equal slot, and its length within the slot is
## the envelope's per-stage curve (`Envelope.set_stage_curve`, normally the parameter's own), so
## short times stay visible and the display moves at the same rate as the parameter's knob. Without a decay stage, attack rises straight to the sustain level.
##
## Handles: attack (x), decay (x = time, y = sustain), sustain (y, only without a decay stage),
## and release (x). Shift drags finely. Hovering or dragging a handle shows its value.
## Everything is drawn inside the control: the curve is inset by the handle radius.
@tool
class_name EnvelopeControl extends Control

enum Handle { NONE = -1, ATTACK, DECAY, SUSTAIN, RELEASE }

## Share of the width the sustain plateau takes when a release stage follows it.
const SUSTAIN_WIDTH := 0.2
const LEVEL_GRID := [0.25, 0.5, 0.75]
const STAGE_LABEL_FONT_SIZE := 10
## Height below which the stage letters are left out.
const MIN_HEIGHT_FOR_LABELS := 48.0

var _tc := ThemedColors.new(self, &"EnvelopeControl")
var bg_color: Color:
	get:
		return _tc.get_color(&"bg")
	set(c):
		_tc.set_color(&"bg", c)

var line_color: Color:
	get:
		return _tc.get_color(&"line")
	set(c):
		_tc.set_color(&"line", c)

@export var line_width := 1.5:
	set(w):
		line_width = w
		queue_redraw()

## Opacity of the area under the curve (in line_color).
@export_range(0.0, 1.0) var fill_alpha := 0.12:
	set(a):
		fill_alpha = a
		queue_redraw()

var grid_color: Color:
	get:
		return _tc.get_color(&"grid")
	set(c):
		_tc.set_color(&"grid", c)

@export var grid_width := 1.0:
	set(w):
		grid_width = w
		queue_redraw()

var handle_color: Color:
	get:
		return _tc.get_color(&"handle")
	set(c):
		_tc.set_color(&"handle", c)

var handle_color_hover: Color:
	get:
		return _tc.get_color(&"handle_hover")
	set(c):
		_tc.set_color(&"handle_hover", c)

@export var handle_radius := 4.0:
	set(r):
		handle_radius = r
		queue_redraw()

@export var envelope: Envelope:
	set(value):
		if envelope == value:
			return
		if envelope != null and envelope.changed.is_connected(_on_envelope_changed):
			envelope.changed.disconnect(_on_envelope_changed)
		envelope = value
		if envelope != null:
			envelope.changed.connect(_on_envelope_changed)
		queue_redraw()

var _hover := Handle.NONE
var _drag := Handle.NONE
var _fine_drag := FineDrag.new()
var _tooltip: ValueTooltip = null


func _ready() -> void:
	mouse_exited.connect(_on_mouse_exited)


func _get_minimum_size() -> Vector2:
	return Vector2(60, 30)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_tc.refresh()
		queue_redraw()
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_EXIT_TREE:
		if not is_visible_in_tree():
			_drag = Handle.NONE
			_hover = Handle.NONE
			_refresh_tooltip()


func _on_envelope_changed() -> void:
	queue_redraw()
	_refresh_tooltip()


## ============================================================================
## GEOMETRY
## ============================================================================

## The area the curve and handle centers live in, inset so handles never leave the control.
func get_inner_rect() -> Rect2:
	var pad := handle_radius + 1.0
	return Rect2(Vector2(pad, pad), (size - Vector2(pad, pad) * 2.0).max(Vector2.ONE))


func _has(stage: Envelope.Stage) -> bool:
	return envelope != null and envelope.has_stage(stage)


## True when the curve holds at the sustain level (the note is held until release).
func _has_plateau() -> bool:
	return _has(Envelope.Stage.SUSTAIN) or _has(Envelope.Stage.RELEASE)


## Width of one time stage's slot.
func _slot_width() -> float:
	var inner := get_inner_rect()
	var count := 0
	for stage in Envelope.TIME_STAGES:
		if _has(stage):
			count += 1
	var free := inner.size.x * (1.0 - SUSTAIN_WIDTH) if _has_plateau() else inner.size.x
	return free / maxf(count, 1)


## Level the curve holds after decay (or after attack without a decay stage), 0–1.
func sustain_level() -> float:
	if _has(Envelope.Stage.SUSTAIN):
		return clampf(envelope.sustain, 0.0, 1.0)
	return 0.0 if _has(Envelope.Stage.DECAY) else 1.0


## Time stage value → 0–1 share of its slot.
func _stage_fraction(stage: Envelope.Stage) -> float:
	return envelope.stage_to_fraction(stage, envelope.get_stage_value(stage))


## Inverse of `_stage_fraction`: share of the slot → stage value.
func _fraction_to_value(stage: Envelope.Stage, fraction: float) -> float:
	return envelope.fraction_to_stage(stage, fraction)


func _level_to_y(level: float) -> float:
	var inner := get_inner_rect()
	return inner.end.y - clampf(level, 0.0, 1.0) * inner.size.y


## Key x positions: attack end, decay end, sustain end, release end.
func _stage_ends() -> Dictionary:
	var inner := get_inner_rect()
	var slot := _slot_width()
	var x := inner.position.x
	var ends := {}
	if _has(Envelope.Stage.ATTACK):
		x += _stage_fraction(Envelope.Stage.ATTACK) * slot
	ends[Handle.ATTACK] = x
	if _has(Envelope.Stage.DECAY):
		x += _stage_fraction(Envelope.Stage.DECAY) * slot
	ends[Handle.DECAY] = x
	if _has(Envelope.Stage.RELEASE):
		x += inner.size.x * SUSTAIN_WIDTH
	elif _has(Envelope.Stage.SUSTAIN):
		x = inner.end.x
	ends[Handle.SUSTAIN] = x
	if _has(Envelope.Stage.RELEASE):
		x += _stage_fraction(Envelope.Stage.RELEASE) * slot
	ends[Handle.RELEASE] = x
	return ends


## The envelope as a polyline, in local coordinates.
func get_curve_points() -> PackedVector2Array:
	var points := PackedVector2Array()
	if envelope == null:
		return points
	var inner := get_inner_rect()
	var ends := _stage_ends()
	var bottom := inner.end.y
	var sus_y := _level_to_y(sustain_level())
	var peak_y := _level_to_y(1.0) if _has(Envelope.Stage.DECAY) else sus_y
	points.append(Vector2(inner.position.x, bottom))
	points.append(Vector2(ends[Handle.ATTACK], peak_y))
	if _has(Envelope.Stage.DECAY):
		points.append(Vector2(ends[Handle.DECAY], sus_y))
	if _has_plateau():
		points.append(Vector2(ends[Handle.SUSTAIN], sus_y))
	if _has(Envelope.Stage.RELEASE):
		points.append(Vector2(ends[Handle.RELEASE], bottom))
	return points


## Handles present for the envelope's stages.
func get_handles() -> Array[Handle]:
	var handles: Array[Handle] = []
	if _has(Envelope.Stage.ATTACK):
		handles.append(Handle.ATTACK)
	if _has(Envelope.Stage.DECAY):
		handles.append(Handle.DECAY)
	elif _has(Envelope.Stage.SUSTAIN):
		handles.append(Handle.SUSTAIN)
	if _has(Envelope.Stage.RELEASE):
		handles.append(Handle.RELEASE)
	return handles


func get_handle_position(handle: Handle) -> Vector2:
	var ends := _stage_ends()
	var sus_y := _level_to_y(sustain_level())
	match handle:
		Handle.ATTACK:
			return Vector2(ends[Handle.ATTACK], _level_to_y(1.0) if _has(Envelope.Stage.DECAY) else sus_y)
		Handle.DECAY:
			return Vector2(ends[Handle.DECAY], sus_y)
		Handle.SUSTAIN:
			return Vector2((ends[Handle.DECAY] + ends[Handle.SUSTAIN]) * 0.5, sus_y)
		Handle.RELEASE:
			return Vector2(ends[Handle.RELEASE], get_inner_rect().end.y)
	return Vector2.ZERO


## Handle under `pos` (the nearest within reach), or NONE.
func handle_at(pos: Vector2) -> Handle:
	var best := Handle.NONE
	var best_dist := maxf(handle_radius * 2.5, 8.0)
	for handle in get_handles():
		var dist := get_handle_position(handle).distance_to(pos)
		if dist <= best_dist:
			best = handle
			best_dist = dist
	return best


## ============================================================================
## INPUT
## ============================================================================

func _gui_input(event: InputEvent) -> void:
	if envelope == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var handle := handle_at(event.position)
			if handle != Handle.NONE:
				_drag = handle
				_fine_drag.begin_at(get_handle_position(handle), event.position)
				queue_redraw()
				_refresh_tooltip()
				accept_event()
		elif _drag != Handle.NONE:
			_drag = Handle.NONE
			_set_hover(handle_at(event.position))
			queue_redraw()
			_refresh_tooltip()
			accept_event()
	elif event is InputEventMouseMotion:
		if _drag != Handle.NONE:
			_drag_to(_fine_drag.update(event.position, event.shift_pressed, get_inner_rect()))
			accept_event()
		else:
			_set_hover(handle_at(event.position))


func _set_hover(handle: Handle) -> void:
	if handle == _hover:
		return
	_hover = handle
	mouse_default_cursor_shape = Control.CURSOR_ARROW if handle == Handle.NONE else Control.CURSOR_POINTING_HAND
	queue_redraw()
	_refresh_tooltip()


func _on_mouse_exited() -> void:
	if _drag == Handle.NONE:
		_set_hover(Handle.NONE)


## Apply a dragged handle position to the envelope.
func _drag_to(point: Vector2) -> void:
	var inner := get_inner_rect()
	var ends := _stage_ends()
	var slot := _slot_width()
	var level := clampf((inner.end.y - point.y) / inner.size.y, 0.0, 1.0)
	match _drag:
		Handle.ATTACK:
			envelope.attack = _fraction_to_value(Envelope.Stage.ATTACK, (point.x - inner.position.x) / slot)
			if not _has(Envelope.Stage.DECAY) and _has(Envelope.Stage.SUSTAIN):
				envelope.sustain = level
		Handle.DECAY:
			envelope.decay = _fraction_to_value(Envelope.Stage.DECAY, (point.x - ends[Handle.ATTACK]) / slot)
			if _has(Envelope.Stage.SUSTAIN):
				envelope.sustain = level
		Handle.SUSTAIN:
			envelope.sustain = level
		Handle.RELEASE:
			var release_start: float = ends[Handle.SUSTAIN]
			envelope.release = _fraction_to_value(Envelope.Stage.RELEASE, (point.x - release_start) / slot)


## ============================================================================
## TOOLTIP
## ============================================================================

## Readout for `handle`, e.g. "Decay 120 ms · Sustain 70%".
func get_handle_text(handle: Handle) -> String:
	match handle:
		Handle.ATTACK:
			if not _has(Envelope.Stage.DECAY) and _has(Envelope.Stage.SUSTAIN):
				return "Attack %s · Sustain %s" % [format_time(envelope.attack), format_level(envelope.sustain)]
			return "Attack %s" % format_time(envelope.attack)
		Handle.DECAY:
			if _has(Envelope.Stage.SUSTAIN):
				return "Decay %s · Sustain %s" % [format_time(envelope.decay), format_level(envelope.sustain)]
			return "Decay %s" % format_time(envelope.decay)
		Handle.SUSTAIN:
			return "Sustain %s" % format_level(envelope.sustain)
		Handle.RELEASE:
			return "Release %s" % format_time(envelope.release)
	return ""


static func format_time(seconds: float) -> String:
	if seconds < 0.01:
		return "%.1f ms" % (seconds * 1000.0)
	if seconds < 1.0:
		return "%d ms" % roundi(seconds * 1000.0)
	return "%.2f s" % seconds


static func format_level(level: float) -> String:
	return "%d%%" % roundi(level * 100.0)


func _refresh_tooltip() -> void:
	if Engine.is_editor_hint():
		return
	var handle := _drag if _drag != Handle.NONE else _hover
	if handle == Handle.NONE or envelope == null or not is_visible_in_tree():
		if _tooltip:
			_tooltip.visible = false
		return
	if _tooltip == null:
		_tooltip = ValueTooltip.attach(self)
		_tooltip.gap = handle_radius + 6.0
	_tooltip.set_text(get_handle_text(handle))
	_tooltip.visible = true
	var at := get_global_transform() * get_handle_position(handle)
	_tooltip.place_above(Rect2(at, Vector2.ZERO))


## ============================================================================
## DRAWING
## ============================================================================

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)
	if envelope == null:
		return
	var inner := get_inner_rect()

	for level in LEVEL_GRID:
		var y := roundf(_level_to_y(level)) + 0.5
		draw_line(Vector2(inner.position.x, y), Vector2(inner.end.x, y), grid_color, grid_width)

	var points := get_curve_points()
	# stage boundaries, so each stage's length reads at a glance
	for i in range(1, points.size() - 1):
		var x := roundf(points[i].x) + 0.5
		draw_line(Vector2(x, inner.position.y), Vector2(x, inner.end.y), grid_color, grid_width)

	_draw_fill(points, inner.end.y)
	if points.size() >= 2:
		draw_polyline(points, line_color, line_width, true)
	_draw_stage_labels()

	for handle in get_handles():
		var active := handle == _drag or (handle == _hover and _drag == Handle.NONE)
		var pos := get_handle_position(handle)
		draw_circle(pos, handle_radius, handle_color_hover if active else handle_color, true, -1.0, true)
		if active:
			draw_circle(pos, handle_radius + 2.0, Color(handle_color_hover, 0.35), false, 1.0, true)


## Fill under the curve, one quad per segment (sidesteps triangulating a self-touching polygon).
func _draw_fill(points: PackedVector2Array, bottom: float) -> void:
	if fill_alpha <= 0.0:
		return
	var fill := Color(line_color, line_color.a * fill_alpha)
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		if b.x - a.x < 0.5:
			continue
		draw_colored_polygon(PackedVector2Array([a, b, Vector2(b.x, bottom), Vector2(a.x, bottom)]), fill)


## Faint stage letters along the bottom, centered in each stage that has room.
func _draw_stage_labels() -> void:
	if get_inner_rect().size.y < MIN_HEIGHT_FOR_LABELS:
		return
	var font := get_theme_default_font()
	var ends := _stage_ends()
	var inner := get_inner_rect()
	var spans := {
		"A": [inner.position.x, ends[Handle.ATTACK], Envelope.Stage.ATTACK],
		"D": [ends[Handle.ATTACK], ends[Handle.DECAY], Envelope.Stage.DECAY],
		"S": [ends[Handle.DECAY], ends[Handle.SUSTAIN], Envelope.Stage.SUSTAIN],
		"R": [ends[Handle.SUSTAIN], ends[Handle.RELEASE], Envelope.Stage.RELEASE],
	}
	var color := Color(line_color, 0.35)
	for letter in spans:
		var span: Array = spans[letter]
		if not _has(span[2]):
			continue
		var text_width := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, STAGE_LABEL_FONT_SIZE).x
		if span[1] - span[0] < text_width + 4.0:
			continue
		var x: float = (span[0] + span[1] - text_width) * 0.5
		draw_string(font, Vector2(x, inner.end.y - 3.0), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, STAGE_LABEL_FONT_SIZE, color)
