extends TestBase
## NoteStrip.decode for the short (Arpeggiator) and long (Step Sequencer, spec 039) note_state
## blobs.


func suite_name() -> String:
	return "NoteState decode"


func run_tests() -> void:
	_test_short_blob()
	_test_long_blob()
	_test_unknown_timing()
	_test_malformed()


func _prefix(step: int, key: int, branch: int, held: Array) -> PackedByteArray:
	var blob := PackedByteArray([step, key, branch, held.size()])
	for k in held:
		blob.append(k)
	return blob


func _append_u16s(blob: PackedByteArray, values: Array) -> PackedByteArray:
	for v in values:
		blob.append(v & 0xFF)
		blob.append((v >> 8) & 0xFF)
	return blob


func _test_short_blob() -> void:
	var d := NoteStrip.decode(_prefix(2, 60, 0xFF, [60, 64]))
	_assert(d["step"] == 2 and d["key"] == 60, "short: step and key")
	_assert(d["branch"] == -1, "short: 0xFF branch is -1")
	_assert(d["held"] == PackedInt32Array([60, 64]), "short: held keys")
	_assert(d["reached"] == 0 and d["fired"] == 0, "short: masks are 0")
	_assert(d["elapsed_ms"] == -1 and d["next_in_ms"] == -1, "short: elapsed/next_in are -1")
	_assert(d["gap_a_ms"] == -1 and d["gap_b_ms"] == -1, "short: gaps are -1")
	var empty := NoteStrip.decode(_prefix(0xFF, 0xFF, 0xFF, []))
	_assert(empty["step"] == -1 and empty["held"].is_empty(), "short: no held keys")


func _test_long_blob() -> void:
	var blob := _append_u16s(_prefix(5, 60, 0xFF, [60, 64]), [0x001C, 0x0014, 30, 95, 125, 250])
	var d := NoteStrip.decode(blob)
	_assert(d["step"] == 5 and d["held"] == PackedInt32Array([60, 64]), "long: prefix unchanged")
	_assert(d["reached"] == 0x1C, "long: reached mask")
	_assert(d["fired"] == 0x14, "long: fired mask")
	_assert(d["elapsed_ms"] == 30, "long: elapsed_ms")
	_assert(d["next_in_ms"] == 95, "long: next_in_ms")
	_assert(d["gap_a_ms"] == 125 and d["gap_b_ms"] == 250, "long: gaps")
	var high := NoteStrip.decode(_append_u16s(_prefix(0, 60, 0xFF, []), [0x8001, 0, 0x0102, 0, 0, 0]))
	_assert(high["reached"] == 0x8001, "long: high mask bit, little-endian")
	_assert(high["elapsed_ms"] == 0x0102, "long: u16 is little-endian")


func _test_unknown_timing() -> void:
	var blob := _append_u16s(_prefix(1, 0xFF, 0xFF, []), [0, 0, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF])
	var d := NoteStrip.decode(blob)
	_assert(d["elapsed_ms"] == -1 and d["next_in_ms"] == -1, "0xFFFF decodes to -1")
	_assert(d["gap_a_ms"] == -1 and d["gap_b_ms"] == -1, "0xFFFF gaps decode to -1")
	var saturated := NoteStrip.decode(_append_u16s(_prefix(1, 0xFF, 0xFF, []), [0, 0, 0xFFFE, 0, 0, 0]))
	_assert(saturated["elapsed_ms"] == 0xFFFE, "0xFFFE is a real value")
	# A half-present tail is treated as short.
	var partial := _prefix(1, 0xFF, 0xFF, [])
	partial.append_array(PackedByteArray([1, 0, 2, 0]))
	_assert(NoteStrip.decode(partial)["fired"] == 0, "partial tail ignored")


func _test_malformed() -> void:
	_assert(NoteStrip.decode(PackedByteArray([1, 2])).is_empty(), "too short is {}")
	_assert(NoteStrip.decode(PackedByteArray([1, 2, 3, 5, 60])).is_empty(), "truncated held is {}")
