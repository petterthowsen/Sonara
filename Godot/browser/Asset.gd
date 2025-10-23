class_name Asset extends RefCounted

enum TYPE { Audio, Midi, Device }

# ============================================================================
# CORE PROPERTIES
# ============================================================================

var type : TYPE = TYPE.Audio
var name : String = ""
var path : String = ""  # Absolute file path


# ============================================================================
# METADATA
# ============================================================================

var favorite: bool = false
var tags: Array[String] = []
var last_used: int = 0  # Unix timestamp
var file_size_bytes: int = 0
var file_modified_time: int = 0  # For hot-reload detection


# ============================================================================
# HELPER METHODS
# ============================================================================

## Get display name (filename without extension, or device title if device asset)
func get_display_name() -> String:
	if path.is_empty():
		return name

	# For device assets, try to get the device and use its title
	if type == TYPE.Device:
		var device = AssetService.get_device(path)
		if device and not device.title.is_empty():
			return device.title

	return path.get_file().trim_suffix("." + get_file_extension())


## Get file extension (e.g. "wav", "mp3", "mid")
func get_file_extension() -> String:
	if path.is_empty():
		return ""
	return path.get_extension().to_lower()


## Check if this is an audio asset
func is_audio() -> bool:
	return type == TYPE.Audio


## Check if this is a MIDI asset
func is_midi() -> bool:
	return type == TYPE.Midi


## Get icon name for this asset type
func get_icon() -> String:
	match type:
		TYPE.Audio:
			return "AudioStreamOggVorbis"
		TYPE.Midi:
			return "DockRemove"  # Generic icon for now
		TYPE.Device:
			return "AudioBusInput"
		_:
			return "File"


## Mark this asset as used (update last_used timestamp)
func mark_as_used() -> void:
	last_used = Time.get_unix_time_from_system()


## Check if this asset has changed on disk (based on modification time)
func has_changed(current_modified_time: int) -> bool:
	return file_modified_time != current_modified_time
