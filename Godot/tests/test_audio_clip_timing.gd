# test_audio_clip_timing.gd
# Stretch modes and clip tempo (spec 029 phase 3): import defaults and the file-name tempo parser,
# mode and tempo round-trip, the tempo rescale as one undo step across tracks, the waveform mapping
# per mode, the mode badge and the AudioClipInspector controls.
#
# Run: godot --headless --path Godot -s tests/test_audio_clip_timing.gd -- --test
extends TestBase

var _recorded: Array = []
## Named through the loaded script: bare class names would compile before the autoloads exist.
var _timing: GDScript


class FakeTimeline:
	var grid_helper

	func _init(gh) -> void:
		grid_helper = gh

	func ticks_to_pixels(ticks: int) -> float:
		return grid_helper.ticks_to_pixels(ticks)


func suite_name() -> String:
	return "Audio clip timing"


func run_tests() -> void:
	_timing = load("res://data/AudioClipTiming.gd")
	var util: GDScript = load("res://history/HistoryUtil.gd")
	util.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	_test_parser()
	_test_import_defaults()
	_test_json_round_trip()
	_test_tempo_rescale()
	_test_waveform_mapping()
	await _test_badge()
	await _test_inspector_controls()
	await _test_gain_double_click()
	util.test_recorder = Callable()


func _clip(bpm: float = 120.0, mode: int = 1):
	var clip = load("res://data/Clip.gd").new()
	clip.type = 0
	clip.audio_file_path = "/tmp/loop.wav"
	clip.set_audio_metadata(48000, 2, 96000, 2.0)
	clip.stretch_mode = mode
	clip.recorded_bpm = bpm
	clip.content_length_ticks = clip.content_length_for_tempo(bpm, 960)
	return clip


func _place(track, clip, start: int, duration: int, offset: int = 0):
	var inst = load("res://data/ClipInstance.gd").new("", clip.id)
	inst.clip = clip
	inst.start_ticks = start
	inst.duration_ticks = duration
	inst.clip_offset = offset
	track.add_clip_instance(inst)
	return inst


func _test_parser() -> void:
	var parse: Callable = load("res://data/AudioImportDefaults.gd").parse_tempo
	_assert(parse.call("/x/loop_120bpm.wav") == 120.0, "120bpm")
	_assert(parse.call("Drums 95 BPM.flac") == 95.0, "95 BPM with spaces")
	_assert(parse.call("bass-128-bpm-Am.wav") == 128.0, "128-bpm")
	_assert(parse.call("pad_87.5bpm.wav") == 87.5, "decimal tempo")
	_assert(parse.call("kick_100_loop.wav") == 100.0, "bare _100_")
	_assert(parse.call("(140) groove.wav") == 140.0, "bare number in parentheses")
	_assert(parse.call("loop_300bpm.wav") == 0.0, "explicit tempo out of range is ignored")
	_assert(parse.call("loop_30_bpm.wav") == 0.0, "30 is below 60")
	_assert(parse.call("snare_808.wav") == 0.0, "808 is out of range")
	_assert(parse.call("take 2.wav") == 0.0, "one digit is not a tempo")
	_assert(parse.call("vox1200.wav") == 0.0, "digits glued to text are not a tempo")
	_assert(parse.call("/music/120/kick.wav") == 0.0, "only the file name counts")
	_assert(parse.call("a_150_and_90bpm.wav") == 90.0, "explicit bpm beats a bare number")


func _test_import_defaults() -> void:
	var defaults: GDScript = load("res://data/AudioImportDefaults.gd")
	var plain: Dictionary = defaults.for_file("/x/field.wav", 133.0)
	_assert(plain["mode"] == 0 and plain["bpm"] == 133.0, "plain file imports Raw at the project tempo")
	var named: Dictionary = defaults.for_file("/x/groove_96bpm.wav", 133.0)
	_assert(named["mode"] == 2 and named["bpm"] == 96.0, "named tempo imports Stretch at that tempo")
	var project = load("res://data/Project.gd").new()
	project.tempo = 100.0
	var asset = load("res://browser/Asset.gd").new()
	asset.name = "a.wav"
	asset.path = "/tmp/a.wav"
	var clip = project.create_clip_from_asset(asset, Color.WHITE, 0)
	_assert(clip.stretch_mode == 0 and is_equal_approx(clip.recorded_bpm, 100.0), "create_clip_from_asset: Raw at project tempo")
	asset.path = "/tmp/b_90bpm.wav"
	clip = project.create_clip_from_asset(asset, Color.WHITE, 0)
	_assert(clip.stretch_mode == 2 and is_equal_approx(clip.recorded_bpm, 90.0), "create_clip_from_asset: Stretch at the named tempo")


