@tool
extends PanelContainer


func _ready() -> void:
	# The knob's modulation look comes from its Preview properties (set in the scene).
	# Controls that normally receive live engine data use fixed demo levels here.
	var level_meter: LevelMeter = $Flow/LevelMeterCard/LevelMeter
	level_meter.push(0, -3.0, -11.0)
	level_meter.push(1, -12.0, -20.0)

	var volumeter: Volumeter = $Flow/VolumeterCard/Volumeter
	volumeter._display_peak = 0.78
	volumeter._display_rms = 0.42
	volumeter.queue_redraw()
	$Flow/SegmentsCard/Segments.set_selected_no_signal(1)
