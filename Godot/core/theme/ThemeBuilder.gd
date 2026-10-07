@tool
## Turns a `ThemePalette` into a complete `Theme`. Everything Sonara looks like comes from here:
## the Godot control types, the semantic type variations scenes refer to (`SectionPanel`,
## `DeviceCard`, `Well`, …), the custom `Sonara` type that carries the palette roles and the
## component types custom-drawn controls read their colours from.
##
## Anything not set here falls back to Godot's default theme. See `docs/specs/024-theme-system/`.
class_name ThemeBuilder extends RefCounted

const FONT_PATH := "res://assets/fonts/OpenSans-SemiBold.woff2"
const FONT_SIZE := 14
const HEADER_SIZES := {&"HeaderSmall": 20, &"HeaderMedium": 24, &"HeaderLarge": 28}

## Custom theme type holding every palette role plus the `unit` and `radius` constants.
const ROLE_TYPE := &"Sonara"

## Semantic variations: name -> base type. Scenes use these names; the look is set below.
const VARIATIONS := {
	&"SectionPanel": &"PanelContainer",
	&"SectionHeader": &"PanelContainer",
	&"SectionStack": &"VBoxContainer",
	&"AppRoot": &"MarginContainer",
	&"DeviceCard": &"PanelContainer",
	&"DeviceCardSelected": &"DeviceCard",
	&"DeviceCardHeader": &"PanelContainer",
	&"Well": &"PanelContainer",
	&"Floating": &"PanelContainer",
	&"ContextMenu": &"PopupPanel",
	&"ContextMenuList": &"PopupMenu",
	&"FlatButton": &"Button",
	&"FlatMenuButton": &"MenuButton",
	&"RecordButton": &"Button",
	&"SoloButton": &"Button",
	&"MuteButton": &"Button",
	&"HeaderSmall": &"Label",
	&"HeaderMedium": &"Label",
	&"HeaderLarge": &"Label",
}


static func build(p: ThemePalette) -> Theme:
	var t := Theme.new()
	_defaults(t, p)
	_role_type(t, p)
	_containers(t, p)
	_panels(t, p)
	_buttons(t, p)
	_inputs(t, p)
	_popups(t, p)
	_lists(t, p)
	_tabs(t, p)
	_scrolling(t, p)
	_separators(t, p)
	_rich_text(t, p)
	_components(t, p)
	_variations(t, p)
	return t


# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

## A rounded `StyleBoxFlat`. *margin_h* / *margin_v* are the content margins in pixels; *margin_v*
## defaults to *margin_h*.
static func box(p: ThemePalette, bg: Color, margin_h: float = 0.0, margin_v: float = -1.0,
		border: Color = Color(0, 0, 0, 0), border_width: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(p.radius)
	s.corner_detail = 4
	if border_width > 0:
		s.border_color = border
		s.set_border_width_all(border_width)
	s.content_margin_left = margin_h
	s.content_margin_right = margin_h
	var v := margin_h if margin_v < 0.0 else margin_v
	s.content_margin_top = v
	s.content_margin_bottom = v
	return s


static func _with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)


static func _set_styles(t: Theme, type: StringName, styles: Dictionary) -> void:
	for name in styles:
		t.set_stylebox(name, type, styles[name])


static func _set_colors(t: Theme, type: StringName, colors: Dictionary) -> void:
	for name in colors:
		t.set_color(name, type, colors[name])


static func _set_constants(t: Theme, type: StringName, constants: Dictionary) -> void:
	for name in constants:
		t.set_constant(name, type, constants[name])


# ---------------------------------------------------------------------------
# DEFAULTS AND ROLES
# ---------------------------------------------------------------------------

static func _defaults(t: Theme, _p: ThemePalette) -> void:
	var font = load(FONT_PATH)
	if font != null:
		t.default_font = font
	t.default_font_size = FONT_SIZE
	for name in HEADER_SIZES:
		t.set_font_size(&"font_size", name, HEADER_SIZES[name])


