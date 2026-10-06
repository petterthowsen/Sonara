# Sampler panel: SampleDisplay hit-testing and drag constraints, playhead decoding and
# extrapolation, and the scene-based view (one undo step per point drag, loop overlay hidden with
# Loop Off, waveform shown once ready, also after the sample source is swapped). Spec 023: the
# display's title, placeholder action and drops, and the views in multisample mode (per-zone
# controls follow focus, the focus menu, the zone strip in the Companion view).
# Run: godot --headless --path Godot -s tests/test_sampler_view.gd -- --test
extends TestBase

var _device_script: GDScript
var _instance_script: GDScript
var _history_util: GDScript
var _sd: GDScript
var _sv: GDScript

const ENUMS := {
	"Play Mode": ["One-shot", "Gated"],
	"Loop Mode": ["Off", "On", "Ping-Pong"],
	"Filter Type": ["Off", "LP12", "LP24", "BP12", "BP24", "HP12", "HP24"],
}


func suite_name() -> String:
	return "Sampler view"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	_sd = load("res://devices/builtin/sampler/SampleDisplay.gd")
	_sv = load("res://devices/builtin/SamplerDefaultView.gd")
	_test_hit_testing()
	_test_play_constraints()
	_test_loop_constraints()
	_test_drag_and_reset()
	_test_loop_hidden_when_off()
	_test_crossfade_ramp()
	_test_playhead_decode()
	_test_playhead_extrapolation()
	_test_display_title_and_action()
	_test_display_drop()
	await _test_view()
	await _test_window_and_companion()
	await _test_view_multisample()
	await _test_zone_strip()


func _make_display() -> Control:
	var display: Control = _sd.new()
	root.add_child(display)
	display.size = Vector2(1000, 100)
	return display


func _test_hit_testing() -> void:
	var d := _make_display()
	d.play_start = 0.2
	d.play_end = 0.8
	d.loop_mode = _sd.LoopMode.ON
	d.loop_start = 0.4
	d.loop_end = 0.6
	_assert(d.hit_test(Vector2(200, 4)) == _sd.Point.PLAY_START, "play start handle at the top")
	_assert(d.hit_test(Vector2(203, 20)) == _sd.Point.PLAY_START, "line band of the play start")
	_assert(d.hit_test(Vector2(800, 10)) == _sd.Point.PLAY_END, "play end handle")
	_assert(d.hit_test(Vector2(400, 97)) == _sd.Point.LOOP_START, "loop start handle at the bottom")
	_assert(d.hit_test(Vector2(600, 80)) == _sd.Point.LOOP_END, "loop end line band in the bottom half")
	_assert(d.hit_test(Vector2(300, 50)) == -1, "empty space hits nothing")
	d.loop_start = 0.2
	_assert(d.hit_test(Vector2(200, 10)) == _sd.Point.PLAY_START, "play wins over loop in the top half")
	_assert(d.hit_test(Vector2(200, 90)) == _sd.Point.LOOP_START, "loop wins over play in the bottom half")
	d.queue_free()


func _test_play_constraints() -> void:
	var d := _make_display()
	d.play_start = 0.2
	d.play_end = 0.8
	_assert(d.constrain(_sd.Point.PLAY_START, 0.9) < 0.8, "play start can't cross play end")
	_assert(is_equal_approx(d.constrain(_sd.Point.PLAY_START, -0.5), 0.0), "play start stops at 0")
	_assert(d.constrain(_sd.Point.PLAY_END, 0.1) > 0.2, "play end can't cross play start")
	d.loop_mode = _sd.LoopMode.ON
	d.loop_start = 0.4
	d.loop_end = 0.6
	_assert(is_equal_approx(d.constrain(_sd.Point.PLAY_START, 0.5), 0.4), "play start can't cross loop start")
	_assert(is_equal_approx(d.constrain(_sd.Point.PLAY_END, 0.5), 0.6), "play end can't cross loop end")
	d.loop_start = 0.0 # outside the play region: the engine clamps it, so it doesn't block
	_assert(is_equal_approx(d.constrain(_sd.Point.PLAY_START, 0.5), 0.5), "an outside loop point doesn't block")
	d.queue_free()


