@tool
extends PanelContainer


func _ready() -> void:
	# The knob's modulation look comes from its Preview properties (set in the scene).
	# Controls that normally receive live engine data use fixed demo levels here.
	var level_meter: LevelMeter = $Flow/LevelMeterCard/LevelMeter
	level_meter.push(0, -3.0, -11.0)
	level_meter.push(1, -12.0, -20.0)

	var compact: CompactSlider = $Flow/CompactHSliderCard/CompactHSlider
	# Freq formatter, as in tests/test_compact_hslider.gd ("2.4 kHz" for 2400).
	compact.value_text_callback = func(v): return "%.1f kHz" % [v / 1000.0]
	# Modulation look, mirroring the knob card's Preview properties.
	compact.mod_ranges = [{"amount": 0.53, "color": ModDisplay.SOURCE_COLORS[0], "bipolar": false} as Dictionary]
	compact.mod_live_values = PackedFloat32Array([0.5])
	compact.mod_hint_active = true
	compact.mod_hint_color = ModDisplay.SOURCE_COLORS[0]

	var toggles: StepLane = $Flow/StepLaneCard/Toggles
	toggles.set_values_no_signal(PackedFloat32Array([1, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0, 1]))
	toggles.length = 12
	toggles.playhead = 3
	var bars: StepLane = $Flow/StepLaneCard/Bars
	bars.set_values_no_signal(PackedFloat32Array([0, 7, 12, -5, 0, 19, 24, -12, 3, 0, 7, -24, 5, 0, 12, 0]))
	bars.off_mask = 0b100100
	bars.length = 12
	bars.playhead = 3
	bars.set_flash(3, 0.8)

	var volumeter: Volumeter = $Flow/VolumeterCard/Volumeter
	volumeter._display_peak = 0.78
	volumeter._display_rms = 0.42
	volumeter.queue_redraw()
	$Flow/SegmentsCard/Segments.set_selected_no_signal(1)