## Every palette role as a colour of the `Sonara` type, plus `unit` and `radius`.
static func _role_type(t: Theme, p: ThemePalette) -> void:
	for name in p.roles:
		t.set_color(name, ROLE_TYPE, p.roles[name])
	t.set_constant(&"unit", ROLE_TYPE, p.unit)
	t.set_constant(&"radius", ROLE_TYPE, p.radius)


# ---------------------------------------------------------------------------
# GODOT BASE TYPES
# ---------------------------------------------------------------------------

static func _containers(t: Theme, p: ThemePalette) -> void:
	for type in [&"BoxContainer", &"HBoxContainer", &"VBoxContainer"]:
		t.set_constant(&"separation", type, p.unit)
	for type in [&"GridContainer", &"FlowContainer", &"HFlowContainer", &"VFlowContainer"]:
		t.set_constant(&"h_separation", type, p.unit)
		t.set_constant(&"v_separation", type, p.unit)
	for type in [&"SplitContainer", &"HSplitContainer", &"VSplitContainer"]:
		_set_constants(t, type, {&"separation": 2 * p.unit, &"minimum_grab_thickness": 6, &"autohide": 1})
		t.set_stylebox(&"split_bar_background", type, StyleBoxEmpty.new())
	for side in [&"margin_left", &"margin_top", &"margin_right", &"margin_bottom"]:
		t.set_constant(side, &"MarginContainer", 0)
	t.set_color(&"touch_dragger_color", &"SplitContainer", Color(1, 1, 1, 0.3))
	t.set_color(&"touch_dragger_hover_color", &"SplitContainer", Color(1, 1, 1, 0.6))
	t.set_color(&"touch_dragger_pressed_color", &"SplitContainer", Color(1, 1, 1, 1))


static func _panels(t: Theme, p: ThemePalette) -> void:
	# Nested panels darken progressively: a translucent black over the parent (REQ-008).
	var nest := box(p, p.role(&"nest_overlay"))
	t.set_stylebox(&"panel", &"Panel", nest)
	t.set_stylebox(&"panel", &"PanelContainer", nest.duplicate())
	var floating := floating_box(p)
	t.set_stylebox(&"panel", &"PopupPanel", floating)
	t.set_stylebox(&"panel", &"TooltipPanel", floating.duplicate())
	var dialog := box(p, p.role(&"floating"), 4 * p.unit)
	t.set_stylebox(&"panel", &"AcceptDialog", dialog)
	t.set_constant(&"buttons_separation", &"AcceptDialog", 10)
	var empty := StyleBoxEmpty.new()
	t.set_stylebox(&"normal", &"Label", empty)
	t.set_stylebox(&"focus", &"Label", empty.duplicate())


static func floating_box(p: ThemePalette) -> StyleBoxFlat:
	return box(p, p.role(&"floating"), 2 * p.unit, -1.0, p.role(&"border"), 1)


## Normal / hover / pressed / hover-pressed / disabled / focus styles for a button-like type.
static func _button_styles(t: Theme, type: StringName, p: ThemePalette, pressed: Color) -> void:
	var m := 2.0 * p.unit
	var disabled := p.role(&"control_bg")
	disabled.a = 0.5
	_set_styles(t, type, {
		&"normal": box(p, p.role(&"control_bg"), m),
		&"hover": box(p, p.role(&"control_hover"), m),
		&"pressed": box(p, pressed, m),
		&"hover_pressed": box(p, pressed.lightened(0.12), m),
		&"disabled": box(p, disabled, m),
		&"focus": StyleBoxEmpty.new(),
	})
	_set_colors(t, type, {
		&"font_color": p.role(&"text"),
		&"font_hover_color": p.role(&"text_bright"),
		&"font_focus_color": p.role(&"text_bright"),
		&"font_pressed_color": p.role(&"text_bright"),
		&"font_hover_pressed_color": p.role(&"text_bright"),
		&"font_disabled_color": p.role(&"text_disabled"),
	})


