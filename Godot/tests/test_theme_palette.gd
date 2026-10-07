# test_theme_palette.gd
# Headless tests for ThemePalette: default roles, the main colour clamp, per-key fallback and the
# neutral app background (REQ-001, REQ-003, REQ-004, REQ-022).
# Run: godot --headless --path Godot -s tests/test_theme_palette.gd -- --test
extends TestBase


func suite_name() -> String:
	return "ThemePalette tests"


func run_tests() -> void:
	_test_defaults()
	_test_main_color_clamp()
	_test_fallback()
	_test_app_background_is_neutral()
	_test_derived_from_main()
	_test_defaults_match_settings()


func _test_defaults() -> void:
	var p := ThemePalette.from_settings({})
	_assert(p.unit == 2 and p.radius == 2, "default unit and radius are 2")
	_assert(p.role(&"section").is_equal_approx(Color("#2b2b2b")), "section is the main colour")
	_assert(p.role(&"accent_primary").is_equal_approx(Color("#624d99")), "primary accent default")
	_assert(p.role(&"accent_secondary").is_equal_approx(Color("#36d99e")), "secondary accent default")
	_assert(p.role(&"solo").is_equal_approx(Color("#ffb13b")), "solo default")
	_assert(p.role(&"border_selected").is_equal_approx(Color(0.6, 0.6, 0.6)), "selection border is neutral grey")
	_assert(p.role(&"meter_warn") == UiColors.METER_WARN and p.role(&"meter_clip") == UiColors.METER_CLIP,
		"meter warn and clip are the fixed values")
	for name in [&"app_bg", &"section", &"section_header", &"card", &"card_header", &"well", &"nest_overlay",
			&"floating", &"border", &"border_selected", &"control_bg", &"control_hover", &"text", &"text_dim",
			&"text_disabled", &"editor_bg", &"grid_line", &"handle", &"accent_primary", &"accent_secondary",
			&"record", &"solo", &"mute", &"meter_warn", &"meter_clip"]:
		_assert(p.has_role(name), "role '%s' exists" % name)
	_assert(p.role(&"floating").a < 1.0 and p.role(&"floating").a > 0.9, "floating is slightly translucent")


func _test_main_color_clamp() -> void:
	var light := Color("#c0c0c0")
	var p := ThemePalette.from_settings({"appearance/theme/main_color": "#c0c0c0"})
	var got := p.role(&"section")
	_assert(is_equal_approx(got.v, 0.35), "#c0c0c0 clamps to HSV value 0.35 (got %.3f)" % got.v)
	_assert(is_equal_approx(got.s, light.s) and is_equal_approx(got.h, light.h), "the clamp keeps hue and saturation")
	var tinted := Color.from_hsv(0.6, 0.5, 0.9)
	var q := ThemePalette.from_settings({"main_color": tinted})
	_assert(is_equal_approx(q.role(&"section").h, 0.6) and is_equal_approx(q.role(&"section").s, 0.5),
		"a tinted light colour keeps its hue and saturation")
	var dark := ThemePalette.from_settings({"main_color": "#303030"})
	_assert(dark.role(&"section").is_equal_approx(Color("#303030")), "a dark colour is unchanged")


func _test_fallback() -> void:
	var p := ThemePalette.from_settings({
		"appearance/theme/accent_primary": "not a colour",
		"appearance/theme/corner_radius": 9,
		"appearance/theme/spacing": 0,
	})
	_assert(p.role(&"accent_primary").is_equal_approx(Color("#624d99")), "an invalid colour falls back to its default")
	_assert(p.radius == 2, "radius 9 falls back to the default")
	_assert(p.unit == 2, "spacing 0 falls back to the default")
	_assert(p.role(&"solo").is_equal_approx(Color("#ffb13b")), "other settings are unaffected")
	var edge := ThemePalette.from_settings({"corner_radius": 0, "spacing": 4})
	_assert(edge.radius == 0 and edge.unit == 4, "values on the range edges are accepted")


func _test_app_background_is_neutral() -> void:
	var c := ThemePalette.from_settings({}).role(&"app_bg")
	var spread := maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b))
	_assert(spread <= 0.01, "app_bg has no tint at the defaults (spread %.4f)" % spread)
	_assert(c.v < 0.12, "app_bg is near-black")


func _test_derived_from_main() -> void:
	var p := ThemePalette.from_settings({"main_color": "#303030"})
	_assert(p.role(&"section").is_equal_approx(Color("#303030")), "section follows the main colour")
	_assert(p.role(&"well").v < p.role(&"section").v, "wells are darker than sections")
	_assert(p.role(&"card").v > p.role(&"section").v, "cards are lighter than sections")
	_assert(p.role(&"app_bg").v < p.role(&"well").v, "the app background is darker than wells")


## Settings registers its theme settings from ThemePalette.DEFAULTS; make sure they stay in step.
func _test_defaults_match_settings() -> void:
	var settings = root.get_node("Settings")
	for name in ThemePalette.DEFAULTS:
		var s = settings.get_setting(ThemePalette.PREFIX + name)
		_assert(s != null and s.default == ThemePalette.DEFAULTS[name], "Settings default for '%s' matches the palette" % name)
