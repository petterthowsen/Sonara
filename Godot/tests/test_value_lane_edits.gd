# Run: godot --headless --path Godot -s tests/test_value_lane_edits.gd -- --test
extends TestBase

const Rig := preload("res://tests/value_lane_rig.gd")

var vel: NoteValueDescriptor
var rel: NoteValueDescriptor


func suite_name() -> String:
	return "Value lane: edits"


func run_tests() -> void:
	vel = NoteValueDescriptors.by_key("vel")
	rel = NoteValueDescriptors.by_key("rel")
	_assert(vel != null and rel != null, "descriptors load")
	if vel == null or rel == null:
		return
	_test_formatter()
	_test_maths()
	_test_transforms()
	await _test_paint()
	await _test_paint_selection_and_updates()
	await _test_offset_scale_line()
	await _test_reset_and_exact()
	await _test_transform_dialog()


func _near(a: float, b: float, eps := 0.0001) -> bool:
	return absf(a - b) < eps


func _test_formatter() -> void:
	_assert(vel.format(100.0 / 127.0) == "100", "100/127 formats as 100")
	_assert(vel.format(100.0 / 127.0, NoteValueDescriptor.DISPLAY_PERCENT) == "79%", "100/127 formats as 79%")
	_assert(_near(vel.parse("64"), 64.0 / 127.0), "parse '64' gives 64/127")
	_assert(_near(vel.parse("50%", NoteValueDescriptor.DISPLAY_PERCENT), 0.5), "parse '50%' gives 0.5")
	_assert(is_nan(vel.parse("abc")), "parse rejects text")
	_assert(_near(vel.parse("500"), 1.0), "parse clamps")
	_assert(vel.anchor == NoteValueDescriptor.Anchor.START and rel.anchor == NoteValueDescriptor.Anchor.END, "anchors: velocity at start, release at end")
	var n := MidiNoteData.new()
	vel.set_value(n, 0.0)
	_assert(_near(vel.get_value(n), MidiNoteData.MIN_VELOCITY), "velocity cannot reach 0")


func _test_maths() -> void:
	_assert(_near(ValueLaneEdits.value_at_y(0.0, 100.0, rel), 1.0), "top of lane is the maximum")
	_assert(_near(ValueLaneEdits.value_at_y(100.0, 100.0, rel), 0.0), "bottom of lane is the minimum")
	_assert(_near(ValueLaneEdits.value_at_y(50.0, 100.0, rel), 0.5), "middle of lane")
	_assert(_near(ValueLaneEdits.value_at_y(-20.0, 100.0, rel), 1.0), "pointer above the lane clamps")
	var o := ValueLaneEdits.offset([0.4, 0.6], 0.2, rel)
	_assert(_near(o[0], 0.6) and _near(o[1], 0.8), "offset +0.2 of 0.4/0.6 gives 0.6/0.8")
	_assert(_near(ValueLaneEdits.offset([0.9], 0.5, rel)[0], 1.0), "offset clamps at the top")
	var s := ValueLaneEdits.scale([0.4, 0.6], 0.5, rel)
	_assert(_near(s[0], 0.2) and _near(s[1], 0.3), "scale by half gives 0.2/0.3")
	var line: Array[float] = []
	for i in 5:
		line.append(ValueLaneEdits.line_value(Vector2(0, 0.2), Vector2(40, 1.0), i * 10.0, rel))
	_assert(_near(line[0], 0.2) and _near(line[2], 0.6) and _near(line[4], 1.0), "line over five stems runs 0.2 to 1.0")
	_assert(ValueLaneEdits.stems_at_x([10.0, 12.0, 30.0], 11.0, 3.0) == [0, 1], "chord: stems within tolerance")


func _test_transforms() -> void:
	var a := NoteValueTransforms.set_all([0.1, 0.9], 0.5, rel)
	_assert(a.size() == 2 and a[0] == 0.5 and a[1] == 0.5, "set_all")
	var sc := NoteValueTransforms.scale_around_mean([0.2, 0.6], 50.0, rel)
	_assert(_near(sc[0], 0.3) and _near(sc[1], 0.5), "scale 50% of 0.2/0.6 gives 0.3/0.5")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var r := NoteValueTransforms.randomize([0.5, 0.5, 0.5, 0.5], 0.1, rng, rel)
	var ok := true
	for v in r:
		ok = ok and v >= 0.4 - 0.0001 and v <= 0.6 + 0.0001
	_assert(ok, "seeded randomize stays within ±0.1")


