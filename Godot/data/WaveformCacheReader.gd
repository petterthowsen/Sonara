## WaveformCacheReader.gd
# Lightweight reader for engine-generated waveform cache files (.swf)
# Mirrors Engine's waveform_cache.rs structure (little-endian binary)

class_name WaveformCacheReader extends RefCounted

const MAGIC_STRING := "SONAWRM1"

var file_path: String = ""
var header: Dictionary = {}
var level_metadata: Array = []

var _is_loaded: bool = false


func load(path: String) -> bool:
	"""Load cache header + directory metadata."""
	_reset()
	if path.is_empty() or not FileAccess.file_exists(path):
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	file.big_endian = false

	var magic := file.get_buffer(8)
	if magic.size() != 8 or magic.get_string_from_ascii() != MAGIC_STRING:
		file.close()
		return false

	var version := file.get_16()
	if version != 1:
		file.close()
		return false

	var channels := file.get_16()
	var sample_rate := file.get_32()
	var frames := file.get_64()
	var levels_count := file.get_16()
	var dir_offset := file.get_64()

	header = {
		"version": version,
		"channels": int(channels),
		"sample_rate": int(sample_rate),
		"frames": int(frames),
		"levels": int(levels_count),
		"dir_offset": int(dir_offset)
	}

	file.seek(dir_offset)
	for i in range(levels_count):
		var meta := _read_level_metadata(file)
		if meta.is_empty():
			file.close()
			_reset()
			return false
		meta["index"] = i
		level_metadata.append(meta)

	file.close()
	file_path = path
	_is_loaded = true
	return true


func is_loaded() -> bool:
	return _is_loaded


func read_level(level_index: int, channel_count: int = -1) -> Dictionary:
	"""Read peak/rms data for a cache level. Returns empty dictionary if unavailable."""
	if not _is_loaded:
		return {}
	if level_index < 0 or level_index >= level_metadata.size():
		return {}

	var meta: Dictionary = level_metadata[level_index]
	var block_size: int = int(meta.get("block_size", 0))
	var num_blocks: int = int(meta.get("num_blocks", 0))
	if num_blocks <= 0:
		return {
			"block_size": block_size,
			"num_blocks": num_blocks,
			"peaks": [],
			"rms": []
		}

	if channel_count <= 0:
		channel_count = header.get("channels", 1)
	channel_count = max(1, channel_count)

	var offsets: PackedInt64Array = meta.get("channel_offsets", PackedInt64Array())
	if offsets.is_empty():
		return {}

	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return {}
	file.big_endian = false
	var file_length := file.get_length()

	var values_per_channel := num_blocks * 3
	var bytes_per_channel := values_per_channel * 4

	var peaks: Array = []
	var rms: Array = []

	for ch in range(min(channel_count, offsets.size())):
		var offset := int(offsets[ch])
		if offset < 0 or offset + bytes_per_channel > file_length:
			continue

		file.seek(offset)
		var channel_peaks := PackedVector2Array()
		var channel_rms := PackedFloat32Array()

		for block in range(num_blocks):
			var min_val := file.get_float()
			var max_val := file.get_float()
			var rms_val := file.get_float()
			channel_peaks.append(Vector2(min_val, max_val))
			channel_rms.append(rms_val)

		peaks.append(channel_peaks)
		rms.append(channel_rms)

	file.close()

	return {
		"block_size": block_size,
		"num_blocks": num_blocks,
		"peaks": peaks,
		"rms": rms
	}


func _read_level_metadata(file: FileAccess) -> Dictionary:
	var level := file.get_16()
	var block_size := file.get_32()
	var num_blocks := file.get_64()
	var vec_len := file.get_64()

	if file.get_error() != OK:
		return {}

	var offsets := PackedInt64Array()
	for _i in range(int(vec_len)):
		offsets.append(file.get_64())

	return {
		"level": int(level),
		"block_size": int(block_size),
		"num_blocks": int(num_blocks),
		"channel_offsets": offsets
	}


func _reset() -> void:
	file_path = ""
	header = {}
	level_metadata.clear()
	_is_loaded = false

