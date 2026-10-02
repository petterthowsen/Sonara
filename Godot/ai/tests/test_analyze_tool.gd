# analyze tool (analyze-plan phase 5): range parsing, grid formatting, MIDI roots, masking, and the
# RenderService round trip against a mocked transport.
# Run: godot --headless --path Godot -s ai/tests/test_analyze_tool.gd -- --test
extends TestBase

var _sonara: Node
var _Project: GDScript
var _Editor: GDScript
var _Tool: GDScript
var _Format: GDScript
var _Roots: GDScript
var _RS: GDScript
var _Clip: GDScript
var _ClipInstance: GDScript
var _Note: GDScript


class MockTransport extends RefCounted:
	var sent: Array = []
	var listeners: Dictionary = {}
	## Called with the /render/analyze args; returns the result JSON to "write", or "" to fail.
	var on_analyze: Callable

	func send(address: String, args: Array = []) -> void:
		sent.append({"address": address, "args": args})
		if address == "/render/analyze" and on_analyze.is_valid():
			var job: String = args[0]
			var path: String = args[5]
			var json: String = on_analyze.call(args)
			if json == "":
				listeners["/render/failed"].call([job, "plugin crashed"])
				return
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_string(json)
			f.close()
			listeners["/render/done"].call([job, path])

	func listen(address: String, callback: Callable) -> void:
		listeners[address] = callback


func suite_name() -> String:
	return "analyze tool"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_Project = load("res://data/Project.gd")
	_Editor = load("res://editor/Editor.gd")
	_Tool = load("res://ai/tools/AnalyzeTool.gd")
	_Format = load("res://ai/analysis/AnalysisFormat.gd")
	_Roots = load("res://ai/analysis/AnalysisRoots.gd")
	_RS = load("res://core/RenderService.gd")
	_Clip = load("res://data/Clip.gd")
	_ClipInstance = load("res://data/ClipInstance.gd")
	_Note = load("res://data/MidiNote.gd")
	_test_digit_scale()
	_test_position_parsing()
	_test_request_planning()
	_test_format_master_with_markers()
	_test_format_beat_resolution()
	_test_masking_and_silent_channels()
	_test_roots()
	await _test_execute_round_trip()


# ---- fixtures ------------------------------------------------------------------------------

func _project() -> Object:
	var project = _Project.new()
	var editor = _Editor.new()
	editor.project = project
	_sonara.editor = editor
	return project


func _metrics(tap: int, lufs: float, bands: Array, clipped := false) -> Dictionary:
	return {"tap": tap, "lufs": lufs, "bands_db": bands, "peak_db": -3.0, "clipped": clipped,
			"crest_db": 10.0, "correlation": 1.0, "side_mid": 0.0}


## `rows`: per bar, an Array of per-tap metrics. Bars are 3840 ticks, numbered from `first_bar`.
func _result(taps: Array, rows: Array, first_bar := 1, beat := false) -> Dictionary:
	var bars: Array = []
	var span := 960.0 if beat else 3840.0
	for i in rows.size():
		bars.append({"bar": first_bar + (i / 4 if beat else i), "beat": (i % 4) + 1 if beat else 0,
				"start_tick": (first_bar - 1) * 3840.0 + i * span,
				"end_tick": (first_bar - 1) * 3840.0 + (i + 1) * span, "frames": 1000, "taps": rows[i]})
	return {"header": {"scale_version": 1, "sample_rate": 48000.0, "ppq": 960, "resolution": "beat" if beat else "bar",
			"band_names": ["sub", "bass", "lowmid", "mid", "himid", "air"],
			"band_edges_hz": [[20, 60], [60, 250], [250, 800], [800, 2500], [2500, 6000], [6000, 20000]],
			"taps": taps}, "bars": bars}


# ---- tests ---------------------------------------------------------------------------------

func _test_digit_scale() -> void:
	_assert(_Format.digit(-6.0) == "9" and _Format.digit(0.0) == "9", "-6 LUFS and louder is 9")
	_assert(_Format.digit(-33.0) == "0" and _Format.digit(-60.0) == "0", "-33 and quieter is 0")
	_assert(_Format.digit(-23.0) == "3" and _Format.digit(-14.0) == "6", "3 dB steps")
	_assert(_Format.digit(-70.0) == "." and _Format.digit(-120.0) == ".", "silence is a dot")
	_assert(_Format.digit(-69.0) == "0", "quiet but not silent is 0")