func _test_json_round_trip() -> void:
	var clip = _clip(97.5, 0)
	var restored = load("res://data/Clip.gd").from_json(clip.to_json())
	_assert(restored.stretch_mode == 0 and is_equal_approx(restored.recorded_bpm, 97.5), "Raw and tempo round-trip")
	clip.stretch_mode = 2
	restored = load("res://data/Clip.gd").from_json(clip.to_json())
	_assert(restored.stretch_mode == 2, "Stretch round-trips")
	var old: Dictionary = clip.to_json()
	old.erase("stretch_mode")
	restored = load("res://data/Clip.gd").from_json(old)
	_assert(restored.stretch_mode == 1 and is_equal_approx(restored.recorded_bpm, 97.5), "old project loads as Repitch with its saved tempo")


func _test_tempo_rescale() -> void:
	var project = load("res://data/Project.gd").new()
	var clip = _clip(120.0, 1)
	project.add_clip(clip)
	var track_a = load("res://data/Track.gd").new(2)
	var track_b = load("res://data/Track.gd").new(3)
	project.tracks.append(track_a)
	project.tracks.append(track_b)
	var a = _place(track_a, clip, 0, 1920, 960)
	a.set_loop(true, 960, 1920)
	var b = _place(track_b, clip, 3840, 960)
	var other = _clip(120.0, 1)
	project.add_clip(other)
	var untouched = _place(track_b, other, 8000, 960)
	var len_before: int = clip.content_length_ticks
	_assert(len_before == 3840, "2 s at 120 BPM is 4 beats")

	_recorded.clear()
	var cmd = _timing.tempo_change_command(project, clip, 60.0)
	_assert(cmd != null, "a change yields a command")
	load("res://history/HistoryUtil.gd").execute(cmd)
	_assert(_recorded.size() == 1, "one history entry for the whole rescale")
	_assert(is_equal_approx(clip.recorded_bpm, 60.0), "tempo set")
	_assert(clip.content_length_ticks == 1920, "content length halves (%d)" % clip.content_length_ticks)
	_assert(a.duration_ticks == 960 and a.clip_offset == 480, "instance A duration and offset scaled")
	_assert(a.loop_start_ticks == 480 and a.loop_length_ticks == 960, "instance A loop scaled")
	_assert(b.duration_ticks == 480 and b.start_ticks == 3840, "instance B on another track scaled, start untouched")
	_assert(untouched.duration_ticks == 960 and other.recorded_bpm == 120.0, "other clips untouched")
	# Source region: seconds of audio covered by the offset and duration are unchanged
	_assert(is_equal_approx(float(a.clip_offset) / 960.0 * 60.0 / 60.0, 0.5), "offset still points at 0.5 s into the file")
	_assert(is_equal_approx(float(a.duration_ticks) / 960.0 * 60.0 / 60.0, 1.0), "duration still covers 1 s of the file")

	_recorded[0].undo()
	_assert(clip.recorded_bpm == 120.0 and clip.content_length_ticks == len_before, "undo restores clip")
	_assert(a.duration_ticks == 1920 and a.clip_offset == 960 and a.loop_start_ticks == 960 and a.loop_length_ticks == 1920, "undo restores A")
	_assert(b.duration_ticks == 960, "undo restores B")
	_recorded[0].do()
	_assert(clip.content_length_ticks == 1920 and b.duration_ticks == 480, "redo reapplies")
	_assert(_timing.tempo_change_command(project, clip, 60.0) == null, "same tempo is no change")