func _test_loop_constraints() -> void:
	var d := _make_display()
	d.play_start = 0.2
	d.play_end = 0.8
	d.loop_mode = _sd.LoopMode.ON
	d.loop_start = 0.4
	d.loop_end = 0.6
	_assert(is_equal_approx(d.constrain(_sd.Point.LOOP_START, 0.0), 0.2), "loop start clamped into the play region")
	_assert(is_equal_approx(d.constrain(_sd.Point.LOOP_END, 1.0), 0.8), "loop end clamped into the play region")
	_assert(d.constrain(_sd.Point.LOOP_START, 0.7) < 0.6, "loop start can't cross loop end")
	_assert(d.constrain(_sd.Point.LOOP_END, 0.3) > 0.4, "loop end can't cross loop start")
	d.queue_free()


func _test_drag_and_reset() -> void:
	var d := _make_display()
	d.play_start = 0.2
	var events: Array = []
	d.point_drag_started.connect(func(which): events.append(["start", which]))
	d.point_dragged.connect(func(which, v): events.append(["drag", which, v]))
	d.point_drag_ended.connect(func(which): events.append(["end", which]))
	d.begin_drag(_sd.Point.PLAY_START, Vector2(200, 5))
	d.drag_to(Vector2(300, 5))
	_assert(is_equal_approx(d.play_start, 0.3), "dragging moves the point with the pointer")
	d.drag_to(Vector2(1500, 5))
	_assert(d.play_start < d.play_end, "dragging past the other point stays constrained")
	d.end_drag()
	_assert(events.size() >= 4 and events[0] == ["start", 0] and events[-1] == ["end", 0], "drag emits started, dragged…, ended")
	# Shift: a fine drag moves less than the pointer.
	d.play_start = 0.2
	d.begin_drag(_sd.Point.PLAY_START, Vector2(200, 5))
	d.drag_to(Vector2(300, 5), true)
	_assert(d.play_start > 0.2 and d.play_start < 0.25, "shift drags finely")
	d.end_drag()
	# Double click resets to the default through one started/dragged/ended sequence.
	d.play_start = 0.3
	events.clear()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.double_click = true
	click.position = Vector2(300, 5)
	d._gui_input(click)
	_assert(is_equal_approx(d.play_start, 0.0), "double click resets the point")
	_assert(events.size() == 3 and events[0][0] == "start" and events[2][0] == "end", "reset is one gesture")
	d.queue_free()


func _test_loop_hidden_when_off() -> void:
	var d := _make_display()
	d.loop_start = 0.4
	d.loop_end = 0.6
	_assert(not d.loop_visible(), "the loop is hidden when Loop Mode is Off")
	_assert(d.hit_test(Vector2(400, 97)) == -1, "loop handles can't be grabbed when Loop Mode is Off")
	d.loop_mode = _sd.LoopMode.ON
	_assert(d.hit_test(Vector2(400, 97)) == _sd.Point.LOOP_START, "loop handles come back with Loop On")
	d.queue_free()


func _test_crossfade_ramp() -> void:
	var d := _make_display()
	d.loop_mode = _sd.LoopMode.ON
	d.loop_start = 0.0
	d.loop_end = 1.0
	d.xfade = 0.5
	_assert(d.effective_crossfade() == Vector2.ZERO, "no forward crossfade when the loop starts at 0")
	d.loop_start = 0.4
	d.loop_end = 0.6
	d.xfade = 0.3
	var ramp: Vector2 = d.effective_crossfade()
	_assert(is_equal_approx(ramp.y, 0.6) and is_equal_approx(ramp.x, 0.54), "crossfade ramp ends at Loop End")
	d.xfade = 1.0
	ramp = d.effective_crossfade()
	_assert(is_equal_approx(ramp.y - ramp.x, 0.1), "crossfade capped at half the loop")
	d.reverse = true
	ramp = d.effective_crossfade()
	_assert(is_equal_approx(ramp.x, 0.4), "reversed crossfade starts at Loop Start")
	d.reverse = false
	d.loop_mode = _sd.LoopMode.PING_PONG
	_assert(d.effective_crossfade() == Vector2.ZERO, "ping-pong ignores the crossfade")
	d.queue_free()


