# AudioFileLoader.gd
# Utility for loading audio files (WAV, MP3) and extracting PCM samples
# Uses Godot's built-in AudioStreamWAV and Waveform classes

class_name AudioFileLoader

# ============================================================================
# AUDIO LOADING
# ============================================================================

static func load_wav(file_path: String) -> Dictionary:
	"""
	Load a WAV file and extract PCM samples using raw WAV parsing.
	IMPORTANT: We use raw parsing instead of Godot's AudioStreamWAV to avoid
	Godot's automatic resampling to the audio output rate (usually 48kHz).
	This ensures we preserve the original file's sample rate (e.g., 44100 Hz).

	Returns: {
		"success": bool,
		"samples": PackedFloat32Array,  # Interleaved stereo samples in range [-1.0, 1.0]
		"sample_rate": int,
		"channels": int,
		"duration_seconds": float,
		"error": String (if failed)
	}
	"""
	# Check if file exists
	if not FileAccess.file_exists(file_path):
		return {
			"success": false,
			"error": "File not found: %s" % file_path
		}

	# Use raw WAV parsing to preserve original sample rate
	# Godot's AudioStreamWAV may resample to audio output rate (48kHz) which breaks timing
	return _load_wav_raw(file_path)


static func load_flac(file_path: String) -> Dictionary:
	"""
	Load a FLAC file and extract PCM samples.
	Note: Godot 4.2+ may support FLAC via AudioStreamOggVorbis or through GDExtension.
	For now, we return an error and recommend using WAV.
	"""
	return {
		"success": false,
		"error": "FLAC support not yet implemented. Please use WAV format for now."
	}


static func load_audio_file(file_path: String) -> Dictionary:
	"""
	Load any supported audio file format.
	Automatically detects format from file extension.
	"""
	var ext = file_path.get_extension().to_lower()

	match ext:
		"wav":
			return load_wav(file_path)
		"flac":
			return load_flac(file_path)
		_:
			return {
				"success": false,
				"error": "Unsupported audio format: .%s" % ext
			}


# ============================================================================
# UTILITY
# ============================================================================

static func _load_wav_raw(file_path: String) -> Dictionary:
	"""
	Load WAV file directly from filesystem using raw file I/O.
	Parses RIFF/WAV format for PCM data. Handles various channel counts and bit depths.
	"""
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return {
			"success": false,
			"error": "Failed to open file: %s" % file_path
		}

	# Read and validate RIFF header
	var riff_header = file.get_buffer(4).get_string_from_utf8()
	if riff_header != "RIFF":
		return {
			"success": false,
			"error": "Not a valid WAV file (missing RIFF header)"
		}

	file.get_32()  # Skip file size (4 bytes)

	var wave_header = file.get_buffer(4).get_string_from_utf8()
	if wave_header != "WAVE":
		return {
			"success": false,
			"error": "Not a valid WAV file (missing WAVE header)"
		}

	# Find and parse fmt chunk
	var fmt_data = _find_wav_chunk(file, "fmt ")
	if fmt_data.is_empty():
		return {
			"success": false,
			"error": "No fmt chunk found in WAV"
		}

	# Parse fmt chunk (minimum 16 bytes)
	if fmt_data.size() < 16:
		return {
			"success": false,
			"error": "fmt chunk too small"
		}

	var audio_format = fmt_data[0] | (fmt_data[1] << 8)
	var num_channels = fmt_data[2] | (fmt_data[3] << 8)
	var sample_rate = fmt_data[4] | (fmt_data[5] << 8) | (fmt_data[6] << 16) | (fmt_data[7] << 24)
	var bits_per_sample = fmt_data[14] | (fmt_data[15] << 8)

	# Only support PCM (format 1) and IEEE Float (format 3)
	if audio_format != 1 and audio_format != 3:
		return {
			"success": false,
			"error": "Unsupported audio format: %d (only PCM and IEEE Float supported)" % audio_format
		}

	# Find data chunk
	var data_chunk = _find_wav_chunk(file, "data")
	if data_chunk.is_empty():
		return {
			"success": false,
			"error": "No data chunk found in WAV"
		}

	# Parse PCM data based on bit depth
	var samples = PackedFloat32Array()
	var bytes_per_sample = bits_per_sample / 8

	match bits_per_sample:
		8:
			# 8-bit PCM (unsigned)
			for i in range(0, data_chunk.size(), num_channels):
				for ch in range(num_channels):
					if i + ch < data_chunk.size():
						var sample_byte = data_chunk[i + ch]
						# Convert unsigned 8-bit to signed (-128 to 127)
						var sample_signed = int(sample_byte) - 128
						var sample_float = float(sample_signed) / 128.0
						samples.append(sample_float)

		16:
			# 16-bit PCM (signed, little-endian)
			for i in range(0, data_chunk.size(), num_channels * 2):
				for ch in range(num_channels):
					var offset = i + ch * 2
					if offset + 1 < data_chunk.size():
						var byte1 = data_chunk[offset]
						var byte2 = data_chunk[offset + 1]
						var sample_int = byte1 | (byte2 << 8)

						# Convert to signed 16-bit
						if sample_int > 32767:
							sample_int -= 65536

						var sample_float = float(sample_int) / 32768.0
						samples.append(sample_float)

		24:
			# 24-bit PCM (signed, little-endian)
			for i in range(0, data_chunk.size(), num_channels * 3):
				for ch in range(num_channels):
					var offset = i + ch * 3
					if offset + 2 < data_chunk.size():
						var byte1 = data_chunk[offset]
						var byte2 = data_chunk[offset + 1]
						var byte3 = data_chunk[offset + 2]
						var sample_int = byte1 | (byte2 << 8) | (byte3 << 16)

						# Convert to signed 24-bit
						if sample_int > 8388607:
							sample_int -= 16777216

						var sample_float = float(sample_int) / 8388608.0
						samples.append(sample_float)

		32:
			if audio_format == 3:
				# 32-bit IEEE Float
				for i in range(0, data_chunk.size(), num_channels * 4):
					for ch in range(num_channels):
						var offset = i + ch * 4
						if offset + 3 < data_chunk.size():
							var bytes = [data_chunk[offset], data_chunk[offset+1],
									   data_chunk[offset+2], data_chunk[offset+3]]
							var sample_float = bytes_to_float32(bytes)
							samples.append(sample_float)
			else:
				# 32-bit PCM (signed, little-endian)
				for i in range(0, data_chunk.size(), num_channels * 4):
					for ch in range(num_channels):
						var offset = i + ch * 4
						if offset + 3 < data_chunk.size():
							var byte1 = data_chunk[offset]
							var byte2 = data_chunk[offset + 1]
							var byte3 = data_chunk[offset + 2]
							var byte4 = data_chunk[offset + 3]
							var sample_int = byte1 | (byte2 << 8) | (byte3 << 16) | (byte4 << 24)

							# Convert to signed 32-bit
							if sample_int > 2147483647:
								sample_int -= 4294967296

							var sample_float = float(sample_int) / 2147483648.0
							samples.append(sample_float)

		_:
			return {
				"success": false,
				"error": "Unsupported bit depth: %d (8, 16, 24, 32 supported)" % bits_per_sample
			}

	# Calculate actual sample count per channel
	var sample_count = samples.size() / num_channels

	# Limit to max 2 channels for now (mix down if needed)
	var output_channels = min(num_channels, 2)
	if num_channels > 2:
		# Mix down to stereo (simple average for channels beyond 2)
		var mixed_samples = PackedFloat32Array()
		for i in range(sample_count):
			var left = samples[i * num_channels]
			var right = samples[i * num_channels + 1] if num_channels > 1 else left
			mixed_samples.append(left)
			mixed_samples.append(right)
		samples = mixed_samples
		num_channels = 2

	var duration = float(sample_count) / float(sample_rate)

	return {
		"success": true,
		"samples": samples,
		"sample_rate": sample_rate,
		"channels": num_channels,
		"duration_seconds": duration
	}


