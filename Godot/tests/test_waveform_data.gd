# Tests WaveformData parsing of engine peak files (v2), and WaveformRegistry sharing.
# Run: godot --headless --path Godot -s tests/test_waveform_data.gd -- --test
extends TestBase

const TEX_WIDTH := 4


func suite_name() -> String:
	return "WaveformData"


func run_tests() -> void:
	var dir := OS.get_cache_dir().path_join("sonara_test_waveform_data")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("test.swp")
	_write_peak_file(path, true)

	_test_load(path)
	_test_texel(path)
	_test_incomplete(dir.path_join("incomplete.swp"))
	await _test_registry(path)

	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(dir.path_join("incomplete.swp"))
	DirAccess.remove_absolute(dir)


## 1 channel, 2 levels: level 0 has 5 blocks (2 rows of 4), level 1 has 3 blocks (1 row).
func _write_peak_file(path: String, complete: bool) -> void:
	var levels := [5, 3]
	var rows := [2, 1]
	var total_rows := 3
	var header := PackedByteArray()
	header.resize(64)
	var magic := "SONAPK02".to_ascii_buffer()
	for i in magic.size():
		header[i] = magic[i]
	header.encode_u16(8, 2)
	header.encode_u16(10, 1)
	header.encode_u32(12, 48000)
	header.encode_u64(16, 300)
	header.encode_u32(24, 64)
	header.encode_u16(28, levels.size())
	header.encode_u16(30, TEX_WIDTH)
	header.encode_u64(32, 1234)
	header.encode_u64(40, 5678)
	header[48] = 1 if complete else 0

	var table := PackedByteArray()
	table.resize(16 * levels.size())
	var row := 0
	for i in levels.size():
		table.encode_u64(i * 16, levels[i])
		table.encode_u32(i * 16 + 8, row)
		table.encode_u32(i * 16 + 12, rows[i])
		row += rows[i]

	var plane_bytes := total_rows * TEX_WIDTH * 8
	var plane_a := PackedByteArray()
	plane_a.resize(plane_bytes)
	var plane_b := PackedByteArray()
	plane_b.resize(plane_bytes)
	# Level 0, block 4 → texel (0, 1).
	_set_texel(plane_a, TEX_WIDTH * 1 + 0, -0.5, 0.75, 0.25)
	_set_texel(plane_b, TEX_WIDTH * 1 + 0, 0.125, 0.5, 0.0625)
	# Level 1, block 2 → texel (2, 2).
	_set_texel(plane_a, TEX_WIDTH * 2 + 2, -1.0, 1.0, 0.5)

	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	f.store_buffer(table)
	f.store_buffer(plane_a)
	f.store_buffer(plane_b)
	f.close()


func _set_texel(buf: PackedByteArray, texel: int, a: float, b: float, c: float) -> void:
	buf.encode_half(texel * 8, a)
	buf.encode_half(texel * 8 + 2, b)
	buf.encode_half(texel * 8 + 4, c)


func _test_load(path: String) -> void:
	var data := WaveformData.new()
	_assert(data.load_file(path), "loads a valid file")
	_assert(data.is_ready(), "ready after load")
	_assert(data.channels == 1, "channels")
	_assert(data.source_sample_rate == 48000, "source sample rate")
	_assert(data.frames == 300, "frames")
	_assert(data.base_block == 64, "base block")
	_assert(data.levels == 2, "level count")
	_assert(data.level_rows == PackedInt32Array([0, 2]), "level rows")
	_assert(data.level_blocks == PackedInt64Array([5, 3]), "level blocks")
	_assert(data.plane_a.size() == 1 and data.plane_b.size() == 1, "one texture per plane")
	_assert(data.plane_a[0].get_width() == TEX_WIDTH, "texture width")
	_assert(data.plane_a[0].get_height() == 3, "texture height = total rows")


func _test_texel(path: String) -> void:
	var parsed := WaveformData.read_file(path)
	_assert(not parsed.has("error"), "read_file ok")
	var img: Image = parsed.images_a[0]
	_assert(img.get_format() == Image.FORMAT_RGBAH, "RGBAH format")
	var px := img.get_pixel(0, 1)
	_assert(is_equal_approx(px.r, -0.5) and is_equal_approx(px.g, 0.75) and is_equal_approx(px.b, 0.25),
		"plane A texel of level 0 block 4: %s" % px)
	px = img.get_pixel(2, 2)
	_assert(is_equal_approx(px.r, -1.0) and is_equal_approx(px.g, 1.0), "plane A texel of level 1 block 2")
	var band: Color = (parsed.images_b[0] as Image).get_pixel(0, 1)
	_assert(is_equal_approx(band.r, 0.125) and is_equal_approx(band.g, 0.5) and is_equal_approx(band.b, 0.0625),
		"plane B texel: %s" % band)


func _test_incomplete(path: String) -> void:
	_write_peak_file(path, false)
	var data := WaveformData.new()
	_assert(not data.load_file(path), "incomplete file is rejected")
	_assert(not data.error.is_empty(), "error message set")
	_assert(not WaveformData.new().load_file(path + ".missing"), "missing file is rejected")


func _test_registry(path: String) -> void:
	var a := WaveformRegistry.get_or_load(path)
	var b := WaveformRegistry.get_or_load(path)
	_assert(a == b, "registry shares one WaveformData per path")
	if not a.is_ready():
		await a.loaded
	_assert(a.is_ready(), "async load finishes")
	_assert(a.plane_a[0].get_height() == 3, "async textures created")

	var source := AudioSourceInfo.new()
	var got := [false]
	source.waveform_ready.connect(func(): got[0] = true)
	source.apply_waveform_ready(["req", path])
	_assert(source.data == a, "AudioSourceInfo uses the shared data")
	_assert(got[0], "waveform_ready emitted at once for already-loaded data")
