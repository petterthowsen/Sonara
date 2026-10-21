## One band's strip in the EQ companion view (`EqBandsCompanionView`): the enabled toggle and
## solo button side by side, then the type and (for cuts) slope dropdowns side by side, then the
## Freq, Gain and Q knobs showing their values. The layout lives in `EqBandStrip.tscn`; the view
## instantiates one per band, calls `show_band` and wires the controls.
class_name EqBandStrip extends VBoxContainer

## Band index (0-based) this strip shows.
var band := 0

## Bound when the scene is instantiated, so the strip works before it enters the tree.
var toggle: CheckBox
var solo: Button
var type: OptionButton
var slope: OptionButton
var freq: LabeledKnob
var gain: LabeledKnob
var q: LabeledKnob


func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		toggle = %Toggle
		solo = %SoloButton
		type = %TypeOption
		slope = %SlopeOption
		freq = %FreqKnob
		gain = %GainKnob
		q = %QKnob


## Label the strip for `band_index` and fill its dropdowns (type icons in the band's colour).
func show_band(band_index: int) -> void:
	band = band_index
	var band_color := EqCurveEditor.band_color(band)
	toggle.text = str(band + 1)
	toggle.add_theme_color_override("font_color", band_color)
	solo.tooltip_text = "Listen to band %d only" % (band + 1)
	for i in EqResponse.TYPE_NAMES.size():
		type.add_icon_item(EqTypeIcon.texture(i, band_color), "")
		type.set_item_tooltip(i, EqResponse.TYPE_NAMES[i])
	for i in EqResponse.SLOPE_NAMES.size():
		slope.add_item(EqResponse.SLOPE_NAMES[i].trim_suffix(" dB/oct"))
		slope.set_item_tooltip(i, EqResponse.SLOPE_NAMES[i])
