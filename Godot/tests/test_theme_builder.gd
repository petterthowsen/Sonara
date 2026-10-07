# test_theme_builder.gd
# Headless tests for ThemeBuilder: Godot types, variations, spacing, radius, fonts and the
# status buttons (REQ-001, 008, 010, 011, 013, 015, 025), then the component types.
# Run: godot --headless --path Godot -s tests/test_theme_builder.gd -- --test
extends TestBase


func suite_name() -> String:
	return "ThemeBuilder tests"


func _palette(overrides: Dictionary = {}) -> ThemePalette:
	return ThemePalette.from_settings(overrides)


func _flat(t: Theme, item: StringName, type: StringName) -> StyleBoxFlat:
	var s := t.get_stylebox(item, type)
	return s as StyleBoxFlat


func run_tests() -> void:
	_test_font()
	_test_variations_exist()
	_test_radius()
	_test_spacing()
	_test_nest_overlay()
	_test_font_sizes()
	_test_buttons()
	_test_role_type()
	_test_sections_follow_main_color()
	_test_component_types()


func _test_font() -> void:
	var font = load(ThemeBuilder.FONT_PATH)
	_assert(font is FontFile and font.font_name == "Open Sans SemiBold", "the extracted font loads as Open Sans SemiBold")
	var t := ThemeBuilder.build(_palette())
	_assert(t.default_font != null and t.default_font == font, "the theme's default font is Open Sans SemiBold")


func _test_variations_exist() -> void:
	var t := ThemeBuilder.build(_palette())
	for name in ThemeBuilder.VARIATIONS:
		_assert(t.get_type_variation_base(name) == ThemeBuilder.VARIATIONS[name],
			"variation '%s' has base '%s'" % [name, ThemeBuilder.VARIATIONS[name]])
	for name in [&"SectionPanel", &"SectionHeader", &"DeviceCard", &"DeviceCardSelected", &"DeviceCardHeader",
			&"Well", &"Floating", &"ContextMenu", &"ContextMenuList"]:
		_assert(t.has_stylebox(&"panel", name), "'%s' has a panel style" % name)
	_assert(not t.get_type_list().has(&"PrimaryPanel") and not t.get_type_list().has(&"DarkPanel"),
		"PrimaryPanel and DarkPanel are gone")


func _test_radius() -> void:
	for radius in [0, 2, 4]:
		var t := ThemeBuilder.build(_palette({"corner_radius": radius}))
		var checked := 0
		var wrong := 0
		for type in t.get_stylebox_type_list():
			for item in t.get_stylebox_list(type):
				var s := t.get_stylebox(item, type) as StyleBoxFlat
				if s == null:
					continue
				checked += 1
				if s.corner_radius_top_left != radius or s.corner_radius_top_right != radius \
						or s.corner_radius_bottom_left != radius or s.corner_radius_bottom_right != radius:
					wrong += 1
		_assert(checked > 30 and wrong == 0, "radius %d on all %d generated StyleBoxFlats (%d wrong)" % [radius, checked, wrong])


func _test_spacing() -> void:
	for unit in [1, 2, 4]:
		var t := ThemeBuilder.build(_palette({"spacing": unit}))
		_assert(t.get_constant(&"separation", &"VBoxContainer") == unit, "unit %d: box separation" % unit)
		_assert(t.get_constant(&"separation", &"HBoxContainer") == unit, "unit %d: HBox separation" % unit)
		_assert(t.get_constant(&"h_separation", &"GridContainer") == unit, "unit %d: grid separation" % unit)
		_assert(t.get_constant(&"separation", &"SplitContainer") == 2 * unit, "unit %d: split separation is 2 units" % unit)
		_assert(t.get_constant(&"separation", &"SectionStack") == 2 * unit, "unit %d: SectionStack separation is 2 units" % unit)
		_assert(t.get_constant(&"margin_left", &"AppRoot") == 2 * unit, "unit %d: AppRoot margin is 2 units" % unit)
		var section := _flat(t, &"panel", &"SectionPanel")
		_assert(section.content_margin_left == 2 * unit and section.content_margin_top == 2 * unit, "unit %d: section padding is 2 units" % unit)
		var card := _flat(t, &"panel", &"DeviceCard")
		_assert(card.content_margin_left == unit and card.content_margin_bottom == unit, "unit %d: card padding is 1 unit" % unit)
		var well := _flat(t, &"panel", &"Well")
		_assert(well.content_margin_right == unit, "unit %d: well padding is 1 unit" % unit)
		_assert(t.get_constant(&"margin_top", &"MarginContainer") == 0, "unit %d: MarginContainer margins are 0" % unit)
		_assert(t.get_constant(&"unit", &"Sonara") == unit, "unit %d: Sonara/unit constant" % unit)


func _test_nest_overlay() -> void:
	var t := ThemeBuilder.build(_palette())
	for type in [&"Panel", &"PanelContainer"]:
		var s := _flat(t, &"panel", type)
		_assert(s.bg_color.r == 0.0 and s.bg_color.g == 0.0 and s.bg_color.b == 0.0, "%s overlay is black" % type)
		_assert(s.bg_color.a > 0.0 and s.bg_color.a <= 0.25, "%s overlay alpha is in (0, 0.25] (%.2f)" % [type, s.bg_color.a])


func _test_font_sizes() -> void:
	var t := ThemeBuilder.build(_palette())
	_assert(t.default_font_size == 14, "the default font size is 14")
	var extra: Array = []
	for type in t.get_font_size_type_list():
		if not ThemeBuilder.HEADER_SIZES.has(type) and not t.get_font_size_list(type).is_empty():
			extra.append(type)
	_assert(extra.is_empty(), "no per-type font size outside the headers (%s)" % [extra])
	_assert(t.get_font_size(&"font_size", &"HeaderSmall") == 20, "HeaderSmall is 20")
	_assert(t.get_font_size(&"font_size", &"HeaderMedium") == 24, "HeaderMedium is 24")
	_assert(t.get_font_size(&"font_size", &"HeaderLarge") == 28, "HeaderLarge is 28")