static func _buttons(t: Theme, p: ThemePalette) -> void:
	for type in [&"Button", &"MenuButton", &"OptionButton", &"ColorPickerButton"]:
		_button_styles(t, type, p, p.role(&"accent_primary"))
	# MenuBar styles each top-level menu like a button.
	_button_styles(t, &"MenuBar", p, p.role(&"accent_primary"))
	for type in [&"LinkButton", &"CheckBox", &"CheckButton"]:
		t.set_stylebox(&"focus", type, StyleBoxEmpty.new())
		t.set_color(&"font_color", type, p.role(&"text"))
	t.set_stylebox(&"preset_focus", &"ColorPresetButton", StyleBoxEmpty.new())


static func _inputs(t: Theme, p: ThemePalette) -> void:
	var well := p.role(&"well")
	var read_only := _with_alpha(well, 0.5)
	for type in [&"LineEdit", &"TextEdit", &"CodeEdit"]:
		_set_styles(t, type, {
			&"normal": box(p, well, 2 * p.unit, -1.0, p.role(&"border"), 1),
			&"focus": box(p, well, 2 * p.unit, -1.0, p.role(&"accent_primary"), 1),
			&"read_only": box(p, read_only, 2 * p.unit, -1.0, p.role(&"border"), 1),
		})
		_set_colors(t, type, {
			&"font_color": p.role(&"text"),
			&"font_placeholder_color": p.role(&"text_dim"),
			&"font_uneditable_color": p.role(&"text_dim"),
			&"caret_color": p.role(&"text_bright"),
			&"selection_color": _with_alpha(p.role(&"accent_primary"), 0.5),
		})
	# SpinBox's arrows share the button look; its field uses the LineEdit styles.
	for dir in [&"up", &"down"]:
		t.set_stylebox(String(dir) + "_background", &"SpinBox", StyleBoxEmpty.new())
		t.set_stylebox(String(dir) + "_background_hovered", &"SpinBox", box(p, p.role(&"control_hover"), 2 * p.unit))
		t.set_stylebox(String(dir) + "_background_pressed", &"SpinBox", box(p, p.role(&"accent_primary"), 2 * p.unit))
		t.set_stylebox(String(dir) + "_background_disabled", &"SpinBox", StyleBoxEmpty.new())
	t.set_icon(&"updown", &"SpinBox", ImageTexture.new())


static func _popups(t: Theme, p: ThemePalette) -> void:
	var item_pad := 2 * p.unit
	_set_styles(t, &"PopupMenu", {
		&"panel": floating_box(p),
		&"hover": box(p, _with_alpha(p.role(&"accent_primary"), 0.45), 0.0),
	})
	_set_colors(t, &"PopupMenu", {
		&"font_color": p.role(&"text"),
		&"font_hover_color": p.role(&"text_bright"),
		&"font_disabled_color": p.role(&"text_disabled"),
		&"font_accelerator_color": p.role(&"text_dim"),
		&"font_separator_color": p.role(&"text_dim"),
	})
	_check_icons(t, &"PopupMenu")
	_check_icons(t, &"CheckBox")
	_set_constants(t, &"PopupMenu", {
		&"h_separation": item_pad,
		&"v_separation": item_pad,
		&"indent": 10,
		&"item_start_padding": item_pad,
		&"item_end_padding": item_pad,
	})


## Opaque white check and radio marks. Godot's default marks are dim grey and nearly vanish on
## the dark popup background (the unchecked ones especially).
static func _check_icons(t: Theme, type: StringName) -> void:
	var icons := {
		&"checked": "check_checked", &"unchecked": "check_unchecked",
		&"radio_checked": "radio_checked", &"radio_unchecked": "radio_unchecked",
	}
	for item in icons:
		var tex := load("res://assets/icons/%s.svg" % icons[item]) as Texture2D
		t.set_icon(item, type, tex)


