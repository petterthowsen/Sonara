## WaveformData.gd
## One engine peak file (format v2, `<key>.swp`) as GPU textures. The format is described in
## docs/subsystems/osc-protocol.md › "Waveform Cache Format". Each channel has two RGBA16F
## planes holding every level stacked by rows: plane A (min, max, rms) and plane B (low, mid,
## high band RMS). WaveformView samples them in a shader.
##
## Get instances from WaveformRegistry so clips sharing a file share the textures.
class_name WaveformData extends RefCounted

static var logger := Log.make("WaveformData")

## Emitted once loading finishes, successfully or not. Check is_ready().
signal loaded(ok: bool)

const MAGIC := "SONAPK02"
const VERSION := 2
const HEADER_SIZE := 64
const LEVEL_ENTRY_SIZE := 16
const TEXEL_BYTES := 8

var path: String = ""
var channels: int = 0
var source_sample_rate: int = 0
var frames: int = 0
var base_block: int = 64
var levels: int = 0
var tex_width: int = 0
var total_rows: int = 0
## First texture row of each level.
var level_rows: PackedInt32Array = PackedInt32Array()
## Block count of each level.
var level_blocks: PackedInt64Array = PackedInt64Array()
## One texture per channel.
var plane_a: Array[Texture2D] = []
var plane_b: Array[Texture2D] = []
var error: String = ""

var _ready := false
var _loading := false
var _task_id := -1


func is_ready() -> bool:
	return _ready


func is_loading() -> bool:
	return _loading


## Load synchronously. Returns false (and sets `error`) on a missing, invalid or incomplete file.
func load_file(p: String) -> bool:
	path = p
	var parsed := read_file(p)
	_apply(parsed)
	return _ready


## Load on the WorkerThreadPool; textures are created on the main thread. Emits `loaded`.
func load_async(p: String) -> void:
	if _loading:
		return
	path = p
	_loading = true
	_task_id = WorkerThreadPool.add_task(_load_task.bind(p), false, "WaveformData load")


func _load_task(p: String) -> void:
	var parsed := read_file(p)
	_finish_async.call_deferred(parsed)


func _finish_async(parsed: Dictionary) -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	_loading = false
	_apply(parsed)


func _apply(parsed: Dictionary) -> void:
	error = str(parsed.get("error", ""))
	if not error.is_empty():
		logger.warn("Failed to load peak file %s: %s" % [path, error])
		_ready = false
		loaded.emit(false)
		return
	channels = parsed.channels
	source_sample_rate = parsed.source_sample_rate
	frames = parsed.frames
	base_block = parsed.base_block
	levels = parsed.levels
	tex_width = parsed.tex_width
	total_rows = parsed.total_rows
	level_rows = parsed.level_rows
	level_blocks = parsed.level_blocks
	plane_a.clear()
	plane_b.clear()
	for img: Image in parsed.images_a:
		plane_a.append(ImageTexture.create_from_image(img))
	for img: Image in parsed.images_b:
		plane_b.append(ImageTexture.create_from_image(img))
	_ready = true
	loaded.emit(true)


## Read and validate a peak file into header fields plus one Image per plane. Thread-safe.
## Returns a Dictionary with an "error" key on failure.
static func read_file(p: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(p)
	if bytes.is_empty():
		return {"error": "cannot read file (%s)" % error_string(FileAccess.get_open_error())}
	return parse_bytes(bytes)


static func parse_bytes(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < HEADER_SIZE:
		return {"error": "file too short"}
	if bytes.slice(0, 8).get_string_from_ascii() != MAGIC:
		return {"error": "bad magic"}
	if bytes.decode_u16(8) != VERSION:
		return {"error": "unsupported version %d" % bytes.decode_u16(8)}
	if bytes[48] != 1:
		return {"error": "incomplete file"}
	var out := {
		"channels": bytes.decode_u16(10),
		"source_sample_rate": bytes.decode_u32(12),
		"frames": bytes.decode_u64(16),
		"base_block": bytes.decode_u32(24),
		"levels": bytes.decode_u16(28),
		"tex_width": bytes.decode_u16(30),
	}
	var num_levels: int = out.levels
	var width: int = out.tex_width
	var table_end := HEADER_SIZE + num_levels * LEVEL_ENTRY_SIZE
	if bytes.size() < table_end or width <= 0 or num_levels <= 0:
		return {"error": "bad level table"}
	var level_rows := PackedInt32Array()
	var level_blocks := PackedInt64Array()
	var rows_total := 0
	for i in num_levels:
		var o := HEADER_SIZE + i * LEVEL_ENTRY_SIZE
		level_blocks.append(bytes.decode_u64(o))
		level_rows.append(bytes.decode_u32(o + 8))
		rows_total += bytes.decode_u32(o + 12)
	var plane_bytes := rows_total * width * TEXEL_BYTES
	var channels: int = out.channels
	if bytes.size() < table_end + plane_bytes * 2 * channels:
		return {"error": "truncated planes"}
	var images_a: Array[Image] = []
	var images_b: Array[Image] = []
	for ch in channels:
		var a_start := table_end + (ch * 2) * plane_bytes
		var b_start := a_start + plane_bytes
		images_a.append(Image.create_from_data(width, rows_total, false, Image.FORMAT_RGBAH,
				bytes.slice(a_start, a_start + plane_bytes)))
		images_b.append(Image.create_from_data(width, rows_total, false, Image.FORMAT_RGBAH,
				bytes.slice(b_start, b_start + plane_bytes)))
	out.total_rows = rows_total
	out.level_rows = level_rows
	out.level_blocks = level_blocks
	out.images_a = images_a
	out.images_b = images_b
	return out
