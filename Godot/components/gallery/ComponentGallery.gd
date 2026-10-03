@tool
extends PanelContainer


func _ready() -> void:
	var rotary_knob: RotaryKnob = $Flow/KnobCard/RotaryKnob
	var demo_mod_ranges: Array[Dictionary] = [
		{"amount": 0.24, "color": Color("#ef6f9a"), "source": "gallery:lfo", "bipolar": true},
		{"amount": 0.18, "color": Color("#4cc9f0"), "source": "gallery:envelope", "bipolar": false},
	]
	rotary_knob.mod_ranges = demo_mod_ranges
	rotary_knob.mod_live_values = PackedFloat32Array([0.35, 0.72])

	# Controls that normally receive live engine data use fixed demo levels here.
	var level_meter: LevelMeter = $Flow/LevelMeterCard/LevelMeter
	level_meter.push(0, -3.0, -11.0)
	level_meter.push(1, -12.0, -20.0)

	var volumeter: Volumeter = $Flow/VolumeterCard/Volumeter
	volumeter._display_peak = 0.78
	volumeter._display_rms = 0.42
	volumeter.queue_redraw()
	$Flow/SegmentsCard/Segments.set_selected_no_signal(1)
