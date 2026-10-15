# test_ui_scale_window_geometry.gd
# Pure logic behind the UI scale setting, remembered window geometry and export notifications:
#   _ui.factor_for_choice, WindowGeometry.clamp_to_area / screen_for / fills_area,
#   Notifier (silent in test mode), the registered appearance/ui_scale setting.
# Not covered: real windows, the OS scale, notify-send (visual / manual checks).
# Run: godot --headless --path Godot -s tests/test_ui_scale_window_geometry.gd -- --test
extends TestBase


func suite_name() -> String:
	return "UI scale and window geometry"


var _ui: Node


func run_tests() -> void:
	_ui = root.get_node("UiScale")  # autoloads are not bare identifiers in a SceneTree script
	_test_scale_choices()
	_test_clamp()
	_test_screen_for()
	_test_notifier()
	_test_setting()


func _test_scale_choices() -> void:
	_assert(is_equal_approx(_ui.factor_for_choice("150%", 1.0), 1.5), "150% -> 1.5")
	_assert(is_equal_approx(_ui.factor_for_choice("75%", 2.0), 0.75), "75% ignores the OS scale")
	_assert(is_equal_approx(_ui.factor_for_choice("Auto", 1.25), 1.25), "Auto uses the OS scale")
	_assert(is_equal_approx(_ui.factor_for_choice("bogus", 1.0), 1.0), "unknown choice falls back to Auto")
	_assert(is_equal_approx(_ui.factor_for_choice("Auto", 99.0), _ui.MAX_FACTOR), "Auto is clamped")


func _test_clamp() -> void:
	var area := Rect2i(0, 0, 1920, 1080)
	var inside := Rect2i(100, 100, 800, 600)
	_assert(WindowGeometry.clamp_to_area(inside, area) == inside, "a window inside the screen is kept")
	var off := Rect2i(3000, -50, 800, 600)
	var fitted := WindowGeometry.clamp_to_area(off, area)
	_assert(area.encloses(fitted) and fitted.size == off.size, "an off-screen window is pulled back")
	var huge := WindowGeometry.clamp_to_area(Rect2i(0, 0, 5000, 4000), area)
	_assert(huge.size == area.size, "an oversized window shrinks to the screen")
	var tiny := WindowGeometry.clamp_to_area(Rect2i(0, 0, 300, 200), area, Vector2i(1280, 700))
	_assert(tiny.size == Vector2i(1280, 700), "the minimum size is respected")
	var small_screen := Rect2i(0, 0, 1024, 600)
	var limited := WindowGeometry.clamp_to_area(Rect2i(0, 0, 300, 200), small_screen, Vector2i(1280, 700))
	_assert(limited.size == small_screen.size, "the screen wins over the minimum size")
	_assert(WindowGeometry.fills_area(Rect2i(0, 0, 1920, 1080), area), "full-screen rect fills the area")
	_assert(not WindowGeometry.fills_area(inside, area), "a smaller rect does not")


func _test_screen_for() -> void:
	var screens: Array[Rect2i] = [Rect2i(0, 0, 1920, 1080), Rect2i(1920, 0, 1920, 1080)]
	_assert(WindowGeometry.screen_for(Rect2i(2000, 100, 800, 600), screens, 0) == 1, "centre decides the screen")
	_assert(WindowGeometry.screen_for(Rect2i(9000, 100, 800, 600), screens, 1) == 1, "falls back to the saved screen")
	_assert(WindowGeometry.screen_for(Rect2i(9000, 100, 800, 600), screens, 7) == -1, "unknown screen gives -1")


func _test_notifier() -> void:
	_assert(not Notifier.should_notify(), "no notification in test mode")
	Notifier.notify("title", "body")  # must be a silent no-op here
	var args := Notifier.notify_args("Sonara", "Export finished", "1 file written")
	_assert(args == PackedStringArray(["--app-name=Sonara", "--", "Export finished", "1 file written"]), "notify-send arguments")
	_assert(WindowGeometry.disabled(), "geometry is not saved or restored in test mode")


func _test_setting() -> void:
	var settings: Node = root.get_node("Settings")
	var s = settings.get_setting("appearance/ui_scale")
	_assert(s != null and s.default == "Auto", "appearance/ui_scale defaults to Auto")
	_assert("200%" in s.options and "75%" in s.options, "scale steps are offered")
	_assert(is_equal_approx(_ui.factor(), 1.0), "factor is 1.0 in test mode")
