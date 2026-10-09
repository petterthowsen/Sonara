# test_audio_clip_inspector.gd
# Clip gain (spec 029 phase 2): the ClipInstance setter, the AudioClipInspector gain row (one undo
# step per drag, reset, typed entry, mixed values) and the waveform following the gain.
#
# Run: godot --headless --path Godot -s tests/test_audio_clip_inspector.gd -- --test
extends TestBase

var _project: Object
var _recorded: Array = []


class FakeTimeline:
	var grid_helper

	func _init(gh) -> void:
		grid_helper = gh

	func ticks_to_pixels(ticks: int) -> float:
		return grid_helper.ticks_to_pixels(ticks)


func suite_name() -> String:
	return "Audio clip inspector"


func run_tests() -> void:
	_project = load("res://data/Project.gd").new()
	var util: GDScript = load("res://history/HistoryUtil.gd")
	util.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	_test_setter()
	await _test_sections()
	await _test_gain_drag_and_undo()
	await _test_gain_reset_and_typed()
	await _test_mixed_gain()
	_test_parse_format()
	await _test_waveform_gain()
	util.test_recorder = Callable()


func _audio_instance(start: int = 0):
	var clip = load("res://data/Clip.gd").new()
	clip.type = 0  # AUDIO
	clip.audio_file_path = "/tmp/loop.wav"
	clip.set_audio_metadata(48000, 2, 96000, 2.0)
	var inst = load("res://data/ClipInstance.gd").new("", clip.id)
	inst.clip = clip
	inst.start_ticks = start
	return inst


func _panel():
	var panel = load("res://editor/inspector/InspectorPanel.tscn").instantiate()
	panel.project = _project
	root.add_child(panel)
	await process_frame
	return panel


func _audio_section(panel):
	for s in panel.get_visible_sections():
		if s.get_script() == load("res://editor/inspector/AudioClipInspector.gd"):
			return s
	return null


func _test_setter() -> void:
	var inst = _audio_instance()
	var hits: Array = []
	inst.gain_changed.connect(func(db: float) -> void: hits.append(db))
	inst.set_gain_offset(6.0)
	_assert(inst.gain_offset == 6.0 and hits == [6.0], "setter stores and signals")
	inst.set_gain_offset(6.0)
	_assert(hits.size() == 1, "same value does not signal")
	inst.set_gain_offset(99.0)
	_assert(inst.gain_offset == 24.0, "clamped to +24 dB")
	inst.set_gain_offset(-200.0)
	_assert(inst.gain_offset == -60.0 and inst.engine_gain_db() < -100.0 and inst.gain_linear() == 0.0, "floor is silent")
	inst.set_gain_offset(0.0)
	_assert(is_equal_approx(inst.gain_linear(), 1.0), "0 dB is unity")
	var restored = load("res://data/ClipInstance.gd").from_json(inst.to_json())
	_assert(restored.gain_offset == 0.0, "gain round-trips through JSON")


func _test_sections() -> void:
	var panel = await _panel()
	var a = _audio_instance()
	panel.set_selection([a])
	var scripts: Array = []
	for s in panel.get_visible_sections():
		scripts.append(s.get_script())
	_assert(scripts == [load("res://editor/inspector/ClipInspector.gd"), load("res://editor/inspector/AudioClipInspector.gd")],
			"Clip then AudioClip sections for an audio clip")
	var s = _audio_section(panel)
	_assert(s._file_label.text == "loop.wav" and s._path_label.text == "/tmp", "file info shown")
	_assert(s._rate_label.text == "48000 Hz" and s._channels_label.text == "Stereo", "format info shown")
	_assert(s._duration_label.text == "2.00 s", "duration shown")
	var midi = load("res://data/ClipInstance.gd").new("", "m")
	midi.clip = load("res://data/Clip.gd").new()
	panel.set_selection([a, midi])
	_assert(_audio_section(panel) == null, "mixed audio and MIDI selection hides the audio section")
	panel.set_selection([midi])
	_assert(_audio_section(panel) == null, "MIDI clip has no audio section")
	panel.queue_free()


