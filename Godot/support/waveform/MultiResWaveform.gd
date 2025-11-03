# MultiResWaveform.gd
# Multi-resolution waveform pyramid for Level-of-Detail (LOD) rendering
# Composed of several Waveform instances at varying resolutions

class_name MultiResWaveform extends RefCounted

var levels: Array[Waveform] = []


## Check if a specific level is fully loaded and ready to render
func is_level_ready(level_index: int) -> bool:
	"""Returns true if the waveform level is loaded and has valid data."""
	if level_index < 0 or level_index >= levels.size():
		return false

	var waveform = levels[level_index]
	if waveform == null:
		return false

	# Check if waveform has valid data
	return waveform.num_blocks > 0 and waveform.peak_data_left.size() > 0


## Get the best loaded level for rendering at current zoom, or null if nothing is ready
func get_ready_level_for_zoom(pixels_per_beat: float, ppq: int, duration_ticks: int, clip_width_pixels: float) -> Waveform:
	"""Like select_level_for_zoom, but only returns levels that are fully loaded and ready."""
	var candidate = select_level_for_zoom(pixels_per_beat, ppq, duration_ticks, clip_width_pixels)

	if candidate == null:
		return null

	# Check if this level is ready
	var level_idx = levels.find(candidate)
	if is_level_ready(level_idx):
		return candidate

	# If ideal level isn't ready, find any ready level (prefer highest resolution)
	for i in range(levels.size()):
		if is_level_ready(i):
			return levels[i]

	return null


func select_level_for_zoom(pixels_per_beat: float, ppq: int, duration_ticks: int, clip_width_pixels: float) -> Waveform:
	"""Select the best waveform resolution level for current zoom/viewport.

	Calculates samples-per-pixel at the current zoom level and selects the waveform
	level with resolution (block_size) closest to that value. This provides Level-of-Detail (LOD)
	rendering: zoomed-out views use coarser waveforms (large block_size) for performance,
	while zoomed-in views use finer waveforms (small block_size) for detail.

	Args:
		pixels_per_beat: Current horizontal zoom (pixels per beat)
		ppq: Project pulses-per-quarter (typically 960)
		duration_ticks: Clip duration in ticks
		clip_width_pixels: Rendered width of clip in pixels

	Returns:
		Best available Waveform level, or null if no levels loaded
	"""
	# Handle edge cases
	if levels.is_empty():
		return null
	if clip_width_pixels <= 0.0:
		return levels[0] if levels[0] != null else null

	# We need to know how many audio samples we're rendering per pixel
	# to choose the appropriate LOD level.
	#
	# Ideally we'd calculate: samples_per_pixel = total_audio_samples / clip_width_pixels
	# But we don't have total_audio_samples here without the sample rate and recorded_bpm.
	#
	# Instead, we can use: blocks_per_pixel = num_blocks / clip_width_pixels
	# Then compare each level's resolution (samples per block) scaled by blocks_per_pixel
	# to find which level provides roughly 1-3 samples per pixel (good visual resolution).

	# Find level with the best blocks_per_pixel ratio
	var best_level: Waveform = null
	var best_distance = INF

	for level in levels:
		if level == null or level.num_blocks == 0:
			continue

		# Calculate how many blocks this level would need per pixel
		var blocks_per_pixel = float(level.num_blocks) / clip_width_pixels

		# We want roughly 1-2 blocks per pixel for good detail
		# Without too many blocks (performance) or too few (blocky appearance)
		var ideal_blocks_per_pixel = 1.5
		var distance = abs(blocks_per_pixel - ideal_blocks_per_pixel)

		# Prefer higher resolution (more blocks) when zoomed in
		# Prefer lower resolution (fewer blocks) when zoomed out
		if distance < best_distance:
			best_distance = distance
			best_level = level

	# Fallback: return any loaded level (prefer first non-null)
	if best_level == null:
		for level in levels:
			if level != null:
				return level

	return best_level