func _h(rig) -> float:
	return rig.area().size.y


func _y_of(rig, value: float) -> float:
	return rig.area().stem_top(value)


func _test_paint() -> void:
	root.get_node("Sonara").set_config("clip_editor/value_lanes", {})
	var rig = Rig.new(self)
	await rig.build([0, 960, 1920], [0.3, 0.3, 0.3])
	var a = rig.area()
	var x0: float = rig.stem_x_of(0)
	rig.clear_osc()
	rig.drag(a, Vector2(x0, _y_of(rig, 0.8)), [Vector2(x0, _y_of(rig, 0.8))])
	_assert(_near(rig.note(0).velocity, 0.8), "paint sets the stem under the pointer (%s)" % rig.note(0).velocity)
	_assert(_near(rig.note(1).velocity, 0.3) and _near(rig.note(2).velocity, 0.3), "other stems stay put")
	_assert(rig.history.size() == 1, "one undo step for the gesture")
	_assert(rig.osc_updates() == 1, "one update_note for the changed note")
	rig.history[0].undo()
	_assert(_near(rig.note(0).velocity, 0.3), "undo restores the value")
	rig.history[0].do()
	_assert(_near(rig.note(0).velocity, 0.8), "redo applies it again")

	# Dragging across stems paints each one it passes.
	rig.history.clear()
	var x2: float = rig.stem_x_of(2)
	rig.drag(a, Vector2(x0, _y_of(rig, 0.5)), [Vector2((x0 + x2) * 0.5, _y_of(rig, 0.5)), Vector2(x2, _y_of(rig, 0.5))])
	_assert(_near(rig.note(0).velocity, 0.5) and _near(rig.note(1).velocity, 0.5) and _near(rig.note(2).velocity, 0.5), "a drag paints every stem it crosses")
	_assert(rig.history.size() == 1, "still one undo step")
	await rig.cleanup()

	# A chord: two notes at one tick are painted together.
	var chord = Rig.new(self)
	await chord.build([0, 0, 960], [0.3, 0.3, 0.3])
	var cx: float = chord.stem_x_of(0)
	chord.drag(chord.area(), Vector2(cx, _y_of(chord, 0.9)), [Vector2(cx, _y_of(chord, 0.9))])
	_assert(_near(chord.note(0).velocity, 0.9) and _near(chord.note(1).velocity, 0.9), "paint hits every stem of a chord")
	_assert(_near(chord.note(2).velocity, 0.3), "but not the next note")
	await chord.cleanup()


func _test_paint_selection_and_updates() -> void:
	var rig = Rig.new(self)
	await rig.build([0, 960, 1920, 2880, 3840], [0.3, 0.3, 0.3, 0.3, 0.3])
	rig.select([1, 3])
	rig.clear_osc()
	var a = rig.area()
	var x: float = rig.stem_x_of(4)
	a._gui_input(rig.mouse(Vector2(x, _y_of(rig, 0.6)), true))
	_assert(rig.osc_updates() == 0, "nothing is sent to the engine during the gesture")
	a._gui_input(rig.motion(Vector2(x, _y_of(rig, 0.7))))
	_assert(rig.osc_updates() == 0, "still nothing while dragging")
	a._gui_input(rig.mouse(Vector2(x, _y_of(rig, 0.7)), false))
	_assert(_near(rig.note(1).velocity, 0.7) and _near(rig.note(3).velocity, 0.7), "with a selection, paint sets the selected notes")
	_assert(_near(rig.note(0).velocity, 0.3) and _near(rig.note(4).velocity, 0.3), "and only those, wherever the pointer is")
	_assert(rig.osc_updates() == 2, "two update_note sends after the release (%d)" % rig.osc_updates())
	await rig.cleanup()

	var five = Rig.new(self)
	await five.build([0, 960, 1920, 2880, 3840], [0.3, 0.3, 0.3, 0.3, 0.3])
	five.select([0, 1, 2, 3, 4])
	five.clear_osc()
	five.drag(five.area(), Vector2(10, _y_of(five, 0.4)), [Vector2(12, _y_of(five, 0.4))])
	_assert(five.osc_updates() == 5 and five.history.size() == 1, "five notes: five update_note sends, one history entry")
	await five.cleanup()


