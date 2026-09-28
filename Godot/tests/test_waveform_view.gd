# Tests WaveformView wiring: settings → shader uniforms, peak data → level uniforms, and the
# arranger's tick → source-frame mapping in TimelineClip. Also loads the Sampler view.
#
# The views reference autoloads by bare name, so they are loaded with load() inside run_tests().
# Run: godot --headless --path Godot -s tests/test_waveform_view.gd -- --test
extends TestBase

var _settings
var _clip_script: GDScript
var _instance_script: GDScript
var _grid_helper_script: GDScript


class FakeTimeline:
	var grid_helper

	func _init(gh) -> void:
		grid_helper = gh

	func ticks_to_pixels(ticks: int) -> float:
		return grid_helper.ticks_to_pixels(ticks)


func suite_name() -> String:
	return "WaveformView"


func run_tests() -> void:
	_settings = root.get_node("Settings")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	var view_script: GDScript = load("res://support/waveform/WaveformView.gd")
	_assert(view_script != null and view_script.can_instantiate(), "WaveformView compiles")
	var sampler_script: GDScript = load("res://devices/builtin/SamplerDefaultView.gd")
	_assert(sampler_script != null and sampler_script.can_instantiate(), "SamplerDefaultView compiles")
	_assert(load("res://devices/builtin/SamplerDefaultView.tscn").instantiate() != null, "Sampler scene instantiates")

	var data := _make_data()
	_test_settings_to_uniforms(view_script)
	_test_data_uniforms(view_script, data)
	_test_timeline_mapping(data)
	_test_visible_slice(view_script, data)
	_test_sample_window(data)
	_test_view_uses_samples(view_script, data)


## A WaveformData loaded from a tiny generated stereo file (48 kHz, 3 levels).
func _make_data() -> WaveformData:
	var dir := OS.get_cache_dir().path_join("sonara_test_waveform_view")
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
	_assert(data.load_file(path), "generated stereo peak file loads")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(dir)
	return data


func _test_settings_to_uniforms(view_script: GDScript) -> void:
	var view: Control = view_script.new()
	root.add_child(view)
	var mat := view.get("_material") as ShaderMaterial
	_assert(mat.get_shader_parameter("style") == 1, "default style is peaks + RMS")
	_assert(mat.get_shader_parameter("color_mode") == 0, "default colour mode is clip colour")
	_settings.set_value("appearance/waveform_style", "Peaks")
	_settings.set_value("appearance/waveform_color_mode", "Spectral (low/mid/high)")
	_settings.set_value("appearance/waveform_channels", "Mono sum")
	_settings.set_value("appearance/waveform_scale", "Logarithmic (dB)")
	_assert(mat.get_shader_parameter("style") == 0, "style follows setting")
	_assert(mat.get_shader_parameter("color_mode") == 1, "colour mode follows setting")
	_assert(mat.get_shader_parameter("channel_mode") == 1, "channel mode follows setting")
	_assert(mat.get_shader_parameter("amp_scale") == 1, "amplitude scale follows setting")
	for key in ["appearance/waveform_style", "appearance/waveform_color_mode",
			"appearance/waveform_channels", "appearance/waveform_scale"]:
		_settings.set_value(key, _settings.get_setting(key).default)
	_assert(mat.get_shader_parameter("style") == 1, "style resets with setting")
	view.queue_free()


