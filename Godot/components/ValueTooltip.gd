@tool
## Floating value readout for knobs, faders and meters. Top-level and
## click-through, so showing it never affects layout. The host adds it as an
## internal child and repositions it while visible (scroll containers move the host).
class_name ValueTooltip extends PanelContainer

## Gap in pixels between the tooltip and the rect or point it is placed against.
@export var gap := 10.0

var _label: Label


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_level = true
	z_index = 128
	visible = false
	theme_type_variation = &"Floating"
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 12)
	add_child(_label)


## Create a hidden tooltip as an unsaved internal child of `host`.
static func attach(host: Control) -> ValueTooltip:
	var tip := ValueTooltip.new()
	host.add_child(tip, false, Node.INTERNAL_MODE_BACK)
	return tip


func set_font_size(font_size: int) -> void:
	if _label.get_theme_font_size("font_size") != font_size:
		_label.add_theme_font_size_override("font_size", font_size)
		reset_size()


## Plain: no panel, just outlined and shadowed text, for a readout drawn over its own
## control (the mixer pan strip) where a panel would hide the value it describes.
func set_plain(plain: bool) -> void:
	if plain:
		add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		_label.add_theme_constant_override("outline_size", 4)
		_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
		_label.add_theme_constant_override("shadow_offset_x", 1)
		_label.add_theme_constant_override("shadow_offset_y", 1)
	else:
		remove_theme_stylebox_override("panel")
		for c in ["font_outline_color", "font_shadow_color"]:
			_label.remove_theme_color_override(c)
		for c in ["outline_size", "shadow_offset_x", "shadow_offset_y"]:
			_label.remove_theme_constant_override(c)
	reset_size()


func set_text(text: String) -> void:
	if _label.text != text:
		_label.text = text
		reset_size()


## Center above `global_rect`; flips below it when there is no room at the top.
func place_above(global_rect: Rect2) -> void:
	var tip_size := _fit()
	var pos := Vector2(global_rect.get_center().x - tip_size.x * 0.5, global_rect.position.y - tip_size.y - gap)
	if pos.y < 0.0:
		pos.y = global_rect.end.y + gap
	_set_clamped(pos, tip_size)


## Center below `global_rect`; flips above it when there is no room at the bottom.
func place_below(global_rect: Rect2) -> void:
	var tip_size := _fit()
	var pos := Vector2(global_rect.get_center().x - tip_size.x * 0.5, global_rect.end.y + gap)
	if pos.y + tip_size.y > get_viewport_rect().size.y:
		pos.y = global_rect.position.y - tip_size.y - gap
	_set_clamped(pos, tip_size)


## Center on `global_rect`, drawn over it (a plain readout on its own control).
func place_over(global_rect: Rect2) -> void:
	var tip_size := _fit()
	_set_clamped(global_rect.get_center() - tip_size * 0.5, tip_size)


## Place right of `global_point`, vertically centered on it; flips left at the viewport edge.
func place_right_of(global_point: Vector2) -> void:
	var tip_size := _fit()
	var pos := Vector2(global_point.x + gap, global_point.y - tip_size.y * 0.5)
	if pos.x + tip_size.x > get_viewport_rect().size.x:
		pos.x = global_point.x - gap - tip_size.x
	_set_clamped(pos, tip_size)


func _fit() -> Vector2:
	var tip_size := get_combined_minimum_size()
	size = tip_size
	return tip_size


func _set_clamped(pos: Vector2, tip_size: Vector2) -> void:
	var view_size := get_viewport_rect().size
	pos.x = clampf(pos.x, 0.0, maxf(view_size.x - tip_size.x, 0.0))
	pos.y = clampf(pos.y, 0.0, maxf(view_size.y - tip_size.y, 0.0))
	global_position = pos