func _test_offset_scale_line() -> void:
	var rig = Rig.new(self)
	await rig.build([0, 960, 1920, 2880, 3840], [0.4, 0.6, 0.4, 0.6, 0.4])
	var a = rig.area()
	rig.select([0, 1])
	var h := _h(rig)
	# Alt-drag up by 20% of the lane height raises the selection by 20% of the range.
	rig.drag(a, Vector2(50, h * 0.5), [Vector2(50, h * 0.3)], {"alt": true})
	var span: float = vel.max_value - vel.min_value
	_assert(_near(rig.note(0).velocity, 0.4 + 0.2 * span) and _near(rig.note(1).velocity, 0.6 + 0.2 * span), "alt-drag offsets the selection")
	_assert(_near(rig.note(2).velocity, 0.4), "and leaves the rest")
	rig.history.clear()
	rig.note(0).velocity = 0.4
	rig.note(1).velocity = 0.6
	rig.drag(a, Vector2(50, h * 0.5), [Vector2(50, h * 1.0)], {"alt": true, "ctrl": true})
	_assert(_near(rig.note(0).velocity, 0.2) and _near(rig.note(1).velocity, 0.3), "ctrl+alt-drag scales toward zero (%s, %s)" % [rig.note(0).velocity, rig.note(1).velocity])
	_assert(rig.history.size() == 1, "scale is one undo step")

	# Ctrl-drag draws a line over the stems it spans.
	rig.select([])
	rig.midi_editor.note_editor.selection_manager.clear_selection()
	var x0: float = rig.stem_x_of(0)
	var x4: float = rig.stem_x_of(4)
	rig.drag(a, Vector2(x0, _y_of(rig, 0.2)), [Vector2((x0 + x4) * 0.5, _y_of(rig, 0.6)), Vector2(x4, _y_of(rig, 1.0))], {"ctrl": true})
	_assert(_near(rig.note(0).velocity, 0.2, 0.01) and _near(rig.note(4).velocity, 1.0, 0.01) and _near(rig.note(2).velocity, 0.6, 0.02), "ctrl-drag draws a line: %s %s %s" % [rig.note(0).velocity, rig.note(2).velocity, rig.note(4).velocity])
	await rig.cleanup()


func _test_reset_and_exact() -> void:
	var rig = Rig.new(self)
	await rig.build([0, 960], [0.5, 0.5], [0.9, 0.2])
	rig.editor.value_pane.add_lane("rel")
	await process_frame
	var a = rig.area(1)
	var x: float = rig.stem_x_of(0, 1)
	rig.drag(a, Vector2(x, 20), [], {"ctrl": true})
	_assert(_near(rig.note(0).release, 0.5), "ctrl+click resets release to 0.5 (%s)" % rig.note(0).release)
	_assert(_near(rig.note(1).release, 0.2), "only the clicked stem")
	_assert(rig.history.size() == 1, "reset is one undo step")

	var va = rig.area(0)
	var vx: float = rig.stem_x_of(0, 0)
	va._gui_input(rig.mouse(Vector2(vx, 30), true, {}, true))
	var box: FloatingValueEditor = null
	for c in va.get_children():
		if c is FloatingValueEditor:
			box = c
	_assert(box != null, "double-click opens the exact value editor")
	if box:
		box.committed.emit("64")
		_assert(_near(rig.note(0).velocity, 64.0 / 127.0), "typing 64 gives 64/127 (%s)" % rig.note(0).velocity)
	await rig.cleanup()


func _test_transform_dialog() -> void:
	var rig = Rig.new(self)
	await rig.build([0, 960, 1920], [0.2, 0.4, 0.6])
	var lane = rig.lane()
	rig.clear_osc()
	lane.transform_dialog.open_for(0, lane.descriptor)  # Set
	lane.transform_dialog.amount_spin.value = 64
	lane.transform_dialog.get_ok_button().pressed.emit()
	_assert(_near(rig.note(0).velocity, 64.0 / 127.0) and _near(rig.note(2).velocity, 64.0 / 127.0), "Set with no selection acts on every note")
	_assert(rig.history.size() == 1, "one undo step")
	rig.history[0].undo()
	_assert(_near(rig.note(0).velocity, 0.2) and _near(rig.note(2).velocity, 0.6), "undo restores them")
	await rig.cleanup()
