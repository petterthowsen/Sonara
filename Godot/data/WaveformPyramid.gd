## WaveformPyramid.gd
## Multi-resolution waveform for decoded audio (an audio Clip or a Sampler DeviceInstance).
## Fed by the engine's AudioFileService: /audiofile/decode/ready gives metadata and the cache
## key, then /audiofile/waveform/level arrives once per level, read from the cache file.
class_name WaveformPyramid extends RefCounted

static var logger := Log.make("WaveformPyramid")

signal waveform_level_updated(level: int)
signal metadata_changed()

var audio_waveform: MultiResWaveform = null
var waveform_cache_path: String = ""
var waveform_cache_key: String = ""
var audio_channels: int = 2
var audio_frames: int = 0
var audio_sample_rate: int = 44100
var audio_duration_seconds: float = 0.0
var _waveform_cache_reader: WaveformCacheReader = null


## Clear cache state so a new file can load into this helper.
func reset() -> void:
	audio_waveform = null
	waveform_cache_path = ""
	waveform_cache_key = ""
	audio_frames = 0
	audio_duration_seconds = 0.0
	_waveform_cache_reader = null
	metadata_changed.emit()


## Record cache file location used by subsequent level ingests.
func set_waveform_cache(path: String, cache_key: String) -> void:
	if path != waveform_cache_path:
		_waveform_cache_reader = null
	waveform_cache_path = path
	waveform_cache_key = cache_key


## Store decoded PCM metadata (no samples on the Godot side).
func set_audio_metadata(sample_rate: int, channels: int, frames: int, duration_seconds: float = -1.0) -> void:
	audio_sample_rate = maxi(1, sample_rate)
	audio_channels = maxi(1, channels)
	audio_frames = maxi(0, frames)
	if duration_seconds >= 0.0:
		audio_duration_seconds = duration_seconds
	elif audio_sample_rate > 0:
		audio_duration_seconds = float(audio_frames) / float(audio_sample_rate)
	else:
		audio_duration_seconds = 0.0
	metadata_changed.emit()


## Create the multi-resolution container if needed.
func ensure_audio_waveform() -> void:
	if audio_waveform == null:
		audio_waveform = MultiResWaveform.new()


## Apply /audiofile/decode/ready args: [req_id, cache_key, channels, frames, sample_rate, duration_s, sample_count?].
## Missing frames or duration are derived from the others. Returns false on a short message.
func apply_decode_ready(args: Array) -> bool:
	if args.size() < 6:
		logger.error("decode_ready: need 6 args, got %d" % args.size())
		return false
	var cache_key := str(args[1])
	var channels := int(args[2])
	var frames := int(args[3])
	var sample_rate := int(args[4])
	var duration_s := float(args[5])
	var sample_count := int(args[6]) if args.size() > 6 else 0

	if frames <= 0:
		if sample_count > 0 and channels > 0:
			@warning_ignore("integer_division")
			frames = sample_count / channels
		elif duration_s > 0.0 and sample_rate > 0:
			frames = int(duration_s * float(sample_rate))
	if duration_s <= 0.0 and frames > 0 and sample_rate > 0:
		duration_s = float(frames) / float(sample_rate)

	waveform_cache_key = cache_key
	var cache_path := Sonara.find_waveform_cache_file(cache_key)
	if cache_path.is_empty():
		logger.warn("Waveform cache not found: %s" % cache_key)
	else:
		set_waveform_cache(cache_path, cache_key)
	set_audio_metadata(sample_rate, channels, frames, duration_s)
	return true


## Apply /audiofile/waveform/level args: [req_id, level, block_size, num_blocks?, file_path?, ...].
## Returns true when the level was read from the cache file.
func apply_waveform_level(args: Array) -> bool:
	if args.size() < 3:
		logger.error("waveform level: need 3 args, got %d" % args.size())
		return false
	var file_path := str(args[4]) if args.size() >= 5 else ""
	if file_path.is_empty():
		file_path = waveform_cache_path
	if not file_path.is_empty():
		if waveform_cache_key.is_empty():
			waveform_cache_key = file_path.get_file()
		set_waveform_cache(file_path, waveform_cache_key)
	var num_blocks := int(args[3]) if args.size() >= 4 else 0
	return ingest_waveform_level_from_cache(int(args[1]), int(args[2]), num_blocks)


## Retry a level that failed to ingest: relocate the cache file by key and read num_blocks
## from the file when the engine did not send it.
func retry_waveform_level(level: int, block_size: int, num_blocks: int) -> bool:
	if waveform_cache_path.is_empty() and not waveform_cache_key.is_empty():
		var cache_path := Sonara.find_waveform_cache_file(waveform_cache_key)
		if not cache_path.is_empty():
			set_waveform_cache(cache_path, waveform_cache_key)
	if num_blocks <= 0 and not waveform_cache_path.is_empty():
		var reader := WaveformCacheReader.new()
		if reader.load(waveform_cache_path):
			var level_info = reader.read_level(level, audio_channels)
			if not level_info.is_empty():
				num_blocks = int(level_info.get("num_blocks", 0))
	return ingest_waveform_level_from_cache(level, block_size, num_blocks)


## Read one waveform pyramid level from the engine cache file.
func ingest_waveform_level_from_cache(level: int, block_size: int, num_blocks: int) -> bool:
	ensure_audio_waveform()
	if waveform_cache_path.is_empty() or not FileAccess.file_exists(waveform_cache_path):
		logger.debug("Waveform cache file not found: %s" % waveform_cache_path)
		return false
	if _waveform_cache_reader == null:
		_waveform_cache_reader = WaveformCacheReader.new()
		if not _waveform_cache_reader.load(waveform_cache_path):
			logger.warn("Failed to open waveform cache: %s" % waveform_cache_path)
			_waveform_cache_reader = null
			return false
	var level_data = _waveform_cache_reader.read_level(level, audio_channels)
	if level_data.is_empty():
		logger.warn("Failed to read level %d from %s" % [level, waveform_cache_path])
		return false
	var waveform := Waveform.new()
	var channel_peaks = level_data.get("peaks", [])
	var channel_rms = level_data.get("rms", [])
	waveform.load_from_cache(block_size, audio_channels, num_blocks, channel_peaks, channel_rms)
	while audio_waveform.levels.size() <= level:
		audio_waveform.levels.append(null)
	audio_waveform.levels[level] = waveform
	waveform_level_updated.emit(level)
	return true


## First fully loaded pyramid level, or null.
func get_ready_level() -> Waveform:
	if audio_waveform == null:
		return null
	for i in range(audio_waveform.levels.size()):
		if audio_waveform.is_level_ready(i):
			return audio_waveform.levels[i]
	return null
