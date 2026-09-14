@tool
## Renders a audio spectrum in a variety of styles
## drawn at the size of the control.
##
## The spectrum is expected to be in dBFS (-160 to 0) from the engine usually.
## The renderer will lerp the spectrum buffer towards the new data, according to the smoothing factor.
##
## The renderer will also draw a background, a frequency grid, a dB grid, and the spectrum.
##
## The renderer will also draw a legend and labels.
class_name SpectrumRenderer extends Control

# ============================================================================
# STYLING
# ============================================================================

enum Style {
	BINS, # render as vertical thin lines
	BARS, # render as vertical bars (width = freq bin width)
	LINE, # render as a single connected line of points for each freq bin
	FILL, # render as a Polyline but filled to the bottom of the control
}

@export var style: Style = Style.BINS:
	set(val):
		style = val
		queue_redraw()

@export var style_bg_color: Color = Color.DIM_GRAY:
	set(val):
		style_bg_color = val
		queue_redraw()

@export var style_line_color: Color = Color.WHITE:
	set(val):
		style_line_color = val
		queue_redraw()

@export var style_fill_color: Color = Color.YELLOW:
	set(val):
		style_fill_color = val
		queue_redraw()

@export var style_bin_width: float = 1.0:
	set(val):
		style_bin_width = val
		queue_redraw()

@export var style_bin_spacing: float = 1.0:
	set(val):
		style_bin_spacing = val
		queue_redraw()

@export var style_line_width: float = 1.0:
	set(val):
		style_line_width = val
		queue_redraw()

@export var style_grid_color: Color = Color.WHITE:
	set(val):
		style_grid_color = val
		queue_redraw()

@export var style_grid_width: float = 1.0:
	set(val):
		style_grid_width = val
		queue_redraw()

# ============================================================================
# CONFIGURATION & STATE
# ============================================================================

var sample_rate: float = 44100.0:
	set(val):
		sample_rate = val
		input_frequency_max = sample_rate / 2.0
		_rebuild_axis_cache()

# 0.0 or DC, engine forces it to -160dB.
var input_frequency_min : float = 0.0:
	set(fm):
		input_frequency_min = fm
		_rebuild_axis_cache()
	
var input_frequency_max : float = 44100.0 / 2.0:
	set(fm):
		input_frequency_max = fm
		_rebuild_axis_cache()

# Input dBFS range (-160 to 0)
# This is needed to convert the input spectrum to the correct range for the renderer.
var input_db_floor: float = -160.0
var input_db_max: float = 0.0

# Frequency scale for X-axis
enum FrequencyScale {
	Log, # Logarithmic scale (10x increments)
	Linear, # Linear scale (1x increments)
}
@export var freq_scale: FrequencyScale = FrequencyScale.Log:
	set(val):
		freq_scale = val
		_mark_x_cache_dirty()
		queue_redraw()


# The range of frequencies to render
enum FrequencyRange {
	HumanEar, # 20 Hz to 21 kHz
	SampleRate, # 20 Hz to sample rate / 2
}

@export var frequency_range: FrequencyRange = FrequencyRange.HumanEar:
	set(val):
		frequency_range = val
		_rebuild_axis_cache()
		queue_redraw()

var frequency_range_min: float:
	get:
		match frequency_range:
			FrequencyRange.HumanEar:
				return 20.0
			_:
				return 0.0

var frequency_range_max: float:
	get:
		match frequency_range:
			FrequencyRange.HumanEar:
				return 44100.0 / 2.0
			_:
				return 44100.0 / 2.0

var _view_fmin: float
var _view_fmax: float
var _lin_span_inv: float
var _log_min: float
var _log_span_inv: float

# Cache of per-bin x positions (index -> pixel x), rebuilt only when size,
# bin count, frequency range, or freq_scale change. Index n (bin count) is
# also cached since _draw_bars looks one bin ahead.
var _x_cache: PackedFloat32Array = PackedFloat32Array()
var _x_cache_dirty: bool = true

# Reused point buffers to avoid per-frame allocation in _draw_line / _draw_fill.
var _line_points: PackedVector2Array = PackedVector2Array()
var _fill_points: PackedVector2Array = PackedVector2Array()