static func _lists(t: Theme, p: ThemePalette) -> void:
	var selected := box(p, _with_alpha(p.role(&"accent_primary"), 0.35))
	var hovered := box(p, _with_alpha(p.role(&"control_hover"), 0.5))
	for type in [&"ItemList", &"Tree"]:
		_set_styles(t, type, {
			&"panel": box(p, p.role(&"well"), p.unit, -1.0, p.role(&"border"), 1),
			&"focus": StyleBoxEmpty.new(),
			&"cursor": StyleBoxEmpty.new(),
			&"cursor_unfocused": StyleBoxEmpty.new(),
			&"selected": selected.duplicate(),
			&"selected_focus": selected.duplicate(),
			&"hovered": hovered.duplicate(),
		})
		_set_colors(t, type, {
			&"font_color": p.role(&"text"),
			&"font_selected_color": p.role(&"text_bright"),
			&"font_hovered_color": p.role(&"text_bright"),
		})
	# Tree buttons (the small buttons inside rows) follow the button look.
	_set_styles(t, &"Tree", {
		&"button_hover": box(p, p.role(&"control_hover"), 2 * p.unit),
		&"button_pressed": box(p, p.role(&"accent_primary"), 2 * p.unit),
		&"custom_button": box(p, p.role(&"control_bg"), 2 * p.unit),
		&"custom_button_hover": box(p, p.role(&"control_hover"), 2 * p.unit),
		&"custom_button_pressed": box(p, p.role(&"accent_primary"), 2 * p.unit),
	})


static func _tabs(t: Theme, p: ThemePalette) -> void:
	var m := 3.0 * p.unit
	var v := 2.0 * p.unit
	for type in [&"TabBar", &"TabContainer"]:
		_set_styles(t, type, {
			&"tab_selected": box(p, p.role(&"card"), m, v),
			&"tab_unselected": box(p, p.role(&"section_header"), m, v),
			&"tab_hovered": box(p, p.role(&"control_hover"), m, v),
			&"tab_disabled": box(p, _with_alpha(p.role(&"section_header"), 0.5), m, v),
			&"tab_focus": StyleBoxEmpty.new(),
		})
		_set_colors(t, type, {
			&"font_selected_color": p.role(&"text_bright"),
			&"font_unselected_color": p.role(&"text_dim"),
			&"font_hovered_color": p.role(&"text_bright"),
			&"font_disabled_color": p.role(&"text_disabled"),
		})
	_set_styles(t, &"TabContainer", {
		&"panel": box(p, p.role(&"card"), p.unit),
		&"tabbar_background": StyleBoxEmpty.new(),
	})
	t.set_stylebox(&"button_pressed", &"TabBar", box(p, p.role(&"accent_primary"), 2 * p.unit))
	t.set_stylebox(&"button_highlight", &"TabBar", box(p, p.role(&"control_hover"), 2 * p.unit))


static func _scrolling(t: Theme, p: ThemePalette) -> void:
	var m := 2.0 * p.unit
	for type in [&"HScrollBar", &"VScrollBar"]:
		_set_styles(t, type, {
			&"scroll": box(p, _with_alpha(p.role(&"well"), 0.6), m),
			&"scroll_focus": StyleBoxEmpty.new(),
			&"grabber": box(p, p.role(&"control_hover"), m),
			&"grabber_highlight": box(p, p.role(&"control_hover").lightened(0.2), m),
			&"grabber_pressed": box(p, p.role(&"accent_primary"), m),
		})
		# The arrow buttons stay hidden: an empty texture takes no space.
		for icon in [&"increment", &"increment_highlight", &"increment_pressed",
				&"decrement", &"decrement_highlight", &"decrement_pressed"]:
			t.set_icon(icon, type, ImageTexture.new())
	for type in [&"HSlider", &"VSlider"]:
		_set_styles(t, type, {
			&"slider": box(p, p.role(&"well"), m),
			&"grabber_area": box(p, p.role(&"accent_primary"), m),
			&"grabber_area_highlight": box(p, p.role(&"accent_primary").lightened(0.15), m),
		})


