## AudioSourceInfo.gd
## Decoded audio metadata and peak data for one loaded file (an audio Clip or a Sampler
## DeviceInstance). Fed by the engine's AudioFileService: /audiofile/decode/ready gives the
## playback metadata, then /audiofile/waveform/ready gives the peak file, which is loaded
## through WaveformRegistry.
class_name AudioSourceInfo extends RefCounted

static var logger := Log.make("AudioSourceInfo")

signal metadata_changed()
## The peak data is loaded (`data.is_ready()`).
signal waveform_ready()

## Engine cache key for the file. Runtime only, not saved: the engine recomputes it.
var cache_key: String = ""
var audio_channels: int = 2
## Frames at the playback (project) rate.
var audio_frames: int = 0
## Playback (project) rate. The file's own rate is `data.source_sample_rate`.
var audio_sample_rate: int = 44100
var audio_duration_seconds: float = 0.0
var peak_path: String = ""
var data: WaveformData = null


## Clear state so a new file can load into this object.
func reset() -> void:
	cache_key = ""
	audio_frames = 0
	audio_duration_seconds = 0.0
	_set_data(null)
	peak_path = ""
	metadata_changed.emit()


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


## True once peak textures are available.
func is_waveform_ready() -> bool:
	return data != null and data.is_ready()


## Apply /audiofile/decode/ready args: [req_id, cache_key, channels, frames, sample_rate, duration_s, sample_count?].
## Missing frames or duration are derived from the others. Returns false on a short message.
func apply_decode_ready(args: Array) -> bool:
	if args.size() < 6:
		logger.error("decode_ready: need 6 args, got %d" % args.size())
		return false
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

	cache_key = str(args[1])
	set_audio_metadata(sample_rate, channels, frames, duration_s)
	return true


## Apply /audiofile/waveform/ready args: [req_id, peak_file_path]. Loads (or shares) the peak
## data and emits `waveform_ready` once it is available.
func apply_waveform_ready(args: Array) -> bool:
	if args.size() < 2:
		logger.error("waveform ready: need 2 args, got %d" % args.size())
		return false
	var path := str(args[1])
	if path.is_empty():
		return false
	peak_path = path
	_set_data(WaveformRegistry.get_or_load(path))
	return data != null


## Share another source's peak data (Make Unique).
func share_from(other: AudioSourceInfo) -> void:
	cache_key = other.cache_key
	audio_channels = other.audio_channels
	audio_frames = other.audio_frames
	audio_sample_rate = other.audio_sample_rate
	audio_duration_seconds = other.audio_duration_seconds
	peak_path = other.peak_path
	_set_data(other.data)
	metadata_changed.emit()


func _set_data(d: WaveformData) -> void:
	logger.info("_set_data: new=%s same=%s ready=%s" % [d != null, data == d, d != null and d.is_ready()])
	if data == d:
		if d != null and d.is_ready():
			waveform_ready.emit()
		return
	if data and data.loaded.is_connected(_on_data_loaded):
		data.loaded.disconnect(_on_data_loaded)
	data = d
	if data == null:
		return
	if data.is_ready():
		waveform_ready.emit()
	else:
		data.loaded.connect(_on_data_loaded, CONNECT_ONE_SHOT)


func _on_data_loaded(ok: bool) -> void:
	if ok:
		waveform_ready.emit()