func _test_waveform_mapping() -> void:
	var tm = load("res://data/TempoMap.gd").new()
	var raw = _clip(90.0, 0)
	var repitch = _clip(90.0, 1)
	var stretch = _clip(90.0, 2)
	# Source rate 48000, ppq 960. Raw follows the project tempo (120): 48000*60/(120*960) = 25
	_assert(is_equal_approx(_timing.frames_per_tick(raw, 0, tm, 120.0, 960, 48000.0), 25.0), "Raw uses the project tempo")
	# Repitch and Stretch use the clip tempo (90): 48000*60/(90*960) = 33.33
	var expected := 48000.0 * 60.0 / (90.0 * 960.0)
	_assert(is_equal_approx(_timing.frames_per_tick(repitch, 0, tm, 120.0, 960, 48000.0), expected), "Repitch uses the clip tempo")
	_assert(is_equal_approx(_timing.frames_per_tick(stretch, 0, tm, 120.0, 960, 48000.0), expected), "Stretch uses the clip tempo")
	# A tempo map: Raw reads the tempo at the instance start
	tm.add_point(0, 60.0)
	_assert(is_equal_approx(_timing.frames_per_tick(raw, 0, tm, 120.0, 960, 48000.0), 48000.0 * 60.0 / (60.0 * 960.0)), "Raw follows the map at the start")


func _timeline_clip(inst):
	var gh = load("res://components/GridHelper.gd").new()
	gh.ppq = 960
	gh.pixels_per_beat = 100.0
	gh.tempo = 120.0
	var ui: Control = load("res://arranger/timeline/clip/TimelineClip.tscn").instantiate()
	root.add_child(ui)
	ui.bind_to_clip_instance(inst, FakeTimeline.new(gh))
	return ui


func _test_badge() -> void:
	_assert(_timing.badge(0) == "" and _timing.badge(1) == "P" and _timing.badge(2) == "S", "badge letters")
	var clip = _clip(120.0, 1)
	var track = load("res://data/Track.gd").new(2)
	var inst = _place(track, clip, 0, 1920)
	var ui = _timeline_clip(inst)
	await process_frame
	_assert(ui._mode_badge_text() == "P", "Repitch clip shows P")
	clip.set_stretch_mode(0)
	_assert(ui._mode_badge_text() == "", "Raw clip shows no badge")
	clip.set_stretch_mode(2)
	_assert(ui._mode_badge_text() == "S", "Stretch clip shows S")
	var view = ui.get("waveform_view")
	_assert(view != null, "waveform view exists")
	ui.queue_free()


func _panel(project):
	var panel = load("res://editor/inspector/InspectorPanel.tscn").instantiate()
	panel.project = project
	root.add_child(panel)
	await process_frame
	return panel


func _audio_section(panel):
	for s in panel.get_visible_sections():
		if s.get_script() == load("res://editor/inspector/AudioClipInspector.gd"):
			return s
	return null


