## Waveform pyramid owned by a file-loading DeviceInstance (Sampler).
class_name DeviceWaveform extends RefCounted

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


## Read one waveform pyramid level from the engine cache file.
func ingest_waveform_level_from_cache(level: int, block_size: int, num_blocks: int) -> bool:
	ensure_audio_waveform()
	if waveform_cache_path.is_empty() or not FileAccess.file_exists(waveform_cache_path):
		return false
	if _waveform_cache_reader == null:
		_waveform_cache_reader = WaveformCacheReader.new()
		if not _waveform_cache_reader.load(waveform_cache_path):
			_waveform_cache_reader = null
			return false
	var level_data = _waveform_cache_reader.read_level(level, audio_channels)
	if level_data.is_empty():
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
