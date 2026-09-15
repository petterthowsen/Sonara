# FileSystemAssetProvider.gd
# Scans `assets/samples/paths` for audio and MIDI files.

class_name FileSystemAssetProvider extends FileScanAssetProvider

const AUDIO_EXTENSIONS: Array[String] = ["wav", "mp3", "ogg"]
const MIDI_EXTENSIONS: Array[String] = ["mid", "midi"]


func _init() -> void:
	super()
	provider_name = "FileSystemAssetProvider"


func _scan_paths_setting() -> String:
	return "assets/samples/paths"


func _cache_file_name() -> String:
	return "samples_cache.json"


func _asset_type_for_extension(extension: String) -> int:
	if extension in AUDIO_EXTENSIONS:
		return Asset.TYPE.Audio
	if extension in MIDI_EXTENSIONS:
		return Asset.TYPE.Midi
	return -1
