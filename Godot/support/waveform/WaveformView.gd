## WaveformView.gd
## Draws a WaveformData with waveform.gdshader: one rect, all work per pixel on the GPU.
## Set `data`, `start_frame` (source frame at the left edge) and `frames_per_pixel`; each
## property only updates a shader uniform. Style, colour mode, channel layout and amplitude
## scale follow the "appearance/waveform_*" settings unless `follow_settings` is off.
##
## Only the visible slice of the control is drawn (ancestors with clip_contents and the
## viewport bound it), so positions stay precise when a clip is millions of pixels wide at deep
## zoom. Below the base block size a WaveformSampleWindow fetches the visible raw samples and
## the shader draws them as a line.
class_name WaveformView extends Control

const SHADER := preload("res://support/waveform/waveform.gdshader")
const MAX_LEVELS := 24
## Seconds between raw-sample window updates while scrolling or zooming.
const SAMPLES_THROTTLE := 0.05

enum ChannelMode { SPLIT, MONO_SUM }
enum Style { PEAKS, PEAKS_RMS }
enum ColorMode { CLIP_COLOR, SPECTRAL }
enum AmpScale { LINEAR, DB }

const SETTING_STYLE := "appearance/waveform_style"
const SETTING_COLOR_MODE := "appearance/waveform_color_mode"
const SETTING_CHANNELS := "appearance/waveform_channels"
const SETTING_SCALE := "appearance/waveform_scale"

## Text drawn while `data` is missing or loading. Empty draws nothing.
@export var placeholder_text := "Loading waveform…"
@export var placeholder_color := Color(0.6, 0.6, 0.6, 0.8)
## Read the display options from Settings and follow live changes.
@export var follow_settings := true

var data: WaveformData = null:
	set(d):
		if data == d:
			return
		if data and data.loaded.is_connected(_on_data_loaded):
			data.loaded.disconnect(_on_data_loaded)
		data = d
		if data and not data.is_ready():
			data.loaded.connect(_on_data_loaded)
		_apply_data()

var start_frame: float = 0.0:
	set(v):
		if start_frame == v:
			return
		start_frame = v
		_update_slice()
var frames_per_pixel: float = 64.0:
	set(v):
		v = maxf(v, 1e-4)
		if frames_per_pixel == v:
			return
		frames_per_pixel = v
		_set_param("frames_per_pixel", frames_per_pixel)
		_update_slice()
var gain: float = 1.0:
	set(v):
		if gain == v:
			return
		gain = v
		_set_param("gain", v)
## Draw the file mirrored (clip plays backwards); the sample window follows the mirror too.
var reverse: bool = false:
	set(v):
		if reverse == v:
			return
		reverse = v
		_set_param("reverse", 1.0 if v else 0.0)
		if is_data_ready():
			_samples.clear()
			_update_slice()
var fade_in_frames: float = 0.0:
	set(v):
		if fade_in_frames == v:
			return
		fade_in_frames = v
		_set_param("fade_in_frames", v)
var fade_out_frames: float = 0.0:
	set(v):
		if fade_out_frames == v:
			return
		fade_out_frames = v
		_set_param("fade_out_frames", v)
var fade_curve: float = 1.0:
	set(v):
		if fade_curve == v:
			return
		fade_curve = v
		_set_param("fade_curve", v)
var channel_mode: ChannelMode = ChannelMode.SPLIT:
	set(v):
		if channel_mode == v:
			return
		channel_mode = v
		_set_param("channel_mode", int(v))
var style: Style = Style.PEAKS_RMS:
	set(v):
		if style == v:
			return
		style = v
		_set_param("style", int(v))
var color_mode: ColorMode = ColorMode.CLIP_COLOR:
	set(v):
		if color_mode == v:
			return
		color_mode = v
		_set_param("color_mode", int(v))
var amp_scale: AmpScale = AmpScale.LINEAR:
	set(v):
		if amp_scale == v:
			return
		amp_scale = v
		_set_param("amp_scale", int(v))
var color: Color = Color(0.35, 0.7, 0.95, 1.0):
	set(v):
		if color == v:
			return
		color = v
		_set_param("color", v)

