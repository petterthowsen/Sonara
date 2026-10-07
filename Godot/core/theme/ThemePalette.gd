@tool
## The named colours and sizes of the UI theme, derived from the eight `appearance/theme/*`
## settings. A pure function of its input, so it is easy to test: `ThemeBuilder` turns a palette
## into a `Theme`, and `UiTheme` keeps it in sync with `Settings`.
##
## Roles are read with `palette.role(&"accent_primary")`, or from running code through
## `UiColors.role(...)`.
class_name ThemePalette extends RefCounted

## Setting key prefix, kept in step with `Settings.THEME_PREFIX`.
const PREFIX := "appearance/theme/"

## The defaults of the eight settings, keyed by the last part of the setting key. This is the only
## place they are written down: `Settings` registers its theme settings from here.
const DEFAULTS := {
	"main_color": "#2b2b2b",
	"accent_primary": "#624d99",
	"accent_secondary": "#36d99e",
	"record_color": "#d43c3c",
	"solo_color": "#ffb13b",
	"mute_color": "#5c6670",
	"corner_radius": 2,
	"spacing": 2,
}
const RADIUS_RANGE := Vector2i(0, 4)
const SPACING_RANGE := Vector2i(1, 4)
## Highest HSV value the main colour may have (REQ-022); light mode isn't supported.
const MAX_MAIN_VALUE := 0.35

## Neutral selection border, the same on every selectable item (REQ-012).
const BORDER_SELECTED := Color(0.6, 0.6, 0.6)

## Base spacing unit in pixels.
var unit: int = 2
## Corner radius in pixels.
var radius: int = 2
## Role name -> Color.
var roles: Dictionary = {}


## Build a palette from *values*, a dictionary of setting key (`appearance/theme/main_color`) or
## short name (`main_color`) -> value. A missing or invalid entry uses its default and logs a
## warning when it was invalid (REQ-003). `{}` gives the default palette.
static func from_settings(values: Dictionary) -> ThemePalette:
	var p := ThemePalette.new()
	var main := _color_value(values, "main_color")
	main = clamp_main(main)
	var primary := _color_value(values, "accent_primary")
	var secondary := _color_value(values, "accent_secondary")
	p.unit = _int_value(values, "spacing", SPACING_RANGE)
	p.radius = _int_value(values, "corner_radius", RADIUS_RANGE)

	var app_bg := main.darkened(0.6)
	var r := p.roles
	r[&"app_bg"] = app_bg
	r[&"section"] = main
	r[&"section_header"] = main.darkened(0.15)
	r[&"card"] = main.lightened(0.05)
	r[&"card_header"] = main.lightened(0.10)
	r[&"well"] = main.darkened(0.35)
	r[&"nest_overlay"] = Color(0, 0, 0, 0.15)
	var floating := main.darkened(0.45)
	floating.a = 0.96
	r[&"floating"] = floating
	r[&"border"] = main.lightened(0.12)
	r[&"border_selected"] = BORDER_SELECTED
	r[&"control_bg"] = main.lightened(0.08)
	r[&"control_hover"] = main.lightened(0.14)
	r[&"text"] = Color(0.875, 0.875, 0.875)
	r[&"text_dim"] = Color(0.6, 0.6, 0.6)
	r[&"text_disabled"] = Color(0.875, 0.875, 0.875, 0.5)
	r[&"text_bright"] = Color(0.95, 0.95, 0.95)
	r[&"editor_bg"] = app_bg
	r[&"grid_line"] = Color(1, 1, 1, 0.06)
	r[&"handle"] = Color.WHITE_SMOKE
	r[&"accent_primary"] = primary
	r[&"accent_secondary"] = secondary
	r[&"record"] = _color_value(values, "record_color")
	r[&"solo"] = _color_value(values, "solo_color")
	r[&"mute"] = _color_value(values, "mute_color")
	r[&"meter_warn"] = UiColors.METER_WARN
	r[&"meter_clip"] = UiColors.METER_CLIP
	return p


func role(name: StringName) -> Color:
	if not roles.has(name):
		push_warning("ThemePalette: unknown role '%s'" % name)
		return Color.MAGENTA
	return roles[name]


func has_role(name: StringName) -> bool:
	return roles.has(name)


## *c* with its HSV value limited to MAX_MAIN_VALUE, keeping hue and saturation.
static func clamp_main(c: Color) -> Color:
	if c.v <= MAX_MAIN_VALUE:
		return c
	return Color.from_hsv(c.h, c.s, MAX_MAIN_VALUE)


static func _lookup(values: Dictionary, name: String):
	if values.has(PREFIX + name):
		return values[PREFIX + name]
	return values.get(name, null)


static func _color_value(values: Dictionary, name: String) -> Color:
	var default := Color.html(DEFAULTS[name])
	var v = _lookup(values, name)
	if v == null:
		return default
	if v is Color:
		return v
	if v is String and Color.html_is_valid(v):
		return Color.html(v)
	push_warning("ThemePalette: invalid colour '%s' for '%s', using the default" % [v, name])
	return default


static func _int_value(values: Dictionary, name: String, bounds: Vector2i) -> int:
	var v = _lookup(values, name)
	if v == null:
		return DEFAULTS[name]
	if (v is int or v is float) and int(v) >= bounds.x and int(v) <= bounds.y:
		return int(v)
	push_warning("ThemePalette: invalid value '%s' for '%s', using the default" % [v, name])
	return DEFAULTS[name]