func _test_data_uniforms(view_script: GDScript, data: WaveformData) -> void:
	var view: Control = view_script.new()
	root.add_child(view)
	_assert(view.material == null, "no shader material without data")
	view.data = data
	var mat := view.material as ShaderMaterial
	_assert(mat != null, "shader material applied once data is ready")
	_assert(mat.get_shader_parameter("channels") == 2, "channels uniform")
	_assert(mat.get_shader_parameter("levels") == 3, "levels uniform")
	_assert(mat.get_shader_parameter("tex_width") == 4, "tex_width uniform")
	var rows: PackedInt32Array = mat.get_shader_parameter("level_rows")
	_assert(rows.size() == 24 and rows[0] == 0 and rows[1] == 3 and rows[2] == 5, "level_rows uniform: %s" % [rows.slice(0, 3)])
	var blocks: PackedInt32Array = mat.get_shader_parameter("level_blocks")
	_assert(blocks[0] == 9 and blocks[1] == 5 and blocks[2] == 3, "level_blocks uniform")
	_assert(mat.get_shader_parameter("plane_a_r") == data.plane_a[1], "second channel texture bound")
	view.data = null
	_assert(view.material == null, "material removed when data is cleared")
	view.queue_free()


func _test_timeline_mapping(data: WaveformData) -> void:
	var clip = _clip_script.new()
	clip.type = _clip_script.ClipType.AUDIO
	clip.recorded_bpm = 120.0
	var inst = _instance_script.new()
	inst.clip = clip
	inst.clip_offset = 960  # one beat trimmed from the left
	inst.duration_ticks = 3840
	var gh = _grid_helper_script.new()
	gh.ppq = 960
	gh.pixels_per_beat = 100.0
	var ui: Control = load("res://arranger/timeline/clip/TimelineClip.tscn").instantiate()
	root.add_child(ui)
	ui.bind_to_clip_instance(inst, FakeTimeline.new(gh))
	var view: Control = ui.get("waveform_view")
	_assert(view.visible, "waveform view shown for audio clips")
	_assert(not view.is_data_ready(), "loading placeholder until data arrives")

	clip.audio_source.share_from(_source_with(data))
	# 120 BPM at 48 kHz: one beat = 0.5 s = 24000 source frames.
	_assert(is_equal_approx(view.start_frame, 24000.0), "start_frame from clip_offset: %s" % view.start_frame)
	_assert(is_equal_approx(view.frames_per_pixel, 240.0), "frames_per_pixel from zoom: %s" % view.frames_per_pixel)
	gh.pixels_per_beat = 200.0
	_assert(is_equal_approx(view.frames_per_pixel, 120.0), "frames_per_pixel follows zoom")
	clip.recorded_bpm = 60.0
	clip.clip_modified.emit()
	_assert(is_equal_approx(view.frames_per_pixel, 240.0), "frames_per_pixel follows recorded BPM")

	var midi = _clip_script.new()
	midi.type = _clip_script.ClipType.MIDI
	var midi_inst = _instance_script.new()
	midi_inst.clip = midi
	ui.bind_to_clip_instance(midi_inst, FakeTimeline.new(gh))
	_assert(not view.visible, "waveform view hidden for MIDI clips")
	ui.queue_free()


## Only the part inside clipping ancestors is drawn, and frame0 is the frame at its left edge.
func _test_visible_slice(view_script: GDScript, data: WaveformData) -> void:
	var clipper := Control.new()
	clipper.clip_contents = true
	clipper.size = Vector2(40, 40)  # inside the 64 px headless viewport
	root.add_child(clipper)
	var view: Control = view_script.new()
	clipper.add_child(view)
	view.size = Vector2(1000, 40)
	view.position = Vector2(-300, 0)
	view.data = data
	view.start_frame = 10.0
	view.frames_per_pixel = 2.0
	var mat := view.material as ShaderMaterial
	_assert(view.get("_slice") == Vector2(300, 340), "slice is the clipped part: %s" % view.get("_slice"))
	_assert(is_equal_approx(mat.get_shader_parameter("frame0"), 610.0), "frame0 at the slice's left edge")
	_assert(mat.get_shader_parameter("rect_size") == Vector2(40, 40), "rect_size is the slice size")
	_assert(is_equal_approx(mat.get_shader_parameter("fade_rel0"), 600.0), "fade offset from the view's left edge")
	_assert(is_equal_approx(mat.get_shader_parameter("view_frames"), 2000.0), "view length in frames")
	view.position = Vector2(-2000, 0)
	view._process(0.0)
	_assert(view.get("_slice").x == view.get("_slice").y, "nothing drawn when scrolled out of view")
	clipper.queue_free()


