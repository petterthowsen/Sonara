# MultiResWaveform.gd
# Manages multiple resolution levels for efficient waveform rendering at any zoom level
# Precomputes 3 resolution levels and selects the appropriate one for rendering

class_name MultiResWaveform extends RefCounted

# ============================================================================
# PROPERTIES
# ============================================================================

## Three resolution levels: detailed, medium, overview
var waveforms: Array[Waveform] = [null, null, null]

## Resolution values (samples per pixel)
var RESOLUTIONS: Array[int] = [256, 1024, 4096]

## Metadata
var duration_samples: int = 0
var channels: int = 1
var sample_rate: int = 48000


# ============================================================================
# LIFECYCLE
# ============================================================================

func _init() -> void:
	"""Initialize with three empty waveforms."""
	for i in range(3):
		waveforms[i] = Waveform.new(RESOLUTIONS[i], 1)


# ============================================================================
# COMPUTATION
# ============================================================================

func precompute_from_audio(audio_samples: PackedFloat32Array, sr: int, num_channels: int) -> void:
	"""
	Precompute all three resolution levels from raw audio.
	audio_samples: interleaved stereo samples [L, R, L, R, ...]
	sr: sample rate
	num_channels: 1 or 2
	"""
	duration_samples = audio_samples.size() / num_channels
	channels = num_channels
	sample_rate = sr

	# Compute each resolution level
	for i in range(3):
		waveforms[i].channels = num_channels
		waveforms[i].compute_from_audio(audio_samples, sr, num_channels)


# ============================================================================
# WAVEFORM SELECTION
# ============================================================================

func get_waveform_for_resolution(target_resolution: int) -> Waveform:
	"""
	Get the best matching waveform for the target resolution.
	Uses the closest resolution level that doesn't oversimplify.
	target_resolution: samples per pixel desired
	Returns: Waveform at appropriate resolution
	"""
	# Find the best resolution level
	# Strategy: Use the closest resolution, but prefer lower resolution if target is between levels
	# to avoid overshooting detail at high zoom
	var best_idx = 0
	var best_diff = absi(RESOLUTIONS[0] - target_resolution)

	for i in range(1, 3):
		var diff = absi(RESOLUTIONS[i] - target_resolution)
		if diff < best_diff:
			best_diff = diff
			best_idx = i

	return waveforms[best_idx]


func get_waveform_for_zoom(timeline_zoom: float) -> Waveform:
	"""
	Get waveform based on timeline zoom level.
	timeline_zoom: pixels per beat (from Timeline)
	Converts zoom to effective samples-per-pixel and selects waveform.
	"""
	# Assuming ~960 samples per beat at 48kHz sample rate
	var samples_per_beat = 960.0
	var target_resolution = int(samples_per_beat / timeline_zoom)

	return get_waveform_for_resolution(target_resolution)


# ============================================================================
# UTILITY
# ============================================================================

func get_duration_pixels(resolution: int) -> int:
	"""Get duration in pixels for a given resolution."""
	for i in range(3):
		if RESOLUTIONS[i] == resolution:
			return waveforms[i].duration_pixels
	return 0


func get_max_duration_pixels() -> int:
	"""Get maximum duration in pixels (lowest resolution = least pixels)."""
	return waveforms[2].duration_pixels if waveforms[2] else 0
