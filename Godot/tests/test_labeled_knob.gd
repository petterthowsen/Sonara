# LabeledKnob display modes: caption only (default), value only, and the value (small font) above
# the caption (normal font), the value text following the knob.
# Run: godot --headless --path Godot -s tests/test_labeled_knob.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Labeled knob"


func run_tests() -> void:
	var knob := LabeledKnob.new()
	knob.text = "Gain"
	knob.knob.min_value = -24.0
	knob.knob.max_value = 24.0
	knob.knob.value_format = "%+.1f"
	knob.knob.unit = "dB"
	_assert(knob.display_mode == LabeledKnob.DisplayMode.LABEL, "caption only is the default")
	_assert(knob.label.visible and not knob.value_label.visible and knob.knob.show_value_tooltip, "the default look is unchanged")

	knob.display_mode = LabeledKnob.DisplayMode.VALUE
	_assert(not knob.label.visible and knob.value_label.visible, "value mode shows only the value")
	_assert(not knob.knob.show_value_tooltip, "the value tooltip would repeat the text")
	knob.knob.value = 6.0
	_assert(knob.value_label.text == "+6.0 dB", "the value text follows the knob: %s" % knob.value_label.text)
	knob.knob.set_value_no_signal(-3.0)
	_assert(knob.value_label.text == "-3.0 dB", "also without a value_changed signal: %s" % knob.value_label.text)

	knob.display_mode = LabeledKnob.DisplayMode.BOTH
	_assert(knob.label.visible and knob.value_label.visible, "both mode shows the value and the caption")
	_assert(knob.get_child(0) == knob.knob and knob.get_child(1) == knob.value_label and knob.get_child(2) == knob.label, "stacked: knob, value, caption")
	_assert(knob.value_label.get_theme_font_size("font_size") < knob.label.get_theme_font_size("font_size"), "the value uses the smaller font")

	knob.display_mode = LabeledKnob.DisplayMode.LABEL
	_assert(knob.label.visible and not knob.value_label.visible and knob.knob.show_value_tooltip, "back to caption only")
	knob.free()
