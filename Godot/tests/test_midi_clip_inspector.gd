# test_midi_clip_inspector.gd
# MIDI clip velocity adjustment (issue 108): VelocityRemap maths, the MidiClipInspector range
# slider (live drag, one undo step per gesture, squashing at the edges) and the vertical row layout.
#
# Run: godot --headless --path Godot -s tests/test_midi_clip_inspector.gd -- --test
extends TestBase

var _recorded: Array = []
var _VR: GDScript = load("res://editor/inspector/VelocityRemap.gd")


func suite_name() -> String:
	return "MIDI clip inspector"


func run_tests() -> void:
	var util: GDScript = load("res://history/HistoryUtil.gd")
	util.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	_test_maths()
	await _test_section()
	await _test_drag_and_undo()
	await _test_shift_squashes()
	await _test_layout()
	await _test_osc_throttle()
	util.test_recorder = Callable()


func _midi_instance(velocities: Array, start: int = 0):
	var clip = load("res://data/Clip.gd").new()
	var id := 1
	for v7 in velocities:
		clip.add_midi_note(id, 60 + id, load("res://data/MidiNote.gd").from_midi_velocity(v7), id * 480, 240)
		id += 1
	var inst = load("res://data/ClipInstance.gd").new("", clip.id)
	inst.clip = clip
	inst.start_ticks = start
	return inst


func _panel():
	var panel = load("res://editor/inspector/InspectorPanel.tscn").instantiate()
	panel.project = load("res://data/Project.gd").new()
	root.add_child(panel)
	await process_frame
	return panel


func _section(panel):
	for s in panel.get_visible_sections():
		if s.get_script() == load("res://editor/inspector/MidiClipInspector.gd"):
			return s
	return null


func _v7(inst) -> Array:
	return inst.clip.midi_notes.map(func(n): return roundi(n.velocity * 127.0))


func _test_maths() -> void:
	var s = _VR.stats([40.0, 80.0, 120.0, 100.0])
	_assert(s["min"] == 40.0 and s["max"] == 120.0, "min / max")
	_assert(s["median"] == 90.0 and s["mean"] == 85.0, "median of an even set is the middle pair, mean is 85")
	_assert(_VR.stats([5.0, 1.0, 9.0])["median"] == 5.0, "median of an odd set")
	_assert(_VR.stats([])["count"] == 0, "empty set")
	var h = _VR.histogram([1.0, 127.0, 127.0], 4)
	_assert(h[0] == 1 and h[3] == 2, "histogram puts extremes in the end bins")
	_assert(_VR.remap(40, 40, 120, 20, 60) == 20.0 and _VR.remap(120, 40, 120, 20, 60) == 60.0, "range ends map to new ends")
	_assert(_VR.remap(80, 40, 120, 20, 60) == 40.0, "middle maps linearly")
	_assert(_VR.remap(50, 50, 50, 20, 60) == 40.0, "equal velocities land mid range")
	_assert(_VR.remap(80, 40, 120, 60, 20) == 40.0, "crossed target range is sorted")
	_assert(_VR.remap(120, 40, 120, 100, 300) == 127.0, "never above 127")


func _test_section() -> void:
	var panel = await _panel()
	var a = _midi_instance([40, 80, 120])
	panel.set_selection([a])
	var s = _section(panel)
	_assert(s != null, "MIDI clip gets the velocity section")
	_assert(is_equal_approx(s._range_slider.a_value, 40.0) and is_equal_approx(s._range_slider.b_value, 120.0), "handles show min and max")
	_assert("Min 40" in s._stats_label.text and "Med 80" in s._stats_label.text and "Max 120" in s._stats_label.text, "readout: " + s._stats_label.text)
	var audio = load("res://data/ClipInstance.gd").new("", "x")
	audio.clip = load("res://data/Clip.gd").new()
	audio.clip.type = 0
	panel.set_selection([a, audio])
	_assert(_section(panel) == null, "mixed MIDI and audio selection has no velocity section")
	panel.set_selection([_midi_instance([])])
	_assert(_section(panel).visible and _section(panel)._stats_label.text == "No notes", "empty clip says so")
	panel.queue_free()