func _playhead_blob(records: Array) -> PackedByteArray:
	var blob := PackedByteArray()
	blob.resize(4 + records.size() * 12)
	blob.encode_u32(0, records.size())
	for i in records.size():
		for k in 3:
			blob.encode_float(4 + i * 12 + k * 4, records[i][k])
	return blob


func _test_playhead_decode() -> void:
	var decoded: Dictionary = _sd.decode_playheads(_playhead_blob([[0.25, 0.5, 1.0], [0.75, -0.5, 0.5]]))
	_assert(int(decoded["count"]) == 2, "two playheads decode")
	_assert(is_equal_approx(decoded["position"][1], 0.75) and is_equal_approx(decoded["velocity"][1], -0.5), "position and velocity decode")
	_assert(is_equal_approx(decoded["level"][1], 0.5), "level decodes")
	_assert(int(_sd.decode_playheads(_playhead_blob([]))["count"]) == 0, "an empty record decodes to no playheads")
	var short := _playhead_blob([[0.1, 0.0, 1.0]])
	short.resize(8)
	_assert(int(_sd.decode_playheads(short)["count"]) == 0, "a truncated blob decodes to nothing")


func _test_playhead_extrapolation() -> void:
	var d := _make_display()
	d.play_start = 0.1
	d.play_end = 0.9
	d.apply_playhead_packet(_sd.decode_playheads(_playhead_blob([[0.3, 0.2, 1.0]])), 1000)
	_assert(is_equal_approx(d.playheads[0], 0.3), "a packet snaps the playhead")
	d.step(1100)
	_assert(is_equal_approx(d.playheads[0], 0.32), "the playhead extrapolates with its velocity")
	d.step(1240)
	_assert(is_equal_approx(d.playheads[0], 0.348), "extrapolation continues within the timeout")
	d.apply_playhead_packet(_sd.decode_playheads(_playhead_blob([[0.89, 1.0, 1.0]])), 2000)
	d.step(2100)
	_assert(is_equal_approx(d.playheads[0], 0.9), "extrapolation is clamped to the play region")
	d.step(2000 + _sd.PLAYHEAD_TIMEOUT_MS + 1)
	_assert(d.playheads.is_empty(), "playheads clear after 250 ms without a packet")
	d.queue_free()


# ============================================================================
# VIEW
# ============================================================================

func _make_instance() -> Object:
	var device: Object = _device_script.new(
		"sonara.builtin.sampler", "Sampler", _device_script.DeviceCategory.Instrument
	)
	var add := func(id: int, name: String, min_v: float, max_v: float, default_v: float, type := "float") -> void:
		var param := DeviceParameter.new(id, name)
		param.min_value = min_v
		param.max_value = max_v
		param.default_value = default_v
		param.param_type = type
		if type == "enum":
			param.enum_values.assign(ENUMS[name])
		device.add_parameter(param)
	add.call(0, "Volume", 0.0, 2.0, 1.0)
	add.call(1, "Tune", -24.0, 24.0, 0.0)
	add.call(2, "Speed", 25.0, 400.0, 100.0)
	add.call(3, "Root", 0.0, 127.0, 60.0)
	add.call(4, "Key Track", 0.0, 1.0, 0.0, "bool")
	add.call(5, "Play Mode", 0.0, 1.0, 0.0, "enum")
	add.call(6, "Velocity", 0.0, 1.0, 1.0)
	add.call(7, "Start", 0.0, 1.0, 0.0)
	add.call(8, "End", 0.0, 1.0, 1.0)
	add.call(9, "Attack", 0.001, 2.0, 0.001)
	add.call(10, "Decay", 0.001, 2.0, 0.001)
	add.call(11, "Sustain", 0.0, 1.0, 1.0)
	add.call(12, "Release", 0.001, 2.0, 0.01)
	add.call(13, "Voices", 1.0, 64.0, 16.0)
	add.call(14, "Fine", -100.0, 100.0, 0.0)
	add.call(20, "Reverse", 0.0, 1.0, 0.0, "bool")
	add.call(21, "Loop Mode", 0.0, 2.0, 0.0, "enum")
	add.call(22, "Loop Start", 0.0, 1.0, 0.0)
	add.call(23, "Loop End", 0.0, 1.0, 1.0)
	add.call(24, "Crossfade", 0.0, 100.0, 0.0)
	add.call(30, "Filter Type", 0.0, 6.0, 0.0, "enum")
	add.call(31, "Cutoff", 20.0, 20000.0, 1000.0)
	add.call(32, "Resonance", 0.0, 100.0, 0.0)
	add.call(33, "Filter Key Track", 0.0, 100.0, 0.0)
	return _instance_script.new(device, 2, 0)


