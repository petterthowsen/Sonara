# Waveform.gd
# Represents audio waveform at a specific resolution
# Stores min/max peak pairs for efficient rendering

class_name Waveform extends RefCounted

# ============================================================================
# PROPERTIES
# ============================================================================

## Resolution in samples per pixel
var resolution: int = 256

## Peak data: each Vector2 = (min, max) for one pixel
## For stereo: PackedVector2Array pairs for each channel
var peak_data_left: PackedVector2Array = PackedVector2Array()
var peak_data_right: PackedVector2Array = PackedVector2Array()

## Number of channels (1 or 2)
var channels: int = 1

## Total duration in pixels (width when rendered)
var duration_pixels: int = 0


# ============================================================================
# LIFECYCLE
# ============================================================================

func _init(res: int = 256, ch: int = 1) -> void:
	"""Initialize waveform with resolution and channel count."""
	resolution = res
	channels = ch


# ============================================================================
# PEAK COMPUTATION
# ============================================================================

func compute_from_audio(audio_samples: PackedFloat32Array, sample_rate: int, num_channels: int) -> void:
	"""
	Compute peak data from raw audio samples.
	audio_samples: interleaved stereo samples [L, R, L, R, ...]
	sample_rate: samples per second
	num_channels: 1 or 2
	"""
	channels = num_channels

	if audio_samples.is_empty():
		duration_pixels = 0
		return

	var samples_per_pixel = resolution
	var total_samples = audio_samples.size() / num_channels

	# Calculate pixel count
	duration_pixels = ceili(float(total_samples) / float(samples_per_pixel))

	# Clear existing peak data
	peak_data_left.clear()
	if channels > 1:
		peak_data_right.clear()

	# Compute peaks for each pixel
	for pixel in range(duration_pixels):
		var start_sample = pixel * samples_per_pixel
		var end_sample = min(start_sample + samples_per_pixel, total_samples)

		# Compute min/max for left channel
		var min_left = 0.0
		var max_left = 0.0

		for sample_idx in range(start_sample, end_sample):
			var interleaved_idx = sample_idx * num_channels
			if interleaved_idx < audio_samples.size():
				var sample = audio_samples[interleaved_idx]
				min_left = min(min_left, sample)
				max_left = max(max_left, sample)

		peak_data_left.append(Vector2(min_left, max_left))

		# Compute min/max for right channel if stereo
		if channels > 1:
			var min_right = 0.0
			var max_right = 0.0

			for sample_idx in range(start_sample, end_sample):
				var interleaved_idx = sample_idx * num_channels + 1
				if interleaved_idx < audio_samples.size():
					var sample = audio_samples[interleaved_idx]
					min_right = min(min_right, sample)
					max_right = max(max_right, sample)

			peak_data_right.append(Vector2(min_right, max_right))


# ============================================================================
# DATA ACCESS
# ============================================================================

func get_peaks_for_range(start_pixel: int, end_pixel: int) -> Dictionary:
	"""
	Get peak data for a range of pixels.
	Returns: { "left": PackedVector2Array, "right": PackedVector2Array }
	"""
	var clamped_start = clampi(start_pixel, 0, duration_pixels)
	var clamped_end = clampi(end_pixel, 0, duration_pixels)

	var result = {
		"left": peak_data_left.slice(clamped_start, clamped_end),
		"right": peak_data_right.slice(clamped_start, clamped_end) if channels > 1 else PackedVector2Array()
	}

	return result


func get_peak_at_pixel(pixel: int) -> Vector2:
	"""Get peak data for a single pixel (left channel)."""
	if pixel >= 0 and pixel < peak_data_left.size():
		return peak_data_left[pixel]
	return Vector2.ZERO


func get_peak_right_at_pixel(pixel: int) -> Vector2:
	"""Get peak data for a single pixel (right channel, stereo only)."""
	if channels > 1 and pixel >= 0 and pixel < peak_data_right.size():
		return peak_data_right[pixel]
	return Vector2.ZERO
