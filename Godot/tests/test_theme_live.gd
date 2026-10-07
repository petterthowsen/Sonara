# test_theme_live.gd
# A theme setting change restyles live controls (REQ-002, 013, 018): resolved defaults, explicit
# overrides surviving a change, fixed meter colours, and one rebuild per frame.
# Run: godot --headless --path Godot -s tests/test_theme_live.gd -- --test
extends TestBase

const NEW_ACCENT := "#12ab34"

# Autoloads do not resolve as bare identifiers in a SceneTree script.
var _settings: Node
var _ui_theme: Node


func suite_name() -> String:
	return "Theme live tests"


func run_tests() -> void:
	_settings = root.get_node("Settings")
	_ui_theme = root.get_node("UiTheme")
	await _test_component_defaults()
	await _test_override_survives()
	await _test_meters()
	await _test_coalescing()
	_settings.reset_theme()
	await process_frame


## Waits for the coalesced rebuild (deferred) plus one frame for the redraw.
func _settle() -> void:
	await process_frame
	await process_frame


func _accent() -> Color:
	return UiColors.role(&"accent_primary")


func _test_component_defaults() -> void:
	var knob := RotaryKnob.new()
	var fader := Fader.new()
	var seg := SegmentedControl.new()
	root.add_child(knob)
	root.add_child(fader)
	root.add_child(seg)
	await _settle()
	_assert(knob.value_arc_color == _accent(), "the knob arc defaults to the accent")
	_assert(fader.fill_color == _accent(), "the fader fill defaults to the accent")
	_assert(seg.selected_color == _accent(), "the selected segment defaults to the accent")

	_settings.set_value("appearance/theme/accent_primary", NEW_ACCENT)
	await _settle()
	var want := Color(NEW_ACCENT)
	_assert(_accent().is_equal_approx(want), "the Sonara role follows the setting")
	_assert(knob.value_arc_color.is_equal_approx(want), "the knob arc follows an accent change")
	_assert(fader.fill_color.is_equal_approx(want), "the fader fill follows an accent change")
	_assert(seg.selected_color.is_equal_approx(want), "the selected segment follows an accent change")
	knob.queue_free()
	fader.queue_free()
	seg.queue_free()
	_settings.reset_theme()
	await _settle()


func _test_override_survives() -> void:
	var knob := RotaryKnob.new()
	root.add_child(knob)
	knob.value_arc_color = Color.RED
	await _settle()
	_assert(knob.value_arc_color == Color.RED, "an explicit colour is returned")
	_settings.set_value("appearance/theme/accent_primary", NEW_ACCENT)
	await _settle()
	_assert(knob.value_arc_color == Color.RED, "an explicit colour survives an accent change")
	_assert(knob.value_arc_bg == UiColors.role(&"control_bg"), "other items still follow the theme")
	knob.queue_free()
	_settings.reset_theme()
	await _settle()


func _test_meters() -> void:
	var meter := LevelMeter.new()
	root.add_child(meter)
	await _settle()
	_settings.set_value("appearance/theme/accent_primary", NEW_ACCENT)
	await _settle()
	_assert(meter.safe_color.is_equal_approx(Color(NEW_ACCENT)), "the meter's safe zone follows the accent")
	_assert(meter.warn_color == UiColors.METER_WARN, "the warn colour stays fixed")
	_assert(meter.clip_color == UiColors.METER_CLIP, "the clip colour stays fixed")
	meter.queue_free()
	_settings.reset_theme()
	await _settle()


func _test_coalescing() -> void:
	await _settle()
	var counter := {"n": 0}
	var on_applied := func() -> void: counter["n"] += 1
	_ui_theme.theme_applied.connect(on_applied)
	for i in 10:
		_settings.set_value("appearance/theme/accent_primary", Color.from_hsv(i / 10.0, 0.6, 0.6).to_html(false))
	await _settle()
	_ui_theme.theme_applied.disconnect(on_applied)
	_assert(counter["n"] == 1, "ten changes in one frame cause one rebuild (got %d)" % counter["n"])
