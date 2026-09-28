## WaveformSampleWindow.gd
## Raw native-rate samples for one WaveformView at deep zoom (frames per pixel below the base
## block). The view says which source frames are visible; this fetches them from the engine in
## 4096-frame chunks (/audiofile/samples → /audiofile/samples/data), keeps recent chunks, and
## uploads the window as one R32F texture that waveform.gdshader draws as a line.
##
## A reply is one channel of one chunk (≤ 16 KB). Godot's UDP peer buffers about 64 KB per
## frame, so at most MAX_IN_FLIGHT requests are outstanding; lost replies are re-requested.
class_name WaveformSampleWindow extends RefCounted

static var logger := Log.make("WaveformSampleWindow")

## The texture now covers a new window (or was cleared).
signal changed()

const CHUNK := 4096
## Widest window, in chunks per channel. Wider views keep drawing the base level.
const MAX_CHUNKS := 8
const MAX_IN_FLIGHT := 2
const REQUEST_TIMEOUT_MS := 500
## Chunks (per channel) kept after they leave the window, for scrolling back.
const MAX_CACHED := 64

var data: WaveformData = null
## First frame of the window (chunk-aligned) and its length in frames.
var window_start: int = 0
var window_len: int = 0
## Channels stored per chunk row group (1 or 2).
var channels: int = 0
var texture: ImageTexture = null

var _first_chunk := -1
var _num_chunks := 0
## Vector2i(chunk, channel) -> PackedFloat32Array
var _chunks: Dictionary = {}
var _queue: Array[Vector2i] = []
## req_id -> {"key": Vector2i, "sent": msec}
var _in_flight: Dictionary = {}
var _seq := 0
var _retry_scheduled := false

static var _by_req: Dictionary = {}  # req_id -> WeakRef(WaveformSampleWindow)
static var _listening := false


## True when the texture covers the current window.
func is_ready() -> bool:
	return texture != null and window_len > 0


## Show source frames [first, last). Returns false (and clears the window) when the range is
## wider than MAX_CHUNKS or there is no data; the view then draws peaks only.
func set_range(first: int, last: int) -> bool:
	if data == null or not data.is_ready() or data.path.is_empty():
		clear()
		return false
	first = clampi(first, 0, data.frames)
	last = clampi(last, first, data.frames)
	@warning_ignore("integer_division")
	var c0 := first / CHUNK
	@warning_ignore("integer_division")
	var c1 := maxi(c0, (last - 1) / CHUNK)
	var n := c1 - c0 + 1
	if last <= first or n > MAX_CHUNKS:
		clear()
		return false
	if c0 == _first_chunk and n == _num_chunks:
		return true
	_first_chunk = c0
	_num_chunks = n
	channels = mini(data.channels, 2)
	_queue.clear()
	for c in range(c0, c1 + 1):
		for ch in channels:
			var key := Vector2i(c, ch)
			if not _chunks.has(key) and not _is_in_flight(key):
				_queue.append(key)
	if _queue.is_empty() and not _has_pending_for_window():
		_build_texture()
	else:
		_pump()
	return true


## Drop the window (the chunk cache stays).
func clear() -> void:
	_first_chunk = -1
	_num_chunks = 0
	_queue.clear()
	if texture != null or window_len != 0:
		texture = null
		window_len = 0
		changed.emit()


## Forget everything, e.g. when the view gets new data.
func reset() -> void:
	clear()
	_chunks.clear()
	for req_id in _in_flight:
		_by_req.erase(req_id)
	_in_flight.clear()


func _is_in_flight(key: Vector2i) -> bool:
	for entry in _in_flight.values():
		if entry.key == key:
			return true
	return false


func _has_pending_for_window() -> bool:
	for entry in _in_flight.values():
		if _in_window(entry.key):
			return true
	return false


func _in_window(key: Vector2i) -> bool:
	return key.x >= _first_chunk and key.x < _first_chunk + _num_chunks


func _pump() -> void:
	var now := Time.get_ticks_msec()
	for req_id in _in_flight.keys():
		var entry: Dictionary = _in_flight[req_id]
		if now - int(entry.sent) > REQUEST_TIMEOUT_MS:
			_in_flight.erase(req_id)
			_by_req.erase(req_id)
			if _in_window(entry.key) and not _queue.has(entry.key):
				_queue.push_front(entry.key)
	while _in_flight.size() < MAX_IN_FLIGHT and not _queue.is_empty():
		_send(_queue.pop_front())
	if not _in_flight.is_empty() and not _retry_scheduled:
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			_retry_scheduled = true
			var self_ref: WeakRef = weakref(self)
			tree.create_timer(REQUEST_TIMEOUT_MS / 1000.0 + 0.05).timeout.connect(func() -> void:
				var w: WaveformSampleWindow = self_ref.get_ref()
				if w:
					w._retry_scheduled = false
					w._pump())