func _test_buttons() -> void:
	var p := _palette({"accent_primary": "#aa3355", "record_color": "#ff0000", "solo_color": "#ffff00", "mute_color": "#00ffff"})
	var t := ThemeBuilder.build(p)
	for type in [&"Button", &"MenuButton", &"OptionButton"]:
		_assert(_flat(t, &"pressed", type).bg_color.is_equal_approx(Color("#aa3355")), "%s pressed uses the primary accent" % type)
	_assert(_flat(t, &"normal", &"Button").bg_color.is_equal_approx(p.role(&"control_bg")), "Button normal uses control_bg")
	_assert(_flat(t, &"hover", &"Button").bg_color.is_equal_approx(p.role(&"control_hover")), "Button hover uses control_hover")
	_assert(t.get_stylebox(&"focus", &"Button") is StyleBoxEmpty, "Button focus is an empty box")
	for entry in [[&"RecordButton", "#ff0000"], [&"SoloButton", "#ffff00"], [&"MuteButton", "#00ffff"]]:
		var bg := _flat(t, &"pressed", entry[0]).bg_color
		_assert(bg.is_equal_approx(Color(entry[1])), "%s pressed uses its status colour" % entry[0])
		_assert(t.get_color(&"font_pressed_color", entry[0]) == Utils.contrasting_text_color(bg),
			"%s pressed text contrasts with its background" % entry[0])
	var loop_bg := _flat(t, &"pressed", &"LoopButton").bg_color
	_assert(loop_bg.is_equal_approx(p.role(&"accent_secondary")), "LoopButton pressed uses the secondary accent")
	_assert(_flat(t, &"pressed", &"FlatButton") != null and t.get_stylebox(&"normal", &"FlatButton") is StyleBoxEmpty,
		"FlatButton is empty until pressed")


func _test_role_type() -> void:
	var p := _palette()
	var t := ThemeBuilder.build(p)
	for name in p.roles:
		_assert(t.has_color(name, &"Sonara") and t.get_color(name, &"Sonara") == p.roles[name], "Sonara/%s matches the palette" % name)
	_assert(t.get_constant(&"radius", &"Sonara") == 2, "Sonara/radius")


func _test_sections_follow_main_color() -> void:
	var t := ThemeBuilder.build(_palette({"main_color": "#303030"}))
	_assert(_flat(t, &"panel", &"SectionPanel").bg_color.is_equal_approx(Color("#303030")), "SectionPanel background is the main colour")
	_assert(_flat(t, &"panel", &"DeviceCardSelected").border_color.is_equal_approx(Color(0.6, 0.6, 0.6)),
		"selected card border is the neutral selection colour")
	_assert(_flat(t, &"panel", &"DeviceCard").border_color != _flat(t, &"panel", &"DeviceCardSelected").border_color,
		"selected and unselected card borders differ")


const COMPONENT_TYPES := [&"RotaryKnob", &"Fader", &"VolumeSlider", &"HorSlider", &"HDualSlider", &"Meter",
	&"LevelMeter", &"Volumeter", &"LightButton", &"SegmentedControl", &"XYSlider", &"EnvelopeControl", &"Ruler"]


func _test_component_types() -> void:
	var p := _palette()
	var t := ThemeBuilder.build(p)
	for type in COMPONENT_TYPES:
		_assert(not t.get_color_list(type).is_empty(), "component type '%s' has colour items" % type)
	_assert(t.get_color(&"fill", &"Fader") == p.role(&"accent_primary"), "Fader/fill is the primary accent")
	_assert(t.get_color(&"value_arc", &"RotaryKnob") == p.role(&"accent_primary"), "RotaryKnob/value_arc is the primary accent")
	_assert(t.get_color(&"alt_fill", &"HDualSlider") == p.role(&"accent_secondary"), "HDualSlider/alt_fill is the secondary accent")
	_assert(t.get_color(&"warn", &"LevelMeter") == UiColors.METER_WARN, "LevelMeter/warn is the fixed warning colour")
	_assert(t.get_color(&"clip", &"LevelMeter") == UiColors.METER_CLIP, "LevelMeter/clip is the fixed clip colour")
	_assert(t.get_color(&"safe", &"LevelMeter") == p.role(&"accent_primary"), "LevelMeter/safe is the primary accent")
	_assert(t.get_color(&"bg", &"XYSlider") == p.role(&"well"), "XYSlider/bg is the well colour")
	_assert(t.get_color(&"bg", &"EnvelopeControl") == p.role(&"well"), "EnvelopeControl/bg is the well colour")
	_assert(t.get_color(&"selected", &"SegmentedControl") == p.role(&"accent_primary"), "SegmentedControl/selected is the primary accent")
	_assert(t.has_color(&"bar_line_color", &"Ruler") and t.has_stylebox(&"normal", &"Ruler"), "Ruler keeps its item names")
	# A new accent reaches every component that uses it.
	var q := ThemeBuilder.build(_palette({"accent_primary": "#ff0000"}))
	for entry in [[&"Fader", &"fill"], [&"RotaryKnob", &"value_arc"], [&"Meter", &"fader"], [&"EnvelopeControl", &"line"]]:
		_assert(q.get_color(entry[1], entry[0]).is_equal_approx(Color("#ff0000")), "%s/%s follows the primary accent" % entry)
