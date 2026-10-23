# Metronome popup (spec 053 T-011), shallow: the scene instantiates, a model step change shows in
# the lane with its colour index, the resolution list follows the signature, and the sound knobs
# follow the settings. Logic lives in test_metronome_model.gd.
# Run: godot --headless --path Godot -s tests/test_metronome_popup.gd -- --test
extends TestBase

var _scene: PackedScene
var _m: GDScript


func suite_name() -> String:
	return "Metronome popup"


func run_tests() -> void:
	_scene = load("res://editor/metronome/MetronomePopup.tscn")
	_m = load("res://data/Metronome.gd")
	await _test_instantiates_and_shows_pattern()
	await _test_resolution_list()
	await _test_knobs_follow_settings()
	await _test_playhead_step()


func _make(model: Object) -> Node:
	var popup: Node = _scene.instantiate()
	root.add_child(popup)
	popup.setup(model)
	await process_frame
	return popup


func _test_instantiates_and_shows_pattern() -> void:
	var model = _m.new()
	var popup := await _make(model)
	var lane: StepLane = popup.get_node("%StepLane")
	_assert(lane.step_count == 4 and lane.get_value_at(0) == 4.0 and lane.get_value_at(1) == 2.0, "4/4 shows the default pattern")
	model.set_step(4, 4, 1, 3)
	_assert(lane.get_value_at(1) == 3.0, "a model step change shows in the lane")
	_assert(lane._bar_color_for(1) == UiColors.role(&"metronome_level_3"), "the bar uses the level-3 theme colour")
	_assert(lane._bar_color_for(0) == UiColors.role(&"metronome_level_4"), "level 4 uses the level-4 theme colour")
	var reset: Button = popup.get_node("%ResetButton")
	_assert(not reset.disabled, "Reset is enabled for an edited signature")
	model.reset_pattern(4, 4)
	_assert(lane.get_value_at(1) == 2.0 and reset.disabled, "Reset restores the default and disables itself")
	popup.queue_free()


func _test_resolution_list() -> void:
	var model = _m.new()
	var popup := await _make(model)
	var option: OptionButton = popup.get_node("%ResolutionOption")
	popup.set_signature(7, 8)
	_assert(option.item_count == 2 and option.get_item_text(0) == "1/8" and option.get_item_text(1) == "1/16", "7/8 offers 1/8 and 1/16")
	var lane: StepLane = popup.get_node("%StepLane")
	_assert(lane.step_count == 7 and lane.group_size == 1, "7/8 shows 7 steps")
	popup.set_signature(4, 4)
	_assert(option.item_count == 3 and lane.step_count == 4, "4/4 offers three resolutions")
	popup.set_signature(3, 32)
	_assert(option.disabled and popup.get_node("%HintLabel").visible, "a 32nd-note signature is read-only with a hint")
	popup.queue_free()


func _test_knobs_follow_settings() -> void:
	var model = _m.new()
	var popup := await _make(model)
	var tune: LabeledKnob = popup.get_node("%TuneKnob")
	_assert(is_equal_approx(tune.knob.value, 1000.0), "Tune shows its default")
	model.set_param("metronome/tune", 2000.0)
	_assert(is_equal_approx(tune.knob.value, 2000.0), "a settings change moves the knob")
	tune.knob.value = 500.0
	_assert(is_equal_approx(float(model.get_param("metronome/tune")), 500.0), "moving the knob sets the setting")
	var sound: OptionButton = popup.get_node("%SoundOption")
	_assert(sound.item_count == 2 and sound.get_item_text(1) == "Wood", "Beep and Wood are offered")
	model.set_param("metronome/tune", 1000.0)
	popup.queue_free()


func _test_playhead_step() -> void:
	var model = _m.new()
	var popup := await _make(model)
	var project = load("res://data/Project.gd").new()
	var lane: StepLane = popup.get_node("%StepLane")
	popup.follow_playhead(project, project.ppq, true)
	_assert(lane.playhead == 1, "playing on the second beat highlights step 2")
	popup.follow_playhead(project, project.ppq, false)
	_assert(lane.playhead == -1, "no highlight while stopped")
	popup.queue_free()