static func _separators(t: Theme, p: ThemePalette) -> void:
	var m := 2 * p.unit
	var h := StyleBoxLine.new()
	h.color = p.role(&"border")
	h.content_margin_left = m
	h.content_margin_right = m
	h.content_margin_top = 0.0
	h.content_margin_bottom = 0.0
	t.set_stylebox(&"separator", &"HSeparator", h)
	var v := StyleBoxLine.new()
	v.color = p.role(&"border")
	v.vertical = true
	v.content_margin_top = m
	v.content_margin_bottom = m
	v.content_margin_left = 0.0
	v.content_margin_right = 0.0
	t.set_stylebox(&"separator", &"VSeparator", v)
	for name in [&"separator", &"labeled_separator_left", &"labeled_separator_right"]:
		t.set_stylebox(name, &"PopupMenu", h.duplicate())


static func _rich_text(t: Theme, _p: ThemePalette) -> void:
	var font = t.default_font
	if font == null:
		return
	var bold := FontVariation.new()
	bold.base_font = font
	bold.variation_embolden = 1.2
	var italics := FontVariation.new()
	italics.base_font = font
	italics.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)
	var bold_italics := FontVariation.new()
	bold_italics.base_font = font
	bold_italics.variation_embolden = 1.2
	bold_italics.variation_transform = italics.variation_transform
	t.set_font(&"bold_font", &"RichTextLabel", bold)
	t.set_font(&"italics_font", &"RichTextLabel", italics)
	t.set_font(&"bold_italics_font", &"RichTextLabel", bold_italics)
	t.set_icon(&"horizontal_rule", &"RichTextLabel", ImageTexture.new())


# ---------------------------------------------------------------------------
# COMPONENT TYPES
# ---------------------------------------------------------------------------

## Colour items for the custom-drawn controls, one theme type per control. Item names are the
## control's colour property without the `_color` suffix (the `Ruler` type keeps its older names).
## Each control caches these on NOTIFICATION_THEME_CHANGED.
static func _components(t: Theme, p: ThemePalette) -> void:
	var accent := p.role(&"accent_primary")
	var handle := p.role(&"handle")
	var well := p.role(&"well")
	var track := p.role(&"control_bg")
	var border := p.role(&"border")

	_set_colors(t, &"RotaryKnob", {
		&"knob": p.role(&"control_hover"),
		&"shadow": well,
		&"knob_line": handle,
		&"value_arc_bg": track,
		&"value_arc": accent,
	})
	_set_colors(t, &"Fader", {
		&"fill": accent,
		&"track": well,
		&"handle": handle,
		&"overlay": _with_alpha(handle, 0.55),
	})
	for type in [&"VolumeSlider", &"HorSlider"]:
		_set_colors(t, type, {&"bg": well, &"fill": accent, &"handle": handle})
	_set_colors(t, &"HDualSlider", {
		&"bg": well,
		&"fill": accent,
		&"alt_fill": p.role(&"accent_secondary"),
		&"handle": handle,
	})
	_set_colors(t, &"Meter", {
		&"bar_bg": well,
		&"bar_low": accent,
		&"bar_high": p.role(&"meter_warn"),
		&"bar_clip": p.role(&"meter_clip"),
		&"tick": _with_alpha(p.role(&"text"), 0.5),
		&"tick_minor": _with_alpha(p.role(&"text"), 0.25),
		&"zero_db": _with_alpha(p.role(&"text_bright"), 0.75),
		&"fader": accent,
		&"fader_bg": well,
		&"fader_handle": handle,
		&"fader_handle_hover": Color.WHITE,
	})
	_set_colors(t, &"LevelMeter", {
		&"safe": accent,
		&"warn": p.role(&"meter_warn"),
		&"clip": p.role(&"meter_clip"),
		&"background": well,
		&"hold": UiColors.METER_HOLD,
	})
	_set_colors(t, &"Volumeter", {
		&"bg": well,
		&"handle": handle,
		&"bar_low": accent,
		&"bar_high": p.role(&"meter_warn"),
		&"bar_clip": p.role(&"meter_clip"),
	})
	_set_colors(t, &"LightButton", {&"light": accent, &"bg": track, &"border": border})
	_set_colors(t, &"SegmentedControl", {
		&"selected": accent,
		&"idle": track,
		&"hover": p.role(&"control_hover"),
	})
	_set_colors(t, &"XYSlider", {
		&"handle": handle,
		&"bg": well,
		&"axis_line": border,
		&"value_label": p.role(&"text"),
	})
	_set_colors(t, &"EnvelopeControl", {
		&"bg": well,
		&"line": accent,
		&"grid": p.role(&"grid_line"),
		&"handle": _with_alpha(handle, 0.6),
		&"handle_hover": p.role(&"text_bright"),
	})
	_set_colors(t, &"Ruler", {
		&"bar_line_color": border.lightened(0.55),
		&"beat_line_color": border.lightened(0.3),
		&"subdivision_line_color": border,
		&"start_arrow_color": accent,
	})
	t.set_stylebox(&"normal", &"Ruler", box(p, p.role(&"editor_bg"), -1.0))


