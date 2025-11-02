# Waveform.gd
# Represents audio waveform at a specific resolution
# Stores min/max peak pairs for efficient rendering

class_name Waveform extends RefCounted

# ============================================================================
# PROPERTIES
# ============================================================================

## Resolution in samples per pixel
var resolution: int = 256

## Convenience proxy for `resolution`
var samples_per_pixel: int:
	get:
		return resolution
	set(value):
		resolution = value

## Peak data: each Vector2 = (min, max) for one pixel
## For stereo: PackedVector2Array pairs for each channel
var peak_data_left: PackedVector2Array = PackedVector2Array()
var peak_data_right: PackedVector2Array = PackedVector2Array()

## Number of channels (1 or 2)
var channels: int = 1

## Total duration in pixels (width when rendered)
var duration_pixels: int = 0

## Root-mean-square (energy) per pixel
var rms_data_left: PackedFloat32Array = PackedFloat32Array()
var rms_data_right: PackedFloat32Array = PackedFloat32Array()


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

func compute_from_audio(audio_samples: PackedFloat32Array, _sample_rate: int, num_channels: int) -> void:
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

	var local_samples_per_pixel = resolution
	var total_samples = int(float(audio_samples.size()) / max(1.0, float(num_channels)))

	# Calculate pixel count
	duration_pixels = ceili(float(total_samples) / float(local_samples_per_pixel))

	# Clear existing peak + RMS data
	peak_data_left.clear()
	if channels > 1:
		peak_data_right.clear()
	rms_data_left.clear()
	rms_data_right.clear()

	# Compute peaks for each pixel
	for pixel in range(duration_pixels):
		var start_sample = pixel * local_samples_per_pixel
		var end_sample = min(start_sample + local_samples_per_pixel, total_samples)

		# Compute min/max for left channel
		var min_left = 0.0
		var max_left = 0.0
		var sum_sq_left = 0.0

		for sample_idx in range(start_sample, end_sample):
			var interleaved_idx = sample_idx * num_channels
			if interleaved_idx < audio_samples.size():
				var sample = audio_samples[interleaved_idx]
				min_left = min(min_left, sample)
				max_left = max(max_left, sample)
				sum_sq_left += sample * sample

		peak_data_left.append(Vector2(min_left, max_left))
		var block_len_left = max(1, end_sample - start_sample)
		rms_data_left.append(sqrt(sum_sq_left / float(block_len_left)))

		# Compute min/max for right channel if stereo
		if channels > 1:
			var min_right = 0.0
			var max_right = 0.0
			var sum_sq_right = 0.0

			for sample_idx in range(start_sample, end_sample):
				var interleaved_idx = sample_idx * num_channels + 1
				if interleaved_idx < audio_samples.size():
					var sample = audio_samples[interleaved_idx]
					min_right = min(min_right, sample)
					max_right = max(max_right, sample)
					sum_sq_right += sample * sample

			peak_data_right.append(Vector2(min_right, max_right))
			var block_len_right = max(1, end_sample - start_sample)
			rms_data_right.append(sqrt(sum_sq_right / float(block_len_right)))


## Load waveform data from cache-provided peak arrays
func load_from_cache(res: int, num_channels: int, num_blocks: int, channel_peaks: Array, channel_rms: Array = []) -> void:
	resolution = res
	channels = num_channels
	duration_pixels = num_blocks

	if channel_peaks.size() > 0:
		peak_data_left = channel_peaks[0].duplicate()
	else:
		peak_data_left = PackedVector2Array()

	if channels > 1 and channel_peaks.size() > 1:
		peak_data_right = channel_peaks[1].duplicate()
	else:
		peak_data_right = PackedVector2Array()

	if channel_rms.size() > 0:
		rms_data_left = channel_rms[0].duplicate()
	else:
		rms_data_left = PackedFloat32Array()

	if channels > 1 and channel_rms.size() > 1:
		rms_data_right = channel_rms[1].duplicate()
	else:
		rms_data_right = PackedFloat32Array()

	# Safety: ensure RMS arrays align with peaks
	if rms_data_left.size() != peak_data_left.size():
		rms_data_left.resize(peak_data_left.size())
	if channels > 1 and rms_data_right.size() != peak_data_right.size():
		rms_data_right.resize(peak_data_right.size())


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


func get_rms_at_pixel(pixel: int, channel: int = 0) -> float:
	"""Get RMS value for a pixel (channel 0 = left, 1 = right)."""
	if channel == 0:
		if pixel >= 0 and pixel < rms_data_left.size():
			return rms_data_left[pixel]
	else:
		if channel == 1 and pixel >= 0 and pixel < rms_data_right.size():
			return rms_data_right[pixel]
	return 0.0