func _test_position_parsing() -> void:
	var p := _project()
	_assert(_Tool.parse_position(p, "1") == 0, "bar 1 is tick 0")
	_assert(_Tool.parse_position(p, "17") == 16 * 3840, "bare bar number")
	_assert(_Tool.parse_position(p, 17) == 16 * 3840, "numeric bar")
	_assert(_Tool.parse_position(p, 17.0) == 16 * 3840, "float bar from JSON")
	_assert(_Tool.parse_position(p, "2.3.120") == 3840 + 2 * 960 + 120, "bar.beat.tick")
	_assert(_Tool.parse_position(p, "2:3") == 3840 + 2 * 960, "colon separator and default tick")
	_assert(_Tool.parse_position(p, "0") == -1 and _Tool.parse_position(p, "x") == -1 and _Tool.parse_position(p, "1.0") == -1, "invalid positions")
	# 3/4 from bar 3: bars 1-2 are 3840 ticks, later bars 2880.
	p.time_signature_map.add_change(3, 3, 4)
	_assert(_Tool.parse_position(p, "3") == 2 * 3840, "change bar starts where the old signature ended")
	_assert(_Tool.parse_position(p, "5") == 2 * 3840 + 2 * 2880, "bars after the change are shorter")
	_assert(_Tool.parse_position(p, "4.3.0") == 2 * 3840 + 2880 + 2 * 960, "beats count in the new signature")


func _test_request_planning() -> void:
	var p := _project()
	var bass = p.create_instrument_track("Bass")
	var plan: Dictionary = _Tool.plan_request(p, {"start": "5", "end": "9"})
	_assert(not plan.has("error"), "master-only request plans")
	_assert(plan.options.start_tick == 4 * 3840 and plan.options.end_tick == 8 * 3840, "range in ticks")
	_assert(plan.options.resolution == "bar" and plan.options.pre_roll_ticks == -1 and plan.options.channel_ids.is_empty(), "defaults")
	plan = _Tool.plan_request(p, {"start": "1", "end": "3", "channels": ["bass"]})
	var ch = _Tool.resolve_channel(p, {"channel": "Bass"})
	_assert(plan.options.channel_ids == [ch.id] and plan.names[ch.id] == "Bass", "channel names resolve to ids")
	plan = _Tool.plan_request(p, {"start": "1", "end": "3", "channels": "all"})
	_assert(plan.options.get("all_channels", false), "\"all\" as a string")
	plan = _Tool.plan_request(p, {"start": "1", "end": "3", "channels": ["Nope"]})
	_assert(plan.has("error") and "Nope" in plan.error, "unknown channel fails: %s" % plan.get("error", ""))
	plan = _Tool.plan_request(p, {"start": "1", "end": "18", "resolution": "beat"})
	_assert(plan.has("error") and "16" in plan.error, "beat resolution over 16 bars is refused")
	plan = _Tool.plan_request(p, {"start": "1", "end": "17", "resolution": "beat"})
	_assert(not plan.has("error"), "beat resolution at exactly 16 bars is fine")
	plan = _Tool.plan_request(p, {"start": "5", "end": "5"})
	_assert(plan.has("error"), "empty range refused")
	plan = _Tool.plan_request(p, {"start": "1", "end": "400"})
	_assert(plan.has("error"), "huge bar range refused")
	plan = _Tool.plan_request(p, {"start": "1", "end": "3", "resolution": "second"})
	_assert(plan.has("error"), "bad resolution refused")