## A WaveformData loaded from a tiny generated stereo peak file.
func _make_data() -> WaveformData:
	var dir := OS.get_cache_dir().path_join("sonara_test_sampler_view")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("v.swp")
	var levels := [9, 5, 3]
	var width := 4
	var header := PackedByteArray()
	header.resize(64)
	var magic := "SONAPK02".to_ascii_buffer()
	for i in magic.size():
		header[i] = magic[i]
	header.encode_u16(8, 2)
	header.encode_u16(10, 2)
	header.encode_u32(12, 48000)
	header.encode_u64(16, 9 * 64)
	header.encode_u32(24, 64)
	header.encode_u16(28, levels.size())
	header.encode_u16(30, width)
	header[48] = 1
	var table := PackedByteArray()
	table.resize(16 * levels.size())
	var row := 0
	for i in levels.size():
		var rows: int = ceili(levels[i] / float(width))
		table.encode_u64(i * 16, levels[i])
		table.encode_u32(i * 16 + 8, row)
		table.encode_u32(i * 16 + 12, rows)
		row += rows
	var planes := PackedByteArray()
	planes.resize(row * width * 8 * 4)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	f.store_buffer(table)
	f.store_buffer(planes)
	f.close()
	var data := WaveformData.new()
	_assert(data.load_file(path), "generated peak file loads")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(dir)
	return data