func _test_drag_and_undo() -> void:
	var panel = await _panel()
	var a = _midi_instance([40, 80, 120])
	var b = _midi_instance([60, 100])
	panel.set_selection([a, b])
	var s = _section(panel)
	_recorded.clear()
	s._range_slider.drag_started.emit()
	s._range_slider.b_value = 80.0
	s._range_slider.a_value = 20.0
	s._range_slider.a_value = 30.0
	_assert(_recorded.is_empty(), "nothing recorded mid-drag")
	# Combined range 40..120 maps linearly into 30..80.
	_assert(_v7(a) == [30, 55, 80] and _v7(b) == [43, 68], "live remap of both clips, got %s %s" % [_v7(a), _v7(b)])
	s._range_slider.drag_ended.emit()
	_assert(_recorded.size() == 1, "one history entry per drag, got %d" % _recorded.size())
	_assert(is_equal_approx(s._range_slider.a_value, 30.0) and "Min 30" in s._stats_label.text, "section follows the new range")
	_recorded[0].undo()
	_assert(_v7(a) == [40, 80, 120] and _v7(b) == [60, 100], "undo restores every note")
	_assert(is_equal_approx(s._range_slider.b_value, 120.0), "slider follows undo")
	_recorded[0].do()
	_assert(_v7(a) == [30, 55, 80], "redo reapplies")
	panel.queue_free()


func _test_shift_squashes() -> void:
	var panel = await _panel()
	var a = _midi_instance([40, 80, 120])
	panel.set_selection([a])
	var s = _section(panel)
	_recorded.clear()
	s._range_slider.drag_started.emit()
	# Fill drag pushed against the top: the slider clamps b at 127, a keeps going.
	s._range_slider.set_values_no_signal(40.0, 120.0)
	s._range_slider._set_both(80.0, 160.0)
	_assert(_v7(a) == [80, 104, 127], "shift up squashes towards 127 instead of clipping, got %s" % [_v7(a)])
	s._range_slider.drag_ended.emit()
	_assert(_recorded.size() == 1, "shift is one undo step")
	_recorded.clear()
	s._range_slider.drag_started.emit()
	s._range_slider.drag_ended.emit()
	_assert(_recorded.is_empty(), "a gesture that changes nothing records nothing")
	panel.queue_free()


func _test_layout() -> void:
	var panel = await _panel()
	var a = _midi_instance([64])
	panel.set_selection([a])
	var clip_section = panel.get_visible_sections()[0]
	var label: Label = null
	for n in clip_section.find_children("*", "Label", true, false):
		if n.text == "Name":
			label = n
	_assert(label != null, "Name caption exists")
	var editor: Control = label.get_parent().get_child(1)
	_assert(label.get_parent() is VBoxContainer and editor is LineEdit, "caption sits above its editor in a vertical row")
	panel.queue_free()


func _test_osc_throttle() -> void:
	var panel = await _panel()
	var vels: Array = []
	for i in 40:
		vels.append(10 + i * 3)
	var a = _midi_instance(vels)
	a.clip._synced_to_engine = true  # count engine syncs without a socket
	panel.set_selection([a])
	var s = _section(panel)
	_recorded.clear()
	var before: int = a.clip.note_updates_sent
	s._range_slider.drag_started.emit()
	for step in 100:
		s._range_slider.b_value = 127.0 - step * 0.5
	var mid: int = a.clip.note_updates_sent - before
	_assert(mid <= 40 * 3, "100 drag steps sync at most a few batches (%d messages for 40 notes)" % mid)
	_assert(mid < 100 * 40, "far fewer than one message per note per step")
	s._range_slider.drag_ended.emit()
	var total: int = a.clip.note_updates_sent - before
	_assert(total > mid or a.clip._dirty_notes.is_empty(), "release flushes the rest")
	_assert(a.clip._dirty_notes.is_empty() and not a.clip._note_sync_throttled, "nothing pending, throttle off after release")
	# A final message exists for every note that moved.
	var sent_before: int = a.clip.note_updates_sent
	_recorded[0].undo()
	_assert(a.clip.note_updates_sent - sent_before == 40, "undo syncs every note at once, got %d" % (a.clip.note_updates_sent - sent_before))
	panel.queue_free()