func _test_format_master_with_markers() -> void:
	var rows: Array = []
	var lufs := [-18.0, -18.0, -18.0, -18.0, -12.0, -12.0, -12.0, -12.0]  # 5, 5, 5, 5 | 7 x4
	for i in 8:
		rows.append([_metrics(1, lufs[i], [-30.0, -24.0, -21.0, -18.0, -21.0, -120.0], i == 5)])
	var result := _result([1], rows, 17)
	var ctx := {
		"markers": [{"name": "Verse 2", "start_ticks": 16 * 3840, "end_ticks": 20 * 3840},
				{"name": "Chorus", "start_ticks": 20 * 3840, "end_ticks": 24 * 3840}],
		"roots": ["A", "A", "F", "G", "A", "A", "F", "-"],
	}
	var text: String = _Format.format(result, ctx)
	var lines := text.split("\n")
	var expected := [
		"bars:   17 18 19 20 | 21 22 23 24",
		"marker: Verse 2     | Chorus",
		"loud:    5  5  5  5 |  7  7  7  7",
		"sub:     1  1  1  1 |  1  1  1  1",
		"bass:    3  3  3  3 |  3  3  3  3",
		"lowmid:  4  4  4  4 |  4  4  4  4",
		"mid:     5  5  5  5 |  5  5  5  5",
		"himid:   4  4  4  4 |  4  4  4  4",
		"air:     .  .  .  . |  .  .  .  .",
		"peak:    .  .  .  . |  .  !  .  .",
		"root:    A  A  F  G |  A  A  F  -",
	]
	_assert(lines[0].begins_with("Digits 0–9") and "sub 20–60" in lines[0] and "air 6k–20k" in lines[0] and "mid 800–2.5k" in lines[0], "legend explains scale and bands: %s" % lines[0])
	for i in expected.size():
		_assert(lines.size() > i + 1 and lines[i + 1] == expected[i], "grid row %d: '%s'" % [i, lines[i + 1] if lines.size() > i + 1 else "<missing>"])
	_assert(lines.size() == expected.size() + 1, "single tap has no block headers or masking")


func _test_format_beat_resolution() -> void:
	var rows: Array = []
	for i in 8:
		rows.append([_metrics(1, -14.0, [-14.0, -14.0, -14.0, -14.0, -14.0, -14.0])])
	var text: String = _Format.format(_result([1], rows, 3, true), {})
	var lines := text.split("\n")
	_assert(lines[1] == "bars:   3.1 3.2 3.3 3.4 4.1 4.2 4.3 4.4", "beat labels: '%s'" % lines[1])
	_assert(lines[2] == "loud:     6   6   6   6   6   6   6   6", "beat cells align to label width: '%s'" % lines[2])


func _test_masking_and_silent_channels() -> void:
	# Three sections of 2 bars (no markers: one section). Bass and Pad share lowmid, Lead is alone in air,
	# Ghost is silent.
	var rows: Array = []
	for i in 2:
		rows.append([
			_metrics(1, -10.0, [-20.0, -20.0, -15.0, -20.0, -20.0, -20.0]),
			_metrics(2, -14.0, [-60.0, -16.0, -17.0, -60.0, -60.0, -120.0]),
			_metrics(3, -15.0, [-120.0, -80.0, -18.5, -30.0, -120.0, -120.0]),
			_metrics(4, -20.0, [-120.0, -120.0, -120.0, -120.0, -22.0, -18.0]),
			_metrics(5, -120.0, [-120.0, -120.0, -120.0, -120.0, -120.0, -120.0]),
		])
	var names := {1: "Master", 2: "Bass", 3: "Pad", 4: "Lead", 5: "Ghost"}
	var text: String = _Format.format(_result([1, 2, 3, 4, 5], rows, 21), {"names": names})
	_assert("[Master]" in text and "[Bass]" in text and "[Lead]" in text, "blocks per tap")
	_assert(not "[Ghost]" in text and "(1 silent channel omitted)" in text, "silent channel omitted and counted")
	_assert("lowmid bars 21–22: Bass 5, Pad 5" in text, "lowmid masking between Bass and Pad: %s" % text.substr(text.find("Masking")))
	_assert(not "air bars" in text and not "himid bars" in text, "a band with one clear loudest channel is not masking")
	_assert(not "bass bars" in text, "Pad's faint bass doesn't count as masking")
	var solo: String = _Format.format(_result([1, 2], rows.map(func(r): return r.slice(0, 2)), 21), {"names": names})
	_assert(not "Masking" in solo, "no masking summary with a single channel")
	var quiet_rows: Array = [[_metrics(1, -10.0, [-20.0, -20.0, -20.0, -20.0, -20.0, -20.0]),
			_metrics(2, -50.0, [-50.0, -50.0, -50.0, -50.0, -50.0, -50.0]),
			_metrics(3, -50.0, [-50.0, -50.0, -50.0, -50.0, -50.0, -50.0])]]
	var quiet: String = _Format.format(_result([1, 2, 3], quiet_rows, 1), {"names": names})
	_assert("no band where two or more channels" in quiet, "two faint channels are not reported: %s" % quiet.substr(quiet.find("Masking")))


