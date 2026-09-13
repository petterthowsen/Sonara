# MediaEncode.gd
# Encode images/audio for OpenRouter chat parts and decode streamed media.
class_name MediaEncode extends RefCounted


const TMP_SUBDIR := "aichat/tmp"


## Image file → `data:<mime>;base64,...` URI. Empty string on read failure.
static func image_file_to_data_uri(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		push_warning("[MediaEncode] Image file not found")
		return ""
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_warning("[MediaEncode] Image file empty")
		return ""
	var mime := _image_mime(path)
	return "data:%s;base64,%s" % [mime, Marshalls.raw_to_base64(bytes)]


## Texture2D → PNG data URI. Empty string if the image cannot be read.
static func texture_to_data_uri(tex: Texture2D) -> String:
	if tex == null:
		return ""
	var img := tex.get_image()
	if img == null:
		push_warning("[MediaEncode] Texture has no image")
		return ""
	var bytes := img.save_png_to_buffer()
	if bytes.is_empty():
		return ""
	return "data:image/png;base64,%s" % Marshalls.raw_to_base64(bytes)


## Raw audio bytes → base64 (no data-URI prefix).
static func audio_bytes_to_b64(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	return Marshalls.raw_to_base64(bytes)


## Audio file → `{data, format}` for an input_audio part. Empty data on failure.
static func audio_file_to_payload(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		push_warning("[MediaEncode] Audio file not found")
		return {"data": "", "format": "wav"}
	var bytes := FileAccess.get_file_as_bytes(path)
	var ext := path.get_extension().to_lower()
	var fmt := "mp3" if ext == "mp3" else "wav"
	return {"data": audio_bytes_to_b64(bytes), "format": fmt}


## Decode a base64 string to bytes.
static func decode_b64(b64: String) -> PackedByteArray:
	if b64.is_empty():
		return PackedByteArray()
	return Marshalls.base64_to_raw(b64)


## Write assembled audio bytes to `~/.config/sonara/aichat/tmp/` and return the path.
static func write_temp_audio(bytes: PackedByteArray, format: String = "wav") -> String:
	if bytes.is_empty():
		return ""
	var dir := _tmp_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var ext := "mp3" if format == "mp3" else "wav"
	var path := "%s/out_%d.%s" % [dir, Time.get_ticks_msec(), ext]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[MediaEncode] Could not write temp audio")
		return ""
	file.store_buffer(bytes)
	file.close()
	return path


## Data URI or raw base64 image → ImageTexture for the transcript.
static func image_from_data_uri(uri: String) -> ImageTexture:
	var b64 := uri
	if uri.begins_with("data:"):
		var comma := uri.find(",")
		if comma < 0:
			return null
		b64 = uri.substr(comma + 1)
	var bytes := decode_b64(b64)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		if img.load_jpg_from_buffer(bytes) != OK:
			push_warning("[MediaEncode] Could not decode image bytes")
			return null
	return ImageTexture.create_from_image(img)


## MIME type from an image path extension.
static func _image_mime(path: String) -> String:
	match path.get_extension().to_lower():
		"jpg", "jpeg":
			return "image/jpeg"
		"webp":
			return "image/webp"
		"gif":
			return "image/gif"
		_:
			return "image/png"


## Config-dir temp folder for assembled chat media.
static func _tmp_dir() -> String:
	if Sonara:
		return Sonara.get_config_dir().path_join(TMP_SUBDIR)
	return OS.get_environment("HOME").path_join(".config/sonara").path_join(TMP_SUBDIR)