func _mark_x_cache_dirty() -> void:
	_x_cache_dirty = true

# Called whenever sample_rate, frequency_range, frequency_range_min/max, or freq_scale change.
func _rebuild_axis_cache() -> void:
	# View bounds (zoom window)
	_view_fmin = max(1e-6, frequency_range_min) # avoid log(0)
	_view_fmax = clamp(frequency_range_max, _view_fmin * 1.000001, input_frequency_max)

	# Linear
	_lin_span_inv = 1.0 / max(1e-9, _view_fmax - _view_fmin)

	# Log
	_log_min = log(_view_fmin)
	_log_span_inv = 1.0 / max(1e-12, log(_view_fmax) - _log_min)

	_mark_x_cache_dirty()

# Recomputes _x_cache (index -> pixel x) for every bin plus one extra slot
# (bin count), lazily on next access if dirty or wrongly sized.
func _rebuild_x_cache() -> void:
	var n := _spectrum.size()
	if _x_cache.size() != n + 1:
		_x_cache.resize(n + 1)
	for i in range(n + 1):
		_x_cache[i] = _index_to_x(float(i))
	_x_cache_dirty = false

## Cached equivalent of _index_to_x(float(index)) for integer bin indices
## (0..spectrum.size() inclusive). Rebuilds the cache lazily when needed.
func _cached_index_to_x(index: int) -> float:
	if _x_cache_dirty or _x_cache.size() != _spectrum.size() + 1:
		_rebuild_x_cache()
	return _x_cache[index]

# View window for rendering (y-axis)
@export var db_range_min: float = -100.0:
	set(val):
		db_range_min = val
		queue_redraw()

@export var db_range_max: float = 0.0:
	set(val):
		db_range_max = val
		queue_redraw()

# Visualization resolution (also convenient for UI mapping)
enum Resolution { Tiny, Small, Medium, Large }

@export var resolution: Resolution = Resolution.Medium:
	set(val):
		resolution = val
		# Map to common FFT sizes
		match resolution:
			Resolution.Tiny:
				fft_size = 512
			Resolution.Small:
				fft_size = 1024
			Resolution.Medium:
				fft_size = 2048
			_:
				fft_size = 4096
		
		print("FFT Size: ", fft_size)
		_rebuild_axis_cache()
		queue_redraw()

@export var fft_size: int = 2048:
	set(val):
		fft_size = max(8, val)
		_ensure_spectrum_capacity()
		_rebuild_axis_cache()
		queue_redraw()

func _ensure_spectrum_capacity() -> void:
	# Keep internal buffer sized to expected FFT bin count if known
	var expected_bins = int(fft_size / 2) + 1
	if expected_bins <= 0:
		return
	if _spectrum.size() != expected_bins:
		_spectrum.resize(expected_bins)
		for i in range(expected_bins):
			_spectrum[i] = input_db_floor
		_mark_x_cache_dirty()

# Smoothing factor for the spectrum
# Controls lerp between current and new spectrum values
# If 1.0: Hold/Freezes (The spectrum updates immediately, but only upwards.
@export var smoothing: float = 0.7:
	set(val):
		smoothing = val
		queue_redraw()

# Current spectrum data (not normalized)
# Values are in input_db_floor to input_db_max range
# size is == to input_spectrum.size()
var _spectrum: PackedFloat32Array = PackedFloat32Array()

# Editor-only test helpers
var _generate_noise_flag: bool = false
@export var generate_test_noise: bool:
	get:
		return _generate_noise_flag
	set(val):
		# One-shot button: when set to true in Inspector, generate noise and reset
		if val:
			_generate_noise_flag = false
			_generate_test_noise()
			queue_redraw()


func _ready():
	_rebuild_axis_cache()
	_ensure_spectrum_capacity()
	resized.connect(_mark_x_cache_dirty)


