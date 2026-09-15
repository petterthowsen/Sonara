# Waveform.gd
# Represents audio waveform at a specific resolution
# Stores min/max peak pairs for efficient rendering

class_name Waveform extends RefCounted

static var logger := Log.make("Waveform")

# ============================================================================
# PROPERTIES
# ============================================================================

## Resolution in samples per pixel
var resolution: int = 256

var num_blocks : int = 0

## Peak data: each Vector2 = (min, max) for one pixel
## For stereo: PackedVector2Array pairs for each channel
var peak_data_left: PackedVector2Array = PackedVector2Array()
var peak_data_right: PackedVector2Array = PackedVector2Array()

## Number of channels (1 or 2)
var channels: int = 1

## Root-mean-square (energy) per pixel
var rms_data_left: PackedFloat32Array = PackedFloat32Array()
var rms_data_right: PackedFloat32Array = PackedFloat32Array()

## Pre-rendered textures for fast drawing (1 pixel per block, 100px height)
## Split into chunks to avoid GPU texture size limits
var texture_chunks_left: Array[ImageTexture] = []
var texture_chunks_right: Array[ImageTexture] = []

## Fixed height for texture rendering
const TEXTURE_HEIGHT: int = 100

## Maximum texture chunk width (to avoid GPU limits, typically 8192-16384)
const TEXTURE_CHUNK_WIDTH: int = 4096


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

## Load waveform data from cache-provided peak arrays
func load_from_cache(res: int, num_channels: int, _num_blocks: int, channel_peaks: Array, channel_rms: Array = []) -> void:
	resolution = res
	channels = num_channels
	num_blocks = _num_blocks

	logger.info("load_from_cache res=%d, channels=%d, num_blocks=%d, channel_peaks.size()=%d" % [res, num_channels, _num_blocks, channel_peaks.size()])

	if channel_peaks.size() > 0:
		peak_data_left = channel_peaks[0].duplicate()
		logger.info("load_from_cache Loaded left: %d peaks" % peak_data_left.size())
	else:
		peak_data_left = PackedVector2Array()

	if channels > 1 and channel_peaks.size() > 1:
		peak_data_right = channel_peaks[1].duplicate()
		logger.info("load_from_cache Loaded right: %d peaks" % peak_data_right.size())
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

	# Generate textures for fast rendering
	generate_textures()


func _to_string() -> String:
	"""Return detailed debug info about this waveform level."""
	var info = "[Waveform] res=%d, channels=%d, num_blocks=%d\n" % [resolution, channels, num_blocks]
	info += "  Left: %d peaks, stats: %s\n" % [peak_data_left.size(), _get_array_stats(peak_data_left)]
	if channels > 1:
		info += "  Right: %d peaks, stats: %s" % [peak_data_right.size(), _get_array_stats(peak_data_right)]
	return info


func _get_array_stats(arr: PackedVector2Array) -> String:
	"""Get statistics about Vector2 array for debugging."""
	if arr.is_empty():
		return "empty"
	var min_x = arr[0].x
	var max_x = arr[0].x
	var min_y = arr[0].y
	var max_y = arr[0].y
	var has_nan = false
	var has_inf = false

	for v in arr:
		if is_nan(v.x) or is_nan(v.y):
			has_nan = true
		if is_inf(v.x) or is_inf(v.y):
			has_inf = true
		min_x = minf(min_x, v.x)
		max_x = maxf(max_x, v.x)
		min_y = minf(min_y, v.y)
		max_y = maxf(max_y, v.y)

	var issues = ""
	if has_nan:
		issues += " [NaN]"
	if has_inf:
		issues += " [Inf]"

	return "x:[%.3f,%.3f] y:[%.3f,%.3f]%s" % [min_x, max_x, min_y, max_y, issues]


# ============================================================================
# TEXTURE RENDERING
# ============================================================================

func generate_textures() -> void:
	"""Generate pre-rendered textures from peak data for fast drawing.

	Creates ImageTextures with:
	- Width: TEXTURE_CHUNK_WIDTH (4096px max per chunk)
	- Height: TEXTURE_HEIGHT (100px)
	- Format: RGBA8 for antialiasing
	- Multiple chunks if num_blocks > TEXTURE_CHUNK_WIDTH

	This allows draw_texture_rect_region to draw waveforms efficiently
	without polygon triangulation on every frame.
	"""
	if num_blocks == 0 or peak_data_left.is_empty():
		return

	# Generate left channel texture chunks
	texture_chunks_left = _generate_channel_texture_chunks(peak_data_left)

	# Generate right channel texture chunks if stereo
	if channels > 1 and not peak_data_right.is_empty():
		texture_chunks_right = _generate_channel_texture_chunks(peak_data_right)


func _generate_channel_texture_chunks(peaks: PackedVector2Array) -> Array[ImageTexture]:
	"""Generate texture chunks from peak data for one channel.

	Splits peak data into chunks of TEXTURE_CHUNK_WIDTH to avoid GPU texture size limits.

	Args:
		peaks: Array of Vector2(min, max) peak pairs

	Returns:
		Array of ImageTextures, each representing a chunk of the waveform
	"""
	var chunks: Array[ImageTexture] = []
	var total_width = peaks.size()

	if total_width == 0:
		return chunks

	# Calculate number of chunks needed
	var num_chunks = ceili(float(total_width) / float(TEXTURE_CHUNK_WIDTH))

	# Generate each chunk
	for chunk_idx in range(num_chunks):
		var chunk_start = chunk_idx * TEXTURE_CHUNK_WIDTH
		var chunk_end = mini(chunk_start + TEXTURE_CHUNK_WIDTH, total_width)
		var chunk_width = chunk_end - chunk_start

		# Create image for this chunk
		var img = Image.create(chunk_width, TEXTURE_HEIGHT, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))  # Transparent background

		# Waveform color (semi-transparent blue matching MidiclipRenderer)
		var color = Color(0.3, 0.6, 0.9, 0.6)

		# Center line (0dB reference)
		var center_y = TEXTURE_HEIGHT / 2.0

		# Draw each block as a vertical line from min to max
		for x in range(chunk_width):
			var peak_idx = chunk_start + x
			if peak_idx >= peaks.size():
				break

			var peak = peaks[peak_idx]

			# Map peak values (-1.0 to 1.0) to pixel coordinates
			# peak.x = min, peak.y = max
			var y_min = center_y - (peak.y * (TEXTURE_HEIGHT / 2.0))  # max value (top)
			var y_max = center_y - (peak.x * (TEXTURE_HEIGHT / 2.0))  # min value (bottom)

			# Clamp to texture bounds
			y_min = clamp(y_min, 0, TEXTURE_HEIGHT - 1)
			y_max = clamp(y_max, 0, TEXTURE_HEIGHT - 1)

			# Draw vertical line from y_min to y_max
			for y in range(int(y_min), int(y_max) + 1):
				img.set_pixel(x, y, color)

		# Convert to texture and add to chunks
		var texture :ImageTexture = ImageTexture.create_from_image(img)
		chunks.append(texture)

	return chunks