var _material := ShaderMaterial.new()
## Visible local x range [x, y) in whole pixels; only this part is drawn.
var _slice := Vector2.ZERO
var _samples := WaveformSampleWindow.new()
var _samples_timer: Timer = null


func _init() -> void:
	_material.shader = SHADER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_samples.changed.connect(_on_samples_changed)
	for key in ["frames_per_pixel", "gain", "fade_in_frames", "fade_out_frames", "fade_curve", "color"]:
		_material.set_shader_parameter(key, get(key))
	_material.set_shader_parameter("reverse", 1.0 if reverse else 0.0)
	for key in ["channel_mode", "style", "color_mode", "amp_scale"]:
		_material.set_shader_parameter(key, int(get(key)))


func _ready() -> void:
	_samples_timer = Timer.new()
	_samples_timer.one_shot = true
	_samples_timer.wait_time = SAMPLES_THROTTLE
	_samples_timer.timeout.connect(_update_samples)
	add_child(_samples_timer, false, Node.INTERNAL_MODE_BACK)
	resized.connect(_on_resized)
	_on_resized()
	if follow_settings:
		_read_settings()
		Settings.setting_changed.connect(_on_setting_changed)


func _exit_tree() -> void:
	if follow_settings and Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.disconnect(_on_setting_changed)


func _enter_tree() -> void:
	if follow_settings and is_node_ready() and not Settings.setting_changed.is_connected(_on_setting_changed):
		_read_settings()
		Settings.setting_changed.connect(_on_setting_changed)


func is_data_ready() -> bool:
	return data != null and data.is_ready()


## Source frames per second of the loaded file, or 0 while loading.
func source_sample_rate() -> int:
	return data.source_sample_rate if is_data_ready() else 0


## True while raw samples are drawn for (part of) the visible range.
func is_showing_samples() -> bool:
	return is_data_ready() and frames_per_pixel < data.base_block and _samples.is_ready()


func _process(_delta: float) -> void:
	# Scrolling moves this control (or clips it differently) without touching its properties.
	if is_data_ready() and is_visible_in_tree() and _visible_x_range() != _slice:
		_update_slice()


func _draw() -> void:
	if is_data_ready():
		if _slice.y > _slice.x:
			draw_rect(Rect2(_slice.x, 0.0, _slice.y - _slice.x, size.y), Color.WHITE)
	elif not placeholder_text.is_empty() and size.y >= 8.0:
		var font := get_theme_default_font()
		var font_size := get_theme_default_font_size()
		draw_string(font, Vector2(4, size.y * 0.5 + font_size * 0.35), placeholder_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, placeholder_color)


func _set_param(key: String, value: Variant) -> void:
	_material.set_shader_parameter(key, value)
	queue_redraw()


## Without data there is no slice to point at (_apply_data sets it once the data is ready). A
## MIDI clip's hidden view is resized on every arranger zoom step, so this skips real work.
func _on_resized() -> void:
	if is_data_ready():
		_update_slice()


## Local x range [x0, x1) of this control that is on screen, in whole pixels.
func _visible_x_range() -> Vector2:
	if not is_inside_tree():
		return Vector2(0.0, ceilf(size.x))
	var clip := get_viewport_rect()
	var node := get_parent()
	while node is CanvasItem:
		if node is Control and node.clip_contents:
			clip = clip.intersection(node.get_global_rect())
		node = node.get_parent()
	var local := get_global_transform().affine_inverse() * clip
	var x0 := clampf(floorf(local.position.x), 0.0, ceilf(size.x))
	var x1 := clampf(ceilf(local.end.x), x0, ceilf(size.x))
	if clip.size.x <= 0.0 or clip.size.y <= 0.0:
		x1 = x0
	return Vector2(x0, x1)


## Source frame shown at `display_frame` (a content-source frame): mirrored when reversed.
func _source_frame(display_frame: float) -> float:
	if reverse and is_data_ready():
		return float(data.frames) - display_frame
	return display_frame


## Point the shader at the visible slice. Frame positions are computed here in double
## precision and passed relative to the slice, so the shader only sees small numbers.
func _update_slice() -> void:
	_slice = _visible_x_range()
	var fpp := frames_per_pixel
	var frame0 := start_frame + _slice.x * fpp
	_material.set_shader_parameter("rect_size", Vector2(_slice.y - _slice.x, size.y))
	_material.set_shader_parameter("frame0", frame0)
	_material.set_shader_parameter("fade_rel0", _slice.x * fpp)
	_material.set_shader_parameter("view_frames", size.x * fpp)
	_material.set_shader_parameter("samples_rel0", _source_frame(frame0) - float(_samples.window_start))
	queue_redraw()
	_schedule_samples()