## Update the visualizer with fresh data and queues a redraw.
## @param spectrum: values in dBFS (-160 to 0) from the engine usually.
## 
## This lerps our spectrum buffer towards the new data, according to the smoothing factor.
## TODO: use separate smoothing values for attack and release type behavior?
## Minor potential issue in the future: If we don't call update_spectrum at 60hz, lerp will need a delta value for consistent smoothing behavior.
func update_spectrum(spectrum: PackedFloat32Array) -> void:
	# Ensure our internal buffer matches incoming resolution
	if _spectrum.size() != spectrum.size():
		_spectrum.resize(spectrum.size())
		for i in range(spectrum.size()):
			_spectrum[i] = spectrum[i]
		_mark_x_cache_dirty()

	if smoothing >= 1.0:
		# freeze mode: only update upwards
		for i in range(spectrum.size()):
			var val = spectrum[i]
			if val > _spectrum[i]:
				_spectrum[i] = lerp(_spectrum[i], val, 0.7)
	else:
		# normal mode: lerp between current and new values
		for i in range(spectrum.size()):
			_spectrum[i] = lerp(_spectrum[i], spectrum[i], 1.0 - smoothing)
	
	queue_redraw()


func _generate_test_noise() -> void:
	var _rng := RandomNumberGenerator.new()

	# Ensure some capacity based on fft_size if buffer is empty
	if _spectrum.size() == 0:
		_ensure_spectrum_capacity()
	
	_rng.randomize()
	var n := _spectrum.size()
	for i in range(n):
		var t = float(i) / max(1.0, float(n - 1))
		
		# Tilted pink-ish noise profile with random variation
		var tilt = -0 * t
		var jitter = _rng.randf_range(0.0, 0.0)
		var db = clamp(tilt + jitter, input_db_floor, input_db_max)
		_spectrum[i] = db


# ============================================================================
# HELPERS
# ============================================================================
# NEW FREQ FUNCS:

# given a frequency, return a normalized value (0.0 to 1.0)
# by mapping it to the input_frequency_min and input_frequency_max range
# which is between 0.0 and 22050.0
# no clamping is applied
func _frequency_to_normalized(f: float) -> float:
	return (f - _view_fmin) * _lin_span_inv          # no clamp

func _frequency_to_log_normalized(f: float) -> float:
	var f_safe : float = max(f, 1e-6)                        # DC safe
	return (log(f_safe) - _log_min) * _log_span_inv   # no clamp

## Convert an index (0 to spectrum.size()-1) to a normalized value (0.0 to 1.0)
func _index_to_normalized(index: int) -> float:
	var n = max(1, _spectrum.size() - 1)
	return float(index) / float(n)

## index may be fractional; bin center Hz
func _index_to_frequency(index: float) -> float:
	return index * (sample_rate / fft_size)

func _frequency_to_index(frequency: float) -> float:
	return frequency * (fft_size / sample_rate)

func _frequency_to_x(frequency: float) -> float:
	var n :=  _frequency_to_log_normalized(frequency) if (freq_scale == FrequencyScale.Log) else _frequency_to_normalized(frequency)

	# keep a tiny margin if you like; otherwise just n * size.x
	var margin := 1.0
	var w := size.x - 1.0
	return margin + n * max(0.0, w - 2.0 * margin)


## Convert an index to x position in pixels
func _index_to_x(index: float) -> float:
	var f := _index_to_frequency(index)  # k * (sample_rate / fft_size)
	return _frequency_to_x(f)


## Convert a normalized value (0.0 to 1.0) to a db value between input_db_floor (-160) and input_db_max (0)
func _normalized_to_db(normalized: float) -> float:
	return input_db_floor + normalized * (input_db_max - input_db_floor)

## Convert a db value (-160 to 0) to a normalized value (0.0 to 1.0)
func _db_to_normalized(db: float) -> float:
	return remap(db, input_db_floor, input_db_max, 0.0, 1.0)


# 0.0 at db_range_min (bottom), 1.0 at db_range_max (top)
func _db_to_view_ratio(db: float) -> float:
	return clamp((db - db_range_min) / (db_range_max - db_range_min), 0.0, 1.0)

# Pixel y (top-down)
func _db_to_y(db: float) -> float:
	return (1.0 - _db_to_view_ratio(db)) * size.y

# ============================================================================
# RENDERING
# ============================================================================