func _test_view() -> void:
	var instance := _make_instance()
	var view: Control = (load("res://devices/builtin/SamplerDefaultView.tscn") as PackedScene).instantiate()
	root.add_child(view)
	view.bind_to_device(instance)
	await process_frame
	var display: Control = view.display
	_assert(display != null, "the view builds its display")
	_assert(display.placeholder == "Drop sample(s) here", "an empty sampler shows the drop placeholder")

	# Values reach the controls and the display.
	instance.set_parameter_real(7, 0.25)
	instance.set_parameter_real(21, 1.0)
	instance.set_parameter_real(24, 50.0)
	_assert(is_equal_approx(display.play_start, 0.25), "Start moves the display's play start")
	_assert(display.loop_mode == _sd.LoopMode.ON, "Loop Mode reaches the display")
	_assert(is_equal_approx(display.xfade, 0.5), "Crossfade reaches the display as a fraction")
	_assert(view._segments["Loop Mode"].selected == 1, "Loop Mode segment follows the parameter")
	_assert(view._knobs["Crossfade"].knob.mouse_filter == Control.MOUSE_FILTER_STOP, "Crossfade is enabled with Loop On")
	instance.set_parameter_real(21, 2.0)
	_assert(view._knobs["Crossfade"].knob.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Crossfade is disabled with Ping-Pong")
	_assert(view._knobs["Cutoff"].modulate.a < 1.0, "filter knobs are dimmed with Filter Type Off")
	instance.set_parameter_real(30, 2.0)
	_assert(view._knobs["Cutoff"].modulate.a == 1.0, "filter knobs light up with a filter type")
	_assert(_sv._knob_text(60.0, "Root") == "C3", "Root shows a note name (C3 = 60)")
	_assert(_sv._knob_text(100.0, "Speed") == "100%", "Speed shows percent")
	_assert(_sv._knob_text(-12.4, "Fine") == "-12 ct", "Fine shows cents")

	# A segment edit goes through the device.
	view._segments["Filter Type"].selected = 4
	_assert(is_equal_approx(instance.get_parameter_real(30), 4.0), "choosing a filter type sets the parameter")

	# A display drag is one undo step.
	instance.set_parameter_real(7, 0.0)
	var recorded: Array = []
	_history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	view.size = Vector2(1000, 500)
	await process_frame
	_assert(is_equal_approx(display.size.x, 1000.0), "the display fills the view's width")
	display.begin_drag(_sd.Point.PLAY_START, Vector2(0, 5))
	display.drag_to(Vector2(100, 5))
	display.drag_to(Vector2(300, 5))
	display.drag_to(Vector2(400, 5))
	display.end_drag()
	_history_util.test_recorder = Callable()
	_assert(recorded.size() == 1, "a point drag records exactly one undo step (got %d)" % recorded.size())
	_assert(is_equal_approx(instance.get_parameter_real(7), 0.4), "the drag wrote the final Start value")
	if recorded.size() == 1:
		recorded[0].undo()
		_assert(is_equal_approx(instance.get_parameter_real(7), 0.0), "undo restores Start")

	# The waveform shows once ready, including after the source object is swapped.
	var source := AudioSourceInfo.new()
	instance.sample_source = source
	_assert(display.data == null, "no waveform before the peak data is ready")
	source.data = _make_data()
	source.waveform_ready.emit()
	_assert(display.data != null and display.data.is_ready(), "the display shows the waveform once ready")
	var swapped := AudioSourceInfo.new()
	swapped.data = _make_data()
	instance.sample_source = swapped
	_assert(display.data == swapped.data, "swapping the sample source rebinds the display")
	var third := AudioSourceInfo.new()
	instance.sample_source = third
	third.data = swapped.data
	third.waveform_ready.emit()
	_assert(display.data == swapped.data, "events of the new source reach the display")
	_assert(not source.waveform_ready.is_connected(view._binder._update_waveform), "the old source is released")

	# Playheads reach the display; an empty record clears them.
	view.apply_playheads(_playhead_blob([[0.5, 0.0, 1.0]]), 1000)
	_assert(display.playheads.size() == 1, "the view feeds playheads to the display")
	view.apply_playheads(_playhead_blob([]))
	_assert(display.playheads.is_empty(), "an empty playheads record clears them")
	view.queue_free()


## Window and Companion views, built the way the device frame and panel do (spec 023, T-002/T-003).
func _test_window_and_companion() -> void:
	var instance := _make_instance()
	var dev: Object = instance.device
	var factory: GDScript = load("res://devices/DeviceViewFactory.gd")
	factory.register_builtin_views(dev)
	var panel: Control = factory.create(instance, _device_script.ViewType.Panel)
	var companion: Control = factory.create(instance, _device_script.ViewType.Companion)
	var window: Control = factory.create(instance, _device_script.ViewType.Window)
	_assert(companion != null, "the factory returns a Sampler Companion view")
	_assert(window != null, "the factory returns a Sampler Window view")
	if companion == null or window == null or panel == null:
		return
	for v in [panel, companion, window]:
		root.add_child(v)
		v.bind_to_device(instance)
	await process_frame
	_assert(companion.display == null, "the Companion view has no display")
	_assert(panel.display != null, "the Panel view keeps its display")
	_assert(companion._knobs.keys() == panel._knobs.keys(), "Companion knobs equal the Panel's")
	_assert(companion._segments.keys() == panel._segments.keys(), "Companion segments equal the Panel's")
	_assert(companion._checks.keys() == panel._checks.keys(), "Companion checks equal the Panel's")
	_assert(window.display != null, "the Window view has a display")

	# A Start drag in the Window view shows on the Companion view's Start-driven display state.
	window.size = Vector2(1000, 300)
	await process_frame
	_history_util.test_recorder = func(_cmd) -> void: pass
	window.display.begin_drag(_sd.Point.PLAY_START, Vector2(0, 5))
	window.display.drag_to(Vector2(500, 5))
	window.display.end_drag()
	_history_util.test_recorder = Callable()
	_assert(is_equal_approx(instance.get_parameter_real(7), 0.5), "a Window display drag writes Start")
	_assert(is_equal_approx(panel.display.play_start, 0.5), "the Panel's display follows the Window's drag")

	# And a Companion edit reaches the Window display.
	companion._segments["Loop Mode"].selected = 1
	_assert(window.display.loop_mode == _sd.LoopMode.ON, "a Companion Loop Mode edit reaches the Window display")

	window.apply_playheads(_playhead_blob([[0.5, 0.0, 1.0]]), 1000)
	_assert(window.display.playheads.size() == 1, "the Window view feeds playheads to its display")
	for v in [panel, companion, window]:
		v.queue_free()


# ============================================================================
# SPEC 023: DISPLAY TITLE, PLACEHOLDER ACTION, DROPS
# ============================================================================

func _click(pos: Vector2, button := MOUSE_BUTTON_LEFT) -> InputEventMouseButton:
	var click := InputEventMouseButton.new()
	click.button_index = button
	click.pressed = true
	click.position = pos
	return click


func _test_display_title_and_action() -> void:
	var d := _make_display()
	var clicks := [0]
	d.title_clicked.connect(func() -> void: clicks[0] += 1)
	_assert(d.title_rect() == Rect2(), "no title, no title rect")
	d._gui_input(_click(Vector2(20, 8)))
	_assert(clicks[0] == 0, "no title, no title click")
	d.title = "Piano_C3"
	var rect: Rect2 = d.title_rect()
	_assert(rect.size.x > 0.0 and rect.position.x >= 8.0, "the title sits at the top left, clear of the Start handle")
	d._gui_input(_click(rect.get_center()))
	_assert(clicks[0] == 1, "clicking the title emits title_clicked")
	d._gui_input(_click(Vector2(500, 50)))
	_assert(clicks[0] == 1, "clicking elsewhere doesn't")
	var font := ThemeDB.fallback_font
	var cut: String = _sd.fit_text("A rather long sample name", font, 11, 60.0)
	_assert(cut.ends_with("…") and font.get_string_size(cut, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x <= 60.0, "long labels are cut to fit with an ellipsis")
	_assert(_sd.fit_text("Kick", font, 11, 200.0) == "Kick", "short labels stay whole")

	var pressed := [0]
	d.placeholder_action_pressed.connect(func() -> void: pressed[0] += 1)
	d.placeholder_action = "Create Multisample"
	_assert(not d.is_placeholder_action_visible(), "no button without a placeholder")
	d.placeholder = "Drop sample(s) here"
	_assert(d.is_placeholder_action_visible(), "the button shows with the placeholder")
	d._action_button.pressed.emit()
	_assert(pressed[0] == 1, "the button emits placeholder_action_pressed")
	d.placeholder = ""
	_assert(not d.is_placeholder_action_visible(), "the button hides with the placeholder")

	var menus: Array = []
	d.context_menu_requested.connect(func(at: Vector2) -> void: menus.append(at))
	d._gui_input(_click(Vector2(300, 40), MOUSE_BUTTON_RIGHT))
	_assert(menus == [Vector2(300, 40)], "a right click requests the context menu")
	d.queue_free()


func _test_display_drop() -> void:
	var d := _make_display()
	var asset_script: GDScript = load("res://browser/Asset.gd")
	var audio: Object = asset_script.new()
	audio.type = asset_script.TYPE.Audio
	audio.path = "/tmp/a.wav"
	var midi: Object = asset_script.new()
	midi.type = asset_script.TYPE.Midi
	midi.path = "/tmp/a.mid"
	var dropped: Array = []
	d.assets_dropped.connect(func(assets: Array) -> void: dropped.append(assets))
	_assert(d._can_drop_data(Vector2.ZERO, audio), "one audio asset can drop")
	_assert(d._can_drop_data(Vector2.ZERO, [audio, audio]), "several audio assets can drop")
	_assert(not d._can_drop_data(Vector2.ZERO, midi), "a MIDI asset can't")
	_assert(not d._can_drop_data(Vector2.ZERO, [audio, midi]), "a mixed selection can't")
	d._drop_data(Vector2.ZERO, audio)
	_assert(dropped.size() == 1 and dropped[0].size() == 1 and dropped[0][0] == audio, "a drop emits the assets as an array")
	d.accepts_drops = false
	_assert(not d._can_drop_data(Vector2.ZERO, audio), "accepts_drops off refuses drops")
	d.queue_free()


# ============================================================================
# SPEC 023: VIEWS IN MULTISAMPLE MODE
# ============================================================================

## A Sampler instance in multisample mode with zones A (root C3) and B (root G3).
func _multisample_instance() -> Object:
	var instance := _make_instance()
	var model: Object = instance.ensure_multisample()
	model.add_files(["/tmp/A_C3.wav", "/tmp/B_G3.wav"])
	return instance


func _test_view_multisample() -> void:
	var recorded: Array = []
	_history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)

	# REQ-010: the empty Sampler's button converts.
	var empty := _make_instance()
	var view: Control = (load("res://devices/builtin/SamplerDefaultView.tscn") as PackedScene).instantiate()
	root.add_child(view)
	view.bind_to_device(empty)
	await process_frame
	_assert(view.display.placeholder_action == "Create Multisample", "an empty Sampler offers Create Multisample")
	view.display.placeholder_action_pressed.emit()
	_assert(empty.multisample.active and empty.multisample.zones.is_empty(), "the button switches to an empty multisample")
	_assert(recorded.size() == 1, "creating the multisample is one undo step")
	_assert(view.display.placeholder_action == "", "no Create button once in multisample mode")
	view.queue_free()

	var instance := _multisample_instance()
	var model: Object = instance.multisample
	var a: Object = model.zones[0]
	var b: Object = model.zones[1]
	view = (load("res://devices/builtin/SamplerDefaultView.tscn") as PackedScene).instantiate()
	root.add_child(view)
	view.bind_to_device(instance)
	await process_frame
	recorded.clear()

	# REQ-022: per-zone controls follow focus; REQ-021: the display shows the focused zone.
	model.set_focus(a.id)
	_assert(is_equal_approx(view._knobs["Root"].knob.value, 60.0), "focusing A shows its root (C3) on the Root knob")
	_assert(view.display.title == "A_C3", "the display title is the focused zone's name")
	model.set_focus(b.id)
	_assert(is_equal_approx(view._knobs["Root"].knob.value, 67.0), "focusing B shows its root (G3)")
	_assert(view.display.title == "B_G3", "the title follows focus")
	_assert(not view._checks["Key Track"].visible, "Key Track hides in multisample mode")
	_assert(view._badges.all(func(badge) -> bool: return badge.visible), "the per-zone groups show the Sample badge")

	# Turning Root edits only the focused zone, through a mergeable zone snapshot.
	var root_param: float = instance.get_parameter_real(3)
	view._knobs["Root"].knob.value = 65.0
	_assert(b.root == 65 and a.root == 60, "turning Root edits only the focused zone")
	_assert(is_equal_approx(instance.get_parameter_real(3), root_param), "the Root parameter is untouched")
	view._knobs["Root"].knob.value = 66.0
	_assert(recorded.size() == 2 and recorded[0].can_merge(recorded[1]), "Root edits on one zone merge into one undo step")
	view._segments["Loop Mode"].selected = 1
	_assert(b.loop_mode == 1 and view.display.loop_mode == _sd.LoopMode.ON, "Loop Mode edits the zone and reaches the display")
	view._knobs["Crossfade"].knob.value = 40.0
	_assert(is_equal_approx(b.crossfade, 0.4), "Crossfade % becomes a zone fraction")

	# A display drag edits the focused zone's start, one undo step.
	recorded.clear()
	view.size = Vector2(1000, 500)
	await process_frame
	view.display.begin_drag(_sd.Point.PLAY_START, Vector2(0, 5))
	view.display.drag_to(Vector2(200, 5))
	view.display.drag_to(Vector2(300, 5))
	view.display.end_drag()
	_assert(is_equal_approx(b.start, 0.3) and is_equal_approx(a.start, 0.0), "a point drag moves the focused zone's start only")
	_assert(recorded.size() == 1, "a zone point drag is one undo step (got %d)" % recorded.size())
	if recorded.size() == 1:
		recorded[0].undo()
		_assert(is_equal_approx(b.start, 0.0), "undo restores the zone's start")

	# The focus menu lists zones by root and changes focus.
	model.set_zone_fields(a.id, {"root": 70})
	var menu: PopupMenu = view._binder.fill_focus_menu()
	_assert(menu.theme_type_variation == &"ContextMenuList", "the focus menu uses the context-menu style")
	_assert(menu.item_count == 2 and menu.get_item_id(0) == b.id and menu.get_item_id(1) == a.id, "the focus menu lists zones by root key")
	menu.id_pressed.emit(a.id)
	_assert(model.focused_zone_id == a.id, "choosing a zone in the menu focuses it")

	# The right-click menu offers the conversion that applies.
	var mode_menu: PopupMenu = view._binder.fill_mode_menu()
	_assert(mode_menu.item_count == 1 and mode_menu.get_item_text(0) == "Convert to Single Sample", "multisample mode offers Convert to Single Sample")
	_history_util.test_recorder = Callable()
	view.queue_free()


func _test_zone_strip() -> void:
	var recorded: Array = []
	_history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	var instance := _make_instance()
	var dev: Object = instance.device
	var factory: GDScript = load("res://devices/DeviceViewFactory.gd")
	factory.register_builtin_views(dev)
	var panel: Control = factory.create(instance, _device_script.ViewType.Panel)
	var companion: Control = factory.create(instance, _device_script.ViewType.Companion)
	for v in [panel, companion]:
		root.add_child(v)
		v.bind_to_device(instance)
	await process_frame
	_assert(panel.zone_strip == null, "the Panel view has no zone strip")
	_assert(companion.zone_strip != null and not companion.zone_strip.visible, "the Companion's zone strip hides in single mode")
	instance.ensure_multisample().add_files(["/tmp/A_C3.wav", "/tmp/B_G3.wav"])
	await process_frame
	var strip: Control = companion.zone_strip
	_assert(strip.visible, "the zone strip shows in Companion + multisample")
	var model: Object = instance.multisample
	var focused: Object = model.focused_zone()
	_assert(strip.name_edit.text == focused.name, "the strip shows the focused zone's name")
	recorded.clear()
	strip.knobs["Gain"].knob.value = 0.5
	_assert(is_equal_approx(focused.gain, 0.5), "a strip gain edit changes the zone")
	_assert(recorded.size() == 1, "the edit records one undo step")
	strip.knobs["VelLo"].knob.value = 40.0
	_assert(focused.vel_lo == 40, "the velocity range is editable")
	var other: Object = model.zones[1]
	model.set_focus(other.id)
	_assert(strip.name_edit.text == other.name and is_equal_approx(strip.knobs["Gain"].knob.value, 1.0), "the strip follows focus")
	recorded.clear()
	strip.name_edit.text = "Renamed"
	strip._commit_name()
	_assert(other.name == "Renamed" and recorded.size() == 1, "renaming is one undo step")
	var group_id: int = model.add_group("Soft")
	strip.group_option.select(strip.group_option.get_item_index(group_id))
	strip.group_option.item_selected.emit(strip.group_option.get_item_index(group_id))
	_assert(other.group_id == group_id, "the group dropdown moves the zone")
	_history_util.test_recorder = Callable()
	for v in [panel, companion]:
		v.queue_free()