## Chunked requests, replies, texture layout and the width cap.
func _test_sample_window(data: WaveformData) -> void:
	var win_script: GDScript = load("res://support/waveform/WaveformSampleWindow.gd")
	var CHUNK: int = win_script.CHUNK
	var MAX_CHUNKS: int = win_script.MAX_CHUNKS
	var blob := PackedByteArray([0, 0, 0, 8])
	blob.append_array(PackedFloat32Array([0.5, -0.25]).to_byte_array())
	_assert(win_script.decode_blob(blob) == PackedFloat32Array([0.5, -0.25]), "blob decodes to f32")

	var w = win_script.new()
	w.data = data
	_assert(not w.set_range(0, CHUNK * (MAX_CHUNKS + 1)) or data.frames < CHUNK * MAX_CHUNKS, "too wide a range is refused")
	_assert(w.set_range(0, data.frames), "file-sized range accepted")
	var in_flight: Dictionary = w.get("_in_flight")
	_assert(in_flight.size() == 2, "one request per channel: %d" % in_flight.size())
	_assert(not w.is_ready(), "not ready before replies")
	for req_id in in_flight.keys():
		var key: Vector2i = in_flight[req_id].key
		var samples := PackedFloat32Array()
		samples.resize(data.frames)
		samples[3] = 0.75 if key.y == 1 else -0.5
		w.receive(req_id, key.y, key.x * CHUNK, samples)
	_assert(w.is_ready(), "ready once every chunk arrived")
	_assert(w.window_len == data.frames, "window clipped to the file: %d" % w.window_len)
	var img: Image = w.texture.get_image()
	_assert(img.get_size() == Vector2i(CHUNK, 2), "one row per channel per chunk")
	_assert(is_equal_approx(img.get_pixel(3, 0).r, -0.5) and is_equal_approx(img.get_pixel(3, 1).r, 0.75), "samples land in their channel rows")
	w.receive("wfs:stale", 0, 0, PackedFloat32Array([1.0]))
	_assert(w.is_ready(), "unknown replies are ignored")
	w.clear()
	_assert(not w.is_ready(), "clear drops the window")
	_assert(w.set_range(0, data.frames) and w.is_ready(), "cached chunks rebuild without requests")
	_assert(w.get("_in_flight").is_empty(), "no requests for cached chunks")


## Below the base block the view hands its visible range to the sample window.
func _test_view_uses_samples(view_script: GDScript, data: WaveformData) -> void:
	var view: Control = view_script.new()
	root.add_child(view)
	view.size = Vector2(100, 40)
	view.data = data
	view.frames_per_pixel = 128.0
	view._update_samples()
	_assert(not view.is_showing_samples(), "no samples above the base block size")
	view.frames_per_pixel = 2.0
	view._update_samples()
	var w = view.get("_samples")
	var in_flight: Dictionary = w.get("_in_flight")
	_assert(in_flight.size() == 2, "view requested the visible chunk")
	for req_id in in_flight.keys():
		var key: Vector2i = in_flight[req_id].key
		var samples := PackedFloat32Array()
		samples.resize(data.frames)
		w.receive(req_id, key.y, key.x * 4096, samples)
	_assert(view.is_showing_samples(), "samples shown once they arrive")
	var mat := view.material as ShaderMaterial
	_assert(mat.get_shader_parameter("samples_channels") == 2, "samples uniforms set")
	_assert(mat.get_shader_parameter("samples_tex") == w.texture, "samples texture bound")
	view.frames_per_pixel = 128.0
	_assert(not view.is_showing_samples(), "zooming out drops the samples")
	view.queue_free()


func _source_with(data: WaveformData) -> AudioSourceInfo:
	var src := AudioSourceInfo.new()
	src.peak_path = data.path
	src.data = data
	return src
