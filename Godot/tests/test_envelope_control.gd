# test_envelope_control.gd
# Headless tests for Envelope (stage subsets, clamping, signals) and EnvelopeControl (geometry
# stays inside the control, stage lengths follow values, handle drags, tooltip text).
# Run: godot --headless --path Godot -s tests/test_envelope_control.gd -- --test
extends TestBase

var _envelope_script: GDScript
var _control_script: GDScript


func suite_name() -> String:
	return "Envelope control tests"


func run_tests() -> void:
	_envelope_script = load("res://support/Envelope.gd")
	_control_script = load("res://components/EnvelopeControl.gd")
	_test_envelope_signals_and_clamping()
	_test_envelope_stages()
	await _test_geometry_inside_and_ordered()
	await _test_subsets_shape()
	await _test_drags()


func _make_envelope(stages := "adsr") -> Resource:
	var env: Resource = _envelope_script.new()
	env.stages = stages
	for stage in [0, 1, 3]:
		env.set_stage_range(stage, 0.0, 1.0)
	env.set_adsr(0.25, 0.25, 0.5, 0.25)
	return env


func _make_control(env: Resource) -> Control:
	var control: Control = _control_script.new()
	control.envelope = env
	# away from the headless pointer at (0, 0)
	control.position = Vector2(300, 300)
	root.add_child(control)
	control.size = Vector2(200, 100)
	return control


func _test_envelope_signals_and_clamping() -> void:
	var env: Resource = _envelope_script.new()
	env.set_stage_range(0, 0.0, 1.0)
	var got: Array[float] = []
	env.attack_changed.connect(func(v: float) -> void: got.append(v))
	env.attack = 5.0
	_assert(got == [1.0], "stage signal carries the clamped value: %s" % [got])
	env.attack = 1.0
	_assert(got.size() == 1, "setting the same value emits nothing")
	env.set_adsr(0.5, 0.1, 0.7, 0.3)
	_assert(got.size() == 1 and env.attack == 0.5, "set_adsr updates without stage signals")


func _test_envelope_stages() -> void:
	var env: Resource = _envelope_script.new()
	env.stages = "RDA x"
	_assert(env.stages == "adr", "stages are normalized to ADSR order: %s" % env.stages)
	_assert(env.has_stage(0) and not env.has_stage(2), "has_stage follows stages")
	var back: Resource = _envelope_script.from_json(env.to_json())
	_assert(back.stages == "adr", "stages survive to_json/from_json")


func _test_geometry_inside_and_ordered() -> void:
	var env := _make_envelope()
	var control := _make_control(env)
	await process_frame
	var bounds := Rect2(Vector2.ZERO, control.size)
	var r: float = control.handle_radius
	var inside := true
	for handle in control.get_handles():
		var p: Vector2 = control.get_handle_position(handle)
		if p.x - r < 0.0 or p.y - r < 0.0 or p.x + r > bounds.end.x or p.y + r > bounds.end.y:
			inside = false
	_assert(inside, "every handle (with its radius) stays inside the control")

	env.set_adsr(1.0, 1.0, 1.0, 1.0)
	var pts: PackedVector2Array = control.get_curve_points()
	_assert(pts[pts.size() - 1].x <= control.size.x - r + 0.01, "max times still end inside the control")
	var ordered := true
	for i in range(pts.size() - 1):
		if pts[i + 1].x < pts[i].x:
			ordered = false
	_assert(ordered, "curve points run left to right")

	env.set_adsr(0.1, 0.4, 0.5, 0.1)
	var ends: Dictionary = control._stage_ends()
	var attack_len: float = ends[0] - control.get_inner_rect().position.x
	var decay_len: float = ends[1] - ends[0]
	_assert(decay_len > attack_len, "longer decay draws longer than a shorter attack")
	env.set_adsr(0.3, 0.3, 0.5, 0.3)
	ends = control._stage_ends()
	var release_len: float = ends[3] - ends[2]
	_assert(is_equal_approx(ends[0] - control.get_inner_rect().position.x, release_len), "equal times draw equal lengths")
	control.queue_free()
	await process_frame


func _test_subsets_shape() -> void:
	var ads := _make_control(_make_envelope("ads"))
	await process_frame
	var pts: PackedVector2Array = ads.get_curve_points()
	_assert(is_equal_approx(pts[pts.size() - 1].x, ads.get_inner_rect().end.x), "ADS: sustain holds to the right edge")
	_assert(ads.get_handles().size() == 2, "ADS: attack and decay handles (decay sets sustain)")

	var asr := _make_control(_make_envelope("asr"))
	await process_frame
	_assert(asr.get_handles().size() == 3, "ASR: attack, sustain and release handles")
	var attack_y: float = asr.get_handle_position(0).y
	_assert(is_equal_approx(attack_y, asr._level_to_y(0.5)), "ASR: attack rises straight to the sustain level")

	var ad := _make_control(_make_envelope("ad"))
	await process_frame
	pts = ad.get_curve_points()
	_assert(pts.size() == 3 and is_equal_approx(pts[2].y, ad.get_inner_rect().end.y), "AD: decays to zero with no plateau")
	_assert(ad.get_handle_text(1) == "Decay 250 ms", "AD: decay tooltip has no sustain part: %s" % ad.get_handle_text(1))
	for c in [ads, asr, ad]:
		c.queue_free()
	await process_frame


func _press(control: Control, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.position = pos
	ev.pressed = pressed
	control._gui_input(ev)


func _move(control: Control, pos: Vector2, shift := false) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.shift_pressed = shift
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	control._gui_input(ev)


func _test_drags() -> void:
	var env := _make_envelope()
	var control := _make_control(env)
	await process_frame
	var released: Array[float] = []
	env.release_changed.connect(func(v: float) -> void: released.append(v))

	# grab the decay handle a few pixels off-center: no jump on press
	var decay_pos: Vector2 = control.get_handle_position(1)
	_press(control, decay_pos + Vector2(3, 2), true)
	_assert(is_equal_approx(env.decay, 0.25), "pressing a handle doesn't move it")
	_assert(control._tooltip != null and control._tooltip.visible, "tooltip shows while dragging")
	_assert(control._tooltip._label.text == "Decay 250 ms · Sustain 50%", "decay tooltip shows decay and sustain: %s" % control._tooltip._label.text)
	_move(control, decay_pos + Vector2(3, 2) + Vector2(0, -20))
	_assert(env.sustain > 0.5 and is_equal_approx(env.decay, 0.25), "dragging the decay handle up raises sustain only")
	var sustain_before: float = env.sustain
	_move(control, decay_pos + Vector2(3, 2) + Vector2(0, -40), true)
	var fine_step: float = env.sustain - sustain_before
	_assert(fine_step > 0.0 and fine_step < sustain_before - 0.5, "shift drag moves less than a normal drag")
	_press(control, decay_pos, false)
	_assert(not control._tooltip.visible, "tooltip hides after the drag when not hovering a handle")

	var release_pos: Vector2 = control.get_handle_position(3)
	_press(control, release_pos, true)
	_move(control, release_pos + Vector2(-500, 0))
	_assert(is_equal_approx(env.release, 0.0), "release drags down to its minimum and no further")
	_assert(released.size() == 1, "release_changed emitted once per change: %s" % [released])
	_press(control, release_pos, false)
	control.queue_free()
	await process_frame