func _test_gain_drag_and_undo() -> void:
	var panel = await _panel()
	var a = _audio_instance()
	var b = _audio_instance(3840)
	panel.set_selection([a, b])
	var s = _audio_section(panel)
	_recorded.clear()
	s._gain_slider.drag_started.emit()
	s._gain_slider.value = 3.0
	s._gain_slider.value = 6.0
	_assert(a.gain_offset == 6.0 and b.gain_offset == 6.0, "drag applies live to every instance")
	_assert(_recorded.is_empty(), "nothing recorded mid-drag")
	s._gain_slider.drag_ended.emit()
	_assert(_recorded.size() == 1, "one history entry per drag, got %d" % _recorded.size())
	_assert(s._gain_edit.text == "6.0 dB", "readout follows, got '%s'" % s._gain_edit.text)
	_recorded[0].undo()
	_assert(a.gain_offset == 0.0 and b.gain_offset == 0.0, "undo restores both")
	_assert(s._gain_slider.value == 0.0, "slider follows undo")
	_recorded[0].do()
	_assert(a.gain_offset == 6.0, "redo reapplies")
	panel.queue_free()


func _test_gain_reset_and_typed() -> void:
	var panel = await _panel()
	var a = _audio_instance()
	a.set_gain_offset(-9.0)
	panel.set_selection([a])
	var s = _audio_section(panel)
	_recorded.clear()
	s._gain_slider.reset_requested.emit()  # emitted after the value moved to default
	s._gain_slider.value = 0.0
	_assert(a.gain_offset == 0.0, "reset to 0 dB")
	_assert(_recorded.size() == 1, "reset is one entry")
	_recorded[0].undo()
	_assert(a.gain_offset == -9.0, "undo of reset")
	_recorded.clear()
	s._gain_edit.text = "3.5"
	s._gain_edit.text_submitted.emit("3.5")
	_assert(a.gain_offset == 3.5 and _recorded.size() == 1, "typed gain applies as one step")
	s._gain_edit.text_submitted.emit("-inf")
	_assert(a.gain_offset == -60.0 and s._gain_edit.text == "-inf", "typed -inf goes to the floor")
	s._gain_edit.text_submitted.emit("nonsense")
	_assert(a.gain_offset == -60.0, "garbage is ignored")
	panel.queue_free()


func _test_mixed_gain() -> void:
	var panel = await _panel()
	var a = _audio_instance()
	var b = _audio_instance(3840)
	b.set_gain_offset(-3.0)
	panel.set_selection([a, b])
	var s = _audio_section(panel)
	_assert(s._gain_edit.text == "" and s._gain_edit.placeholder_text == "—", "different gains show the dash")
	b.set_gain_offset(0.0)
	_assert(s._gain_edit.text == "0.0 dB", "equal gains show the value")
	panel.queue_free()


func _test_parse_format() -> void:
	var script: GDScript = load("res://editor/inspector/AudioClipInspector.gd")
	_assert(script.parse_gain("-6 dB") == -6.0, "parse with unit")
	_assert(script.parse_gain("100") == 24.0, "parse clamps")
	_assert(script.parse_gain("-INF") == -60.0, "parse -inf")
	_assert(is_nan(script.parse_gain("x")), "parse rejects text")
	_assert(script.format_gain(-60.0) == "-inf" and script.format_gain(2.25) == "2.3 dB" or script.format_gain(2.25) == "2.2 dB", "format")


func _test_waveform_gain() -> void:
	var inst = _audio_instance()
	var gh = load("res://components/GridHelper.gd").new()
	gh.ppq = 960
	gh.pixels_per_beat = 100.0
	var ui: Control = load("res://arranger/timeline/clip/TimelineClip.tscn").instantiate()
	root.add_child(ui)
	ui.bind_to_clip_instance(inst, FakeTimeline.new(gh))
	var view = ui.get("waveform_view")
	_assert(is_equal_approx(view.gain, 1.0), "unity gain at start")
	inst.set_gain_offset(6.0)
	_assert(is_equal_approx(view.gain, db_to_linear(6.0)), "waveform gain follows the setting, got %s" % view.gain)
	inst.set_gain_offset(-60.0)
	_assert(view.gain == 0.0, "floor draws flat")
	ui.queue_free()
