# MultiResWaveform.gd
# Manages multiple resolution levels for efficient waveform rendering at any zoom level
# Precomputes 3 resolution levels and selects the appropriate one for rendering

class_name MultiResWaveform extends RefCounted

# ============================================================================
# PROPERTIES
# ============================================================================

## Waveform levels ({"level": int, "block_size": int, "waveform": Waveform})
var levels: Array = []

## Lookup map level -> index within `levels`
var _level_lookup: Dictionary = {}

## Metadata
var duration_samples: int = 0
var channels: int = 1
var sample_rate: int = 48000


# ============================================================================
# LIFECYCLE
# ============================================================================

func _init() -> void:
	reset()


func reset() -> void:
	levels.clear()
	_level_lookup.clear()
	duration_samples = 0
	channels = 1
	sample_rate = 48000


func set_metadata(frames: int, sr: int, num_channels: int) -> void:
	# Only overwrite duration_samples if we're given valid frame data (frames > 0)
	# This preserves duration_samples if it was already calculated from waveform levels
	if frames > 0:
		duration_samples = frames

	sample_rate = sr
	channels = max(1, num_channels)


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
	reset()
	if num_channels <= 0:
		num_channels = 1
	duration_samples = int(float(audio_samples.size()) / max(1.0, float(num_channels)))
	channels = num_channels
	sample_rate = sr

	var default_resolutions = [256, 1024, 4096]
	for i in range(default_resolutions.size()):
		var resolution = default_resolutions[i]
		var waveform = Waveform.new(resolution, num_channels)
		waveform.compute_from_audio(audio_samples, sr, num_channels)
		_store_level(i, resolution, waveform)


func ingest_cache_level(level_index: int, block_size: int, num_blocks: int, channel_peaks: Array, channel_rms: Array = []) -> void:
	"""Add or replace a waveform level generated from cache data."""
	var waveform = Waveform.new(block_size, channels)
	waveform.load_from_cache(block_size, channels, num_blocks, channel_peaks, channel_rms)
	_store_level(level_index, block_size, waveform)

	# Calculate duration_samples from the finest resolution level (smallest block_size)
	# Each level has: duration = num_blocks * block_size
	# The finest level gives the most accurate duration
	if num_blocks > 0 and block_size > 0:
		var calculated_duration = num_blocks * block_size
		if duration_samples <= 0:
			# First level to set it
			duration_samples = calculated_duration
		else:
			# Update if this level is finer (smaller block_size) than what we calculated before
			# Find the current finest block_size
			var finest_block_size = int(1e9)  # Start with large number
			for entry in levels:
				var bs = entry.get("block_size", 0)
				if bs > 0 and bs < finest_block_size:
					finest_block_size = bs

			# If this new level is the finest, recalculate duration
			if block_size <= finest_block_size:
				duration_samples = calculated_duration


func has_level(level_index: int) -> bool:
	return _level_lookup.has(level_index)


func get_level_info(level_index: int) -> Dictionary:
	if not _level_lookup.has(level_index):
		return {}
	return levels[_level_lookup[level_index]]


func get_available_block_sizes() -> PackedInt32Array:
	var result := PackedInt32Array()
	for entry in levels:
		result.append(entry.get("block_size", 0))
	return result


func _store_level(level_index: int, block_size: int, waveform: Waveform) -> void:
	var entry = {
		"level": level_index,
		"block_size": block_size,
		"waveform": waveform
	}

	var replaced = false
	for i in range(levels.size()):
		if levels[i].get("level") == level_index:
			levels[i] = entry
			replaced = true
			break

	if not replaced:
		levels.append(entry)

	levels.sort_custom(func(a, b): return a.get("block_size", 0) < b.get("block_size", 0))
	_rebuild_lookup()


func _rebuild_lookup() -> void:
	_level_lookup.clear()
	for i in range(levels.size()):
		_level_lookup[levels[i].get("level")] = i


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
	if levels.is_empty():
		return null

	if target_resolution <= 0:
		return levels[0]["waveform"]

	var best_entry = levels[0]
	var best_diff = abs(best_entry.get("block_size", 0) - target_resolution)

	for entry in levels:
		var block_size = entry.get("block_size", 0)
		var diff = abs(block_size - target_resolution)
		if diff < best_diff:
			best_entry = entry
			best_diff = diff

	return best_entry.get("waveform")


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
	for entry in levels:
		if entry.get("block_size") == resolution:
			var waveform: Waveform = entry.get("waveform")
			return waveform.duration_pixels if waveform else 0
	return 0


func get_max_duration_pixels() -> int:
	"""Get maximum duration in pixels (lowest resolution = least pixels)."""
	if levels.is_empty():
		return 0
	var waveform: Waveform = levels.back().get("waveform")
	return waveform.duration_pixels if waveform else 0