func _send(key: Vector2i) -> void:
	_ensure_listening()
	_seq += 1
	var req_id := "wfs:%d:%d" % [get_instance_id(), _seq]
	_in_flight[req_id] = {"key": key, "sent": Time.get_ticks_msec()}
	_by_req[req_id] = weakref(self)
	AudioEngineOSC.send("/audiofile/samples",
			[req_id, data.path.get_file().get_basename(), key.y, key.x * CHUNK, CHUNK])


## Store a reply: `start_frame`/`channel` identify the chunk, `samples` may be short (EOF).
func receive(req_id: String, channel: int, start_frame: int, samples: PackedFloat32Array) -> void:
	var entry: Dictionary = _in_flight.get(req_id, {})
	_in_flight.erase(req_id)
	_by_req.erase(req_id)
	if entry.is_empty():
		return
	@warning_ignore("integer_division")
	var key := Vector2i(start_frame / CHUNK, channel)
	if key != entry.key:
		logger.warn("sample reply %s for %s, expected %s" % [req_id, key, entry.key])
		return
	_chunks[key] = samples
	_trim_cache()
	if _first_chunk >= 0 and _queue.is_empty() and not _has_pending_for_window():
		_build_texture()
	_pump()


## A request failed on the engine side (for example an unknown cache key). Stop asking.
func fail(req_id: String, message: String) -> void:
	if not _in_flight.has(req_id):
		return
	_in_flight.erase(req_id)
	_by_req.erase(req_id)
	_queue.clear()
	logger.warn("sample request failed: %s" % message)


func _trim_cache() -> void:
	if _chunks.size() <= MAX_CACHED * 2:
		return
	for key: Vector2i in _chunks.keys():
		if not _in_window(key):
			_chunks.erase(key)
		if _chunks.size() <= MAX_CACHED:
			break


func _build_texture() -> void:
	var rows := _num_chunks * channels
	var bytes := PackedByteArray()
	for i in _num_chunks:
		for ch in channels:
			var chunk: PackedFloat32Array = _chunks.get(Vector2i(_first_chunk + i, ch), PackedFloat32Array())
			var raw := chunk.to_byte_array()
			raw.resize(CHUNK * 4)  # zero-pads a short last chunk
			bytes.append_array(raw)
	var image := Image.create_from_data(CHUNK, rows, false, Image.FORMAT_RF, bytes)
	if texture != null and texture.get_width() == CHUNK and texture.get_height() == rows:
		texture.update(image)
	else:
		texture = ImageTexture.create_from_image(image)
	window_start = _first_chunk * CHUNK
	window_len = mini(_num_chunks * CHUNK, data.frames - window_start)
	changed.emit()


static func _ensure_listening() -> void:
	if _listening:
		return
	_listening = true
	AudioEngineOSC.listen("/audiofile/samples/data", _on_samples_data)
	AudioEngineOSC.listen("/audiofile/error", _on_error)


## /audiofile/samples/data s:req_id i:channel h:start_frame b:f32 LE samples
static func _on_samples_data(args: Array) -> void:
	if args.size() < 4:
		return
	var req_id := str(args[0])
	var window := _window_for(req_id)
	if window:
		window.receive(req_id, int(args[1]), int(args[2]), decode_blob(args[3]))


static func _on_error(args: Array) -> void:
	if args.is_empty():
		return
	var req_id := str(args[0])
	var window := _window_for(req_id)
	if window:
		window.fail(req_id, str(args[2]) if args.size() > 2 else "")


static func _window_for(req_id: String) -> WaveformSampleWindow:
	if not req_id.begins_with("wfs:"):
		return null
	var ref: WeakRef = _by_req.get(req_id)
	var window: WaveformSampleWindow = ref.get_ref() if ref else null
	if window == null:
		_by_req.erase(req_id)
	return window


## OSC blob argument (4-byte big-endian length, payload) → little-endian f32 samples.
static func decode_blob(blob: PackedByteArray) -> PackedFloat32Array:
	if blob.size() < 4:
		return PackedFloat32Array()
	var length := (blob[0] << 24) | (blob[1] << 16) | (blob[2] << 8) | blob[3]
	length = mini(length, blob.size() - 4)
	return blob.slice(4, 4 + length - length % 4).to_float32_array()
