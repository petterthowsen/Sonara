# DropIndicator.gd
# Glowing drop marker shared by every drag: an insert line between items, or a glowing outline
# around a header or slot. Top-level and click-through, so showing it never shifts layout.
class_name DropIndicator extends Control

## Accent used by every drop indicator.
const DEFAULT_COLOR := Color("#5aa0ff")

## Width of an insert line core, in pixels.
const LINE_WIDTH := 3.0

## How far the glow spreads past the core line, in pixels.
const GLOW_RADIUS := 6.0
const GLOW_STEPS := 4

var color := DEFAULT_COLOR

## Outline a header instead of drawing an insert line.
var _outline := false


func _init() -> void:
	top_level = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 100
	visible = false


## Place over global `rect`: a line rect for inserts, a header rect when `outline`.
func show_at(rect: Rect2, outline: bool) -> void:
	# Grow by the glow so it isn't clipped to the target rect.
	global_position = rect.position - Vector2(GLOW_RADIUS, GLOW_RADIUS)
	size = rect.size + Vector2(GLOW_RADIUS, GLOW_RADIUS) * 2.0
	if outline != _outline or not visible:
		_outline = outline
		visible = true
	queue_redraw()


## Show `indicator` at `rect` under `host`, creating it on first use. Returns the indicator.
static func place(
	host: Node,
	indicator: DropIndicator,
	rect: Rect2,
	outline: bool,
	p_color: Color = DEFAULT_COLOR
) -> DropIndicator:
	if indicator == null:
		indicator = DropIndicator.new()
		host.add_child(indicator)
	indicator.color = p_color
	indicator.show_at(rect, outline)
	return indicator


## Hide `indicator` if it exists.
static func hide_indicator(indicator: DropIndicator) -> void:
	if indicator:
		indicator.visible = false


## Thin line rect centered on `at`: vertical (spanning `span`'s height) when `vertical`,
## horizontal (spanning `span`'s width) otherwise.
static func line_rect(at: float, span: Rect2, vertical: bool) -> Rect2:
	if vertical:
		return Rect2(at - LINE_WIDTH * 0.5, span.position.y, LINE_WIDTH, span.size.y)
	return Rect2(span.position.x, at - LINE_WIDTH * 0.5, span.size.x, LINE_WIDTH)


func _draw() -> void:
	var core := Rect2(Vector2(GLOW_RADIUS, GLOW_RADIUS), size - Vector2(GLOW_RADIUS, GLOW_RADIUS) * 2.0)
	if _outline:
		draw_rect(core, Color(color, 0.15), true)
	# Soft halo: widening, fading copies of the core shape.
	for i in range(GLOW_STEPS, 0, -1):
		var spread := GLOW_RADIUS * float(i) / GLOW_STEPS
		var halo := Color(color, 0.12)
		if _outline:
			draw_rect(core.grow(spread * 0.5), halo, false, spread)
		else:
			draw_rect(core.grow(spread), halo, true)
	if _outline:
		draw_rect(core, color, false, 2.0)
	else:
		draw_rect(core, color.lightened(0.3), true)