static func _find_wav_chunk(file: FileAccess, chunk_id: String) -> PackedByteArray:
	"""Find and return the data of a WAV chunk."""
	file.seek(12)  # Skip RIFF header (4) + size (4) + WAVE (4)

	while file.get_position() < file.get_length():
		var chunk_header = file.get_buffer(4)
		if chunk_header.size() < 4:
			break

		var current_chunk_id = chunk_header.get_string_from_utf8()
		var chunk_size = file.get_32()

		if current_chunk_id == chunk_id:
			return file.get_buffer(chunk_size)
		else:
			# Skip to next chunk (chunks must be word-aligned)
			var padded_size = chunk_size + (chunk_size % 2)
			file.seek(file.get_position() + padded_size)

	return PackedByteArray()


static func bytes_to_float32(bytes: Array) -> float:
	"""Convert 4 bytes (little-endian) to IEEE 754 float."""
	if bytes.size() != 4:
		return 0.0

	var bits = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)

	# Handle sign bit
	var sign = 1.0 if (bits & 0x80000000) == 0 else -1.0

	# Extract exponent (8 bits, biased by 127)
	var exponent = ((bits >> 23) & 0xFF) - 127

	# Extract mantissa (23 bits) and add implicit leading 1
	var mantissa = 1.0 + float(bits & 0x7FFFFF) / (1 << 23)

	# Special cases
	if exponent == -127:
		return 0.0  # Zero or subnormal
	if exponent == 128:
		return sign * INF if (bits & 0x7FFFFF) == 0 else NAN  # Infinity or NaN

	return sign * mantissa * pow(2.0, float(exponent))


static func get_duration_ticks(sample_count: int, sample_rate: int, ppq: int = 960) -> int:
	"""
	Convert sample count to ticks.
	ppq: pulses per quarter note (default 960)
	Assumes: 1 beat = 1 quarter note
	Formula: ticks = (sample_count / sample_rate) * tempo_beats_per_second * ppq
	For now, assuming 120 BPM = 2 beats per second
	"""
	var duration_seconds = float(sample_count) / float(sample_rate)
	var beats = duration_seconds * 2.0  # Assume 120 BPM = 2 beats/second
	var ticks = int(beats * ppq)
	return ticks