# ---------------------------------------------------------------------------
# VARIATIONS
# ---------------------------------------------------------------------------

static func _variations(t: Theme, p: ThemePalette) -> void:
	for name in VARIATIONS:
		t.set_type_variation(name, VARIATIONS[name])
	var u := float(p.unit)
	t.set_stylebox(&"panel", &"SectionPanel", box(p, p.role(&"section"), 2 * u))
	t.set_stylebox(&"panel", &"SectionHeader", box(p, p.role(&"section_header"), u))
	t.set_constant(&"separation", &"SectionStack", 2 * p.unit)
	for side in [&"margin_left", &"margin_top", &"margin_right", &"margin_bottom"]:
		t.set_constant(side, &"AppRoot", 2 * p.unit)
	t.set_stylebox(&"panel", &"DeviceCard", box(p, p.role(&"card"), u, -1.0, p.role(&"border"), 1))
	t.set_stylebox(&"panel", &"DeviceCardSelected", box(p, p.role(&"card"), u, -1.0, p.role(&"border_selected"), 1))
	t.set_stylebox(&"panel", &"DeviceCardHeader", box(p, p.role(&"card_header"), u))
	t.set_stylebox(&"panel", &"Well", box(p, p.role(&"well"), u))
	t.set_stylebox(&"panel", &"Floating", floating_box(p))
	t.set_stylebox(&"panel", &"ContextMenu", floating_box(p))
	t.set_stylebox(&"panel", &"ContextMenuList", floating_box(p))

	# Flat buttons show nothing until pressed, then a dark veil.
	var veil := box(p, Color(0, 0, 0, 0.51), 2 * u)
	for type in [&"FlatButton", &"FlatMenuButton"]:
		_set_styles(t, type, {
			&"normal": StyleBoxEmpty.new(),
			&"hover": StyleBoxEmpty.new(),
			&"disabled": StyleBoxEmpty.new(),
			&"pressed": veil.duplicate(),
		})

	# Status buttons: the pressed background is the status colour, the text contrasts with it.
	for entry in [[&"RecordButton", &"record"], [&"SoloButton", &"solo"], [&"MuteButton", &"mute"]]:
		var bg := p.role(entry[1])
		var text := Utils.contrasting_text_color(bg)
		t.set_stylebox(&"pressed", entry[0], box(p, bg, 2 * u))
		t.set_stylebox(&"hover_pressed", entry[0], box(p, bg.lightened(0.12), 2 * u))
		_set_colors(t, entry[0], {
			&"font_pressed_color": text,
			&"font_hover_pressed_color": text,
		})
