## One active band's row in the Multiband FX panel (`MultibandDefaultView`): the band's color
## stripe and name, its Mute and Solo toggles and its Gain knob. The layout lives in
## `MultibandBandRow.tscn`; the view instantiates one per active band, wires the controls and
## calls `show_band`.
class_name MultibandBandRow extends PanelContainer

## Band position (1–6) this row shows.
var band := 0

## Bound when the scene is instantiated, so the row works before it enters the tree.
var name_label: Label
var mute: Button
var solo: Button
var gain: RotaryKnob


func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		name_label = %NameLabel
		mute = %MuteButton
		solo = %SoloButton
		gain = %GainKnob


## Show `chain`'s name and device count, tinted with the slot `color`; an `open` slot is brighter.
func show_band(chain: DeviceInstance, color: Color, open: bool) -> void:
	var style := get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	style.bg_color = Color(0.2, 0.2, 0.2, 0.95) if open else Color(0.12, 0.12, 0.12, 0.6)
	style.border_color = color if open else color.darkened(0.3)
	add_theme_stylebox_override("panel", style)
	tooltip_text = ("Hide %s" if open else "Show %s") % chain.get_display_name()
	name_label.text = "%s%s" % [chain.get_display_name(), "  (%d)" % chain.children.size() if not chain.children.is_empty() else ""]