func _schedule_samples() -> void:
	if not is_data_ready() or frames_per_pixel >= data.base_block:
		_samples.clear()
		return
	# Throttle rather than debounce, so the window follows a continuous scroll.
	if _samples_timer and _samples_timer.is_inside_tree() and _samples_timer.is_stopped():
		_samples_timer.start()


## Ask for the visible frames plus a margin on each side for scrolling; without the margin if
## that is too wide.
func _update_samples() -> void:
	if not is_data_ready() or frames_per_pixel >= data.base_block or _slice.y <= _slice.x:
		_samples.clear()
		return
	var f0 := start_frame + _slice.x * frames_per_pixel
	var f1 := start_frame + _slice.y * frames_per_pixel
	var s0 := _source_frame(f0)
	var s1 := _source_frame(f1)
	var lo := minf(s0, s1)
	var hi := maxf(s0, s1)
	var margin := (hi - lo) * 0.25
	if not _samples.set_range(floori(lo - margin), ceili(hi + margin)):
		_samples.set_range(floori(lo), ceili(hi) + 1)


func _on_samples_changed() -> void:
	var ready := _samples.is_ready()
	_material.set_shader_parameter("samples_tex", _samples.texture)
	_material.set_shader_parameter("samples_channels", _samples.channels if ready else 0)
	_material.set_shader_parameter("samples_row", WaveformSampleWindow.CHUNK)
	_material.set_shader_parameter("samples_len", float(_samples.window_len))
	_material.set_shader_parameter("samples_rel0",
			_source_frame(start_frame + _slice.x * frames_per_pixel) - float(_samples.window_start))
	queue_redraw()


func _on_data_loaded(_ok: bool) -> void:
	_apply_data()


func _apply_data() -> void:
	_samples.reset()
	_samples.data = data if is_data_ready() else null
	if not is_data_ready():
		material = null
		queue_redraw()
		return
	var rows := PackedInt32Array()
	var blocks := PackedInt32Array()
	rows.resize(MAX_LEVELS)
	blocks.resize(MAX_LEVELS)
	for i in mini(data.levels, MAX_LEVELS):
		rows[i] = data.level_rows[i]
		blocks[i] = int(data.level_blocks[i])
	_material.set_shader_parameter("plane_a_l", data.plane_a[0])
	_material.set_shader_parameter("plane_b_l", data.plane_b[0])
	var r := 1 if data.channels > 1 else 0
	_material.set_shader_parameter("plane_a_r", data.plane_a[r])
	_material.set_shader_parameter("plane_b_r", data.plane_b[r])
	_material.set_shader_parameter("channels", mini(data.channels, 2))
	_material.set_shader_parameter("levels", mini(data.levels, MAX_LEVELS))
	_material.set_shader_parameter("tex_width", data.tex_width)
	_material.set_shader_parameter("level_rows", rows)
	_material.set_shader_parameter("level_blocks", blocks)
	_material.set_shader_parameter("base_block", float(data.base_block))
	_material.set_shader_parameter("total_frames", float(data.frames))
	material = _material
	_update_slice()


func _read_settings() -> void:
	style = Style.PEAKS if str(Settings.get_value(SETTING_STYLE)) == "Peaks" else Style.PEAKS_RMS
	color_mode = ColorMode.SPECTRAL if str(Settings.get_value(SETTING_COLOR_MODE)).begins_with("Spectral") else ColorMode.CLIP_COLOR
	channel_mode = ChannelMode.MONO_SUM if str(Settings.get_value(SETTING_CHANNELS)) == "Mono sum" else ChannelMode.SPLIT
	amp_scale = AmpScale.DB if str(Settings.get_value(SETTING_SCALE)).begins_with("Logarithmic") else AmpScale.LINEAR


func _on_setting_changed(key: String, _value) -> void:
	if key.begins_with("appearance/waveform_"):
		_read_settings()
