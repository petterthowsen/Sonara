# Badge.gd
# Rounded colored pin with an optional icon and label. Optional glow (soft pulsing halo in the
# badge color) marks it as active; `muted` dims it. Emits `pressed` on left click when `clickable`.
@tool
class_name Badge extends PanelContainer

signal pressed()

const PULSE_SPEED := 2.4

@export var text: String = "":
	set(value):
		text = value
		_refresh()
@export var icon: Texture2D = null:
	set(value):
		icon = value
		_refresh()
@export var color: Color = Color(0.36, 0.6, 0.95):
	set(value):
		color = value
		_refresh()
## Soft halo in `color` that slowly pulses.
@export var glow: bool = false:
	set(value):
		glow = value
		_refresh()
## Dimmed look, e.g. for an excluded or inactive item.
@export var muted: bool = false:
	set(value):
		muted = value
		_refresh()
@export var clickable: bool = false:
	set(value):
		clickable = value
		mouse_default_cursor_shape = CURSOR_POINTING_HAND if clickable else CURSOR_ARROW
@export var font_size: int = 11:
	set(value):
		font_size = value
		_refresh()
@export var icon_size: int = 12:
	set(value):
		icon_size = value
		_refresh()

var _row: HBoxContainer
var _icon_rect: TextureRect
var _label: Label
var _style: StyleBoxFlat
var _phase: float = 0.0


func _init() -> void:
	mouse_filter = MOUSE_FILTER_STOP
	size_flags_vertical = SIZE_SHRINK_CENTER
	_style = StyleBoxFlat.new()
	_style.set_corner_radius_all(999)
	_style.set_border_width_all(1)
	_style.content_margin_left = 7
	_style.content_margin_right = 8
	_style.content_margin_top = 2
	_style.content_margin_bottom = 2
	add_theme_stylebox_override("panel", _style)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 4)
	_row.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(_row, false, INTERNAL_MODE_FRONT)
	_icon_rect = TextureRect.new()
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect.size_flags_vertical = SIZE_SHRINK_CENTER
	_icon_rect.mouse_filter = MOUSE_FILTER_IGNORE
	_row.add_child(_icon_rect)
	_label = Label.new()
	_label.mouse_filter = MOUSE_FILTER_IGNORE
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_row.add_child(_label)
	_refresh()


## Convenience constructor.
static func make(p_text: String, p_color: Color, p_icon: Texture2D = null) -> Badge:
	var badge := Badge.new()
	badge.text = p_text
	badge.color = p_color
	badge.icon = p_icon
	return badge


func _process(delta: float) -> void:
	if not glow or muted:
		set_process(false)
		return
	_phase = fmod(_phase + delta * PULSE_SPEED, TAU)
	var t := 0.5 + 0.5 * sin(_phase)
	_style.shadow_size = int(round(lerpf(3.0, 7.0, t)))
	_style.shadow_color = Color(color, lerpf(0.25, 0.5, t))
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not clickable:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit()
		accept_event()


func _refresh() -> void:
	if _style == null:
		return
	var base := color
	var alpha := 0.45 if muted else 1.0
	_style.bg_color = Color(base.darkened(0.55), 0.55 * alpha)
	_style.border_color = Color(base, 0.9 * alpha)
	if glow and not muted:
		_style.shadow_size = 5
		_style.shadow_color = Color(base, 0.4)
		set_process(true)
	else:
		_style.shadow_size = 0
		set_process(false)
	_icon_rect.texture = icon
	_icon_rect.visible = icon != null
	_icon_rect.custom_minimum_size = Vector2(icon_size, icon_size)
	_icon_rect.modulate = Color(base.lightened(0.35), alpha)
	_label.text = text
	_label.visible = not text.is_empty()
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_color", Color(base.lightened(0.6), alpha))
	queue_redraw()