## Draw the entire spectrum renderer
## Override this to draw differently.
func _draw() -> void:
	_draw_background(style_bg_color)
	_draw_frequency_grid(style_grid_color, style_grid_width)
	_draw_db_grid(style_grid_color, style_grid_width)
	_draw_spectrum()


# Draws the background color
func _draw_background(bg_color: Color) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color)


func _draw_frequency_grid(color: Color, thickness: float) -> void:
	var height := size.y
	var freqs = [20.0, 100.0, 1000.0, 10000.0]

	for f in freqs:
		if f < _view_fmin or f > _view_fmax:
			continue
		var x := _frequency_to_x(f)
		draw_line(Vector2(x, 0.0), Vector2(x, height), color, thickness, true)
		var label := Midi.frequency_text(f)
		draw_string(get_theme_default_font(), Vector2(x, 32), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)

	# Left/right bounds of the *view* (optional visual cue)
	draw_line(Vector2(_frequency_to_x(_view_fmin), 0.0), Vector2(_frequency_to_x(_view_fmin), height), color, thickness, true)
	draw_line(Vector2(_frequency_to_x(_view_fmax), 0.0), Vector2(_frequency_to_x(_view_fmax), height), color, thickness, true)


func _draw_db_grid(color: Color, thickness: float) -> void:
	# Draw horizontal lines every 10 dB within the current view window
	var start_step = int(ceil(db_range_min / 10.0)) * 10
	var end_step = int(floor(db_range_max / 10.0)) * 10
	for db in range(start_step, end_step + 1, 10):
		var y = _db_to_y(float(db))
		draw_line(Vector2(0.0, y), Vector2(size.x, y), color, thickness, true)


func _draw_spectrum() -> void:
	match style:
		Style.BINS:
			_draw_bins(style_fill_color, style_bin_width)
		Style.BARS:
			_draw_bars(style_fill_color, style_bin_spacing)
		Style.LINE:
			_draw_line(style_fill_color, style_line_width)
		Style.FILL:
			_draw_fill(style_fill_color)


## Draws the spectrum as bars (width = freq bin width)
func _draw_bars(color: Color, spacing: float = 1.0) -> void:
	var group_start_x := NAN
	var group_width := 0.0
	var group_val := input_db_floor
	var min_width := 1.0 + spacing

	for i in range(_spectrum.size()):
		var x := _cached_index_to_x(i)
		var next_x := _cached_index_to_x(i + 1)
		var f := _index_to_frequency(i)

		if is_nan(group_start_x):
			group_start_x = x
		group_width += (next_x - x)
		group_val = max(group_val, _spectrum[i])

		if group_width >= min_width:
			if group_val > db_range_min and f >= frequency_range_min and f <= frequency_range_max:
				_draw_bar(group_start_x, group_width, group_val, spacing, color)
			group_start_x = NAN
			group_width = 0.0
			group_val = input_db_floor


func _draw_bar(x: float, w: float, val : float, spacing: float = 1.0, color: Color = Color.WHITE) -> void:
	var y = _db_to_y(val)
	draw_rect(Rect2(x, y, w - spacing, size.y - y), color, true, -1.0, true)


func _draw_bins(color : Color, thickness: float = 1.0) -> void:
	for i in range(_spectrum.size()):
		var x = _cached_index_to_x(i)
		var y = _db_to_y(_spectrum[i])
		draw_line(Vector2(x, y), Vector2(x, size.y), color, thickness, true)


func _draw_line(color: Color, width: float) -> void:
	var n := _spectrum.size()
	if _line_points.size() != n:
		_line_points.resize(n)
	for i in range(n):
		_line_points[i] = Vector2(_cached_index_to_x(i), _db_to_y(_spectrum[i]))

	draw_polyline(_line_points, color, width, true)


func _draw_fill(fill_color: Color) -> void:
	var n := _spectrum.size()
	if _fill_points.size() != n + 2:
		_fill_points.resize(n + 2)

	for i in range(n):
		_fill_points[i] = Vector2(_cached_index_to_x(i), _db_to_y(_spectrum[i]))

	# Close the polygon to the bottom
	_fill_points[n] = Vector2(size.x, size.y)
	_fill_points[n + 1] = Vector2(0.0, size.y)
	draw_colored_polygon(_fill_points, fill_color)