func _test_inspector_controls() -> void:
	var project = load("res://data/Project.gd").new()
	var clip = _clip(120.0, 0)
	project.add_clip(clip)
	var track = load("res://data/Track.gd").new(2)
	project.tracks.append(track)
	var inst = _place(track, clip, 0, 3840)
	var panel = await _panel(project)
	panel.set_selection([inst])
	var s = _audio_section(panel)
	_assert(s._mode_select.selected == s._mode_select.get_item_index(0), "Raw shown")
	_assert(not s._tempo_edit.editable and s._tempo_double.disabled and s._tempo_half.disabled, "tempo controls disabled in Raw")

	_recorded.clear()
	s._mode_select.select(s._mode_select.get_item_index(1))
	s._mode_select.item_selected.emit(s._mode_select.get_item_index(1))
	_assert(clip.stretch_mode == 1 and _recorded.size() == 1, "selecting Repitch is one undo step")
	_assert(s._tempo_edit.editable and not s._tempo_double.disabled, "tempo controls enabled in Repitch")
	_recorded[0].undo()
	_assert(clip.stretch_mode == 0 and s._mode_select.selected == s._mode_select.get_item_index(0), "undo goes back to Raw and the selector follows")
	_assert(s._mode_select.get_item_text(2).contains("Repitch"), "Stretch item says it plays as Repitch")
	s._mode_select.select(s._mode_select.get_item_index(1))
	s._mode_select.item_selected.emit(s._mode_select.get_item_index(1))

	_assert(s._tempo_edit.text == "120", "tempo shown, got '%s'" % s._tempo_edit.text)
	_recorded.clear()
	s._tempo_double.pressed.emit()
	_assert(is_equal_approx(clip.recorded_bpm, 240.0) and _recorded.size() == 1, "x2 doubles the tempo in one step")
	_assert(inst.duration_ticks == 7680 and clip.content_length_ticks == 7680, "x2 rescales the instance and the clip")
	_assert(s._tempo_edit.text == "240", "field follows")
	s._tempo_half.pressed.emit()
	_assert(is_equal_approx(clip.recorded_bpm, 120.0) and inst.duration_ticks == 3840, "/2 halves it again")

	_recorded.clear()
	s._tempo_edit.text_submitted.emit("90")
	_assert(is_equal_approx(clip.recorded_bpm, 90.0) and _recorded.size() == 1, "typed tempo applies")
	# Length in beats: 2 s file, 8 beats -> 240 BPM
	s._beats_edit.text_submitted.emit("8")
	_assert(is_equal_approx(clip.recorded_bpm, 240.0), "8 beats in 2 s is 240 BPM, got %s" % clip.recorded_bpm)
	_assert(clip.content_length_ticks == 7680, "length is 8 beats")
	s._beats_edit.text_submitted.emit("x")
	_assert(is_equal_approx(clip.recorded_bpm, 240.0), "garbage ignored")

	# Reverse
	_recorded.clear()
	s._reverse_toggle.button_pressed = true
	_assert(inst.reverse_enabled and _recorded.size() == 1, "reverse toggles as one step")
	_recorded[0].undo()
	_assert(not inst.reverse_enabled and not s._reverse_toggle.button_pressed, "undo unreverses and the toggle follows")

	# Mixed modes across two clips show the dash
	var clip2 = _clip(120.0, 2)
	project.add_clip(clip2)
	var inst2 = _place(track, clip2, 4000, 960)
	panel.set_selection([inst, inst2])
	s = _audio_section(panel)
	_assert(s._mode_select.selected == -1, "mixed modes select nothing")
	_assert(s._tempo_edit.text == "" and s._tempo_edit.placeholder_text == "—", "different tempos show the dash")
	panel.queue_free()


func _test_gain_double_click() -> void:
	var project = load("res://data/Project.gd").new()
	var clip = _clip(120.0, 0)
	project.add_clip(clip)
	var track = load("res://data/Track.gd").new(2)
	var inst = _place(track, clip, 0, 3840)
	var panel = await _panel(project)
	panel.set_selection([inst])
	var s = _audio_section(panel)
	_recorded.clear()
	# First click of the double-click: press (drag_started), value moves once, release
	s._gain_slider.drag_started.emit()
	s._gain_slider.value = 6.0
	s._gain_slider.drag_ended.emit()
	_assert(_recorded.is_empty(), "a bare click waits for a possible double-click")
	# Second press: reset to default
	s._gain_slider.reset_requested.emit()
	s._gain_slider.value = 0.0
	_assert(inst.gain_offset == 0.0, "reset applied")
	_assert(_recorded.size() == 1, "click plus reset is one undo step, got %d" % _recorded.size())
	_recorded[0].undo()
	_assert(inst.gain_offset == 0.0, "undo returns to the value before the click")
	# A lone click is recorded once the delay passes
	_recorded.clear()
	s._gain_slider.drag_started.emit()
	s._gain_slider.value = 3.0
	s._gain_slider.drag_ended.emit()
	await create_timer(s.CLICK_RECORD_DELAY + 0.15).timeout
	_assert(_recorded.size() == 1 and inst.gain_offset == 3.0, "a lone click is recorded after the delay")
	# Unbinding flushes a waiting click
	_recorded.clear()
	s._gain_slider.drag_started.emit()
	s._gain_slider.value = 5.0
	s._gain_slider.drag_ended.emit()
	panel.set_selection([])
	_assert(_recorded.size() == 1, "selection change flushes the waiting click")
	panel.queue_free()