func _test_roots() -> void:
	var p := _project()
	var track = p.create_instrument_track("Bass").track
	var clip = p.create_clip("Line", _Clip.ClipType.MIDI)
	var notes := [[45, 0, 3840], [57, 0, 3840], [43, 3840, 960], [41, 3840 + 960, 2880]]  # A | G short, F long
	for n in notes:
		var note = _Note.new()
		note.note = n[0]
		note.start_tick = n[1]
		note.duration_ticks = n[2]
		clip.midi_notes.append(note)
	clip.content_length_ticks = 7680
	var inst = _ClipInstance.new("", clip.id)
	inst.set_clip(clip)
	inst.start_ticks = 0
	inst.duration_ticks = 7680
	track.clip_instances.append(inst)
	var drums = p.create_instrument_track("Drum Kit").track
	var kick = _Note.new()
	kick.note = 36
	kick.duration_ticks = 7680
	var drum_clip = p.create_clip("Beat", _Clip.ClipType.MIDI)
	drum_clip.midi_notes.append(kick)
	var drum_inst = _ClipInstance.new("", drum_clip.id)
	drum_inst.set_clip(drum_clip)
	drum_inst.duration_ticks = 7680
	drums.clip_instances.append(drum_inst)

	var spans := [Vector2i(0, 3840), Vector2i(3840, 7680), Vector2i(7680, 11520)]
	var roots: PackedStringArray = _Roots.compute(p, spans)
	_assert(roots[0] == "A", "lowest note of the bar wins over the octave above: %s" % roots[0])
	_assert(roots[1] == "F", "the pitch class the bass spends longest on: %s" % roots[1])
	_assert(roots[2] == "-", "nothing pitched is playing: %s (drum track is ignored)" % roots[2])
	inst.transpose = 2
	_assert(_Roots.compute(p, [Vector2i(0, 3840)])[0] == "B", "transpose applies")
	inst.transpose = 0
	inst.muted = true
	_assert(_Roots.compute(p, [Vector2i(0, 3840)])[0] == "-", "muted instances are ignored")


func _test_execute_round_trip() -> void:
	var p := _project()
	p.create_instrument_track("Bass")
	var ch = _Tool.resolve_channel(p, {"channel": "Bass"})
	var mock := MockTransport.new()
	var service = _RS.new()
	service.transport = mock
	root.add_child(service)
	var tool = _Tool.new()
	tool.render_service = service
	tool.result_dir = OS.get_cache_dir().path_join("sonara_analyze_test")
	mock.on_analyze = func(_args):
		return JSON.stringify(_result([1, ch.id], [
			[_metrics(1, -12.0, [-20.0, -14.0, -20.0, -20.0, -20.0, -30.0]), _metrics(ch.id, -14.0, [-30.0, -14.0, -20.0, -40.0, -60.0, -80.0])],
			[_metrics(1, -12.0, [-20.0, -14.0, -20.0, -20.0, -20.0, -30.0]), _metrics(ch.id, -14.0, [-30.0, -14.0, -20.0, -40.0, -60.0, -80.0])],
		], 5))
	var out: Dictionary = await tool.execute({"start": "5", "end": "7", "channels": ["Bass"]})
	_assert(out.ok, "execute succeeds: %s" % out.get("error", ""))
	var sent: Array = mock.sent[0].args
	_assert(mock.sent[0].address == "/render/analyze" and sent[1] == 4 * 3840 and sent[2] == 6 * 3840, "range sent to the engine")
	_assert(sent[3] == "bar" and sent[4] == -1 and sent[6] == 0 and sent[7] == ch.id, "resolution, pre-roll, channel ids")
	_assert(out.text.contains("bars:    5  6") and out.text.contains("[Bass]") and out.text.contains("root:"), "grid text returned: %s" % out.text)
	_assert(not service.is_running, "service is free again")
	_assert(not FileAccess.file_exists(sent[5]), "result file is cleaned up")

	mock.on_analyze = func(_args): return ""
	out = await tool.execute({"start": "5", "end": "7"})
	_assert(not out.ok and "plugin crashed" in out.error, "engine failure becomes a tool error: %s" % out.get("error", ""))
	_assert(not service.is_running, "service is free after a failure")

	mock.on_analyze = Callable()
	service.start({"start_tick": 0, "end_tick": 960, "master_path": "/tmp/x.wav"})
	out = await tool.execute({"start": "5", "end": "7"})
	_assert(not out.ok and "already running" in out.error, "refuses while another render runs")
	service.queue_free()
