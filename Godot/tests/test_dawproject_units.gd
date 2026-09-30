# test_dawproject_units.gd
# Headless tests for the DAWproject building blocks: XML DOM/writer, unit conversions and
# curve resampling, `.clap-preset` wrapping, SFZ file collection and the transfer report.
# Run: godot --headless --path Godot -s tests/test_dawproject_units.gd -- --test
extends TestBase

const FIXTURE := "res://tests/fixtures/dawproject/sonara_test_01.dawproject"


func suite_name() -> String:
	return "DAWproject units tests"


func run_tests() -> void:
	_test_xml_fixture()
	_test_xml_errors()
	_test_xml_writer_round_trip()
	_test_conversions()
	_test_resample()
	_test_clap_preset()
	_test_report()
	_test_sfz()


func _zip_entry(entry: String) -> PackedByteArray:
	var zip := ZIPReader.new()
	if zip.open(ProjectSettings.globalize_path(FIXTURE)) != OK:
		return PackedByteArray()
	var bytes := zip.read_file(entry)
	zip.close()
	return bytes


func _test_xml_fixture() -> void:
	var result: Dictionary = DawXml.parse(_zip_entry("project.xml"))
	_assert(result.root != null, "fixture project.xml parses")
	var root: DawXml.El = result.root
	_assert(root.tag == "Project", "root is Project")
	var structure := root.child("Structure")
	_assert(structure.children_named("Track").size() == 4, "4 Tracks under Structure")
	_assert(structure.children[0].get_attr("name") == "Apricot", "first track is Apricot")
	_assert(root.find("Tempo").get_float("value") == 110.0, "tempo attribute read as float")
	var meta: Dictionary = DawXml.parse(_zip_entry("metadata.xml"))
	_assert(meta.root.tag == "MetaData" and meta.root.child("Title").text == "", "metadata parses, empty Title")


func _test_xml_errors() -> void:
	_assert(DawXml.parse("<a><b></a>".to_utf8_buffer()).root == null, "mismatched tags fail")
	var unclosed: Dictionary = DawXml.parse("<a>\n<b>\n".to_utf8_buffer())
	_assert(unclosed.root == null and "never closed" in unclosed.error, "unclosed element reports its tag")
	_assert(DawXml.parse("".to_utf8_buffer()).root == null, "empty input fails")
	var garbage: Dictionary = DawXml.parse("not xml at all".to_utf8_buffer())
	_assert(garbage.root == null and garbage.error != "", "non-XML fails with a message")


func _test_xml_writer_round_trip() -> void:
	var name := "A & \"B\" <x>"
	var w := DawXml.Writer.new()
	w.open("Project", {"version": "1.0"})
	w.open("Track", {"name": name, "value": 0.501187, "flag": true})
	w.leaf("Note", {"time": 1.5})
	w.close()
	w.leaf("Title", {}, "Song & Dance")
	w.close()
	var parsed: Dictionary = DawXml.parse(w.to_bytes())
	_assert(parsed.root != null, "writer output parses (%s)" % parsed.error)
	var track: DawXml.El = parsed.root.child("Track")
	_assert(track.get_attr("name") == name, "escaped attribute survives the round trip")
	_assert(is_equal_approx(track.get_float("value"), 0.501187), "number survives")
	_assert(track.get_bool("flag"), "bool written as true")
	_assert(track.child("Note").get_float("time") == 1.5, "leaf child")
	_assert(parsed.root.child("Title").text == "Song & Dance", "text content escaped and restored")
	_assert(w.to_text().contains("    <Track"), "children are indented")


func _test_conversions() -> void:
	_assert(is_equal_approx(DawUnits.volume_db_to_linear(-6.0), 0.501187), "-6 dB -> 0.501187")
	_assert(absf(DawUnits.linear_to_db(0.501187) + 6.0) < 0.001, "0.501187 -> -6 dB")
	_assert(DawUnits.linear_to_db(0.0) == -60.0, "linear 0 -> -60 dB")
	_assert(DawUnits.volume_db_to_linear(-60.0) == 0.0, "-60 dB -> linear 0")
	_assert(DawUnits.linear_to_db(DawUnits.db_to_linear(20.0)) == 12.0, "+20 dB clamps to +12")
	_assert(DawUnits.linear_exceeds_max(DawUnits.db_to_linear(20.0)), "+20 dB flagged as exceeding")
	_assert(not DawUnits.linear_exceeds_max(DawUnits.db_to_linear(12.0)), "+12 dB is within range")
	_assert(absf(DawUnits.linear_to_db(0.071991) + 22.85) < 0.01, "send 0.071991 -> -22.85 dB")
	_assert(DawUnits.pan_to_normalized(-0.5) == 0.25 and DawUnits.normalized_to_pan(0.25) == -0.5, "pan -0.5 <-> 0.25")
	_assert(absf(DawUnits.velocity_to_normalized(100) - 0.787402) < 1e-6, "velocity 100 -> 0.787402")
	_assert(DawUnits.normalized_to_velocity(0.787402) == 100, "0.787402 -> velocity 100")
	_assert(DawUnits.normalized_to_velocity(0.0) == 1, "velocity clamps to 1")
	_assert(DawUnits.beats_to_ticks(1.8333330154418945) == 1760, "1.8333 beats -> 1760 ticks")
	_assert(DawUnits.ticks_to_beats(3840) == 4.0, "3840 ticks -> 4 beats")
	_assert(DawUnits.real_to_param(null, 0.5, 0.0, 2.0) == 0.25, "unknown param maps linearly over min/max")
	_assert(DawUnits.param_to_real(null, 0.25, 0.0, 2.0) == 0.5, "and back")


func _lane_point(tick: int, value: float, step: bool = false, tension: float = 0.0) -> Dictionary:
	return {"tick": tick, "value": value, "step": step, "tension": tension}


## Interpolate the emitted points at `tick`, honouring holds.
func _eval_out(points: Array, tick: int) -> float:
	for i in range(points.size() - 1):
		var a: Dictionary = points[i]
		var b: Dictionary = points[i + 1]
		if tick >= a.tick and tick <= b.tick:
			if a.step:
				return a.value
			if b.tick == a.tick:
				return b.value
			return a.value + (b.value - a.value) * float(tick - a.tick) / float(b.tick - a.tick)
	return points[points.size() - 1].value


func _test_resample() -> void:
	# Curved segment through the identity map: within 1% of the range.
	var curved := [_lane_point(0, 0.0, false, 0.7), _lane_point(960, 1.0)]
	var out := DawUnits.resample(curved, func(v: float) -> float: return v, 0.01)
	var worst := 0.0
	for i in 101:
		var tick := roundi(960.0 * i / 100.0)
		var truth := AutomationCurve.apply_tension(float(tick) / 960.0, 0.7)
		worst = maxf(worst, absf(_eval_out(out, tick) - truth))
	_assert(worst <= 0.01, "tension 0.7 segment within 1%% at 100 samples (worst %.4f, %d points)" % [worst, out.size()])
	_assert(out.size() > 2, "a curve needs extra points")

	# Straight segment through a linear map: no extra points.
	var straight := [_lane_point(0, 0.0), _lane_point(960, 1.0)]
	out = DawUnits.resample(straight, func(v: float) -> float: return v * 2.0, 0.01)
	_assert(out.size() == 2, "straight linear segment emits no extra points (got %d)" % out.size())

	# -60 -> 0 dB linear ramp to gain (range 0..2, 1% = 0.02).
	var db_ramp := [_lane_point(0, -60.0), _lane_point(3840, 0.0)]
	out = DawUnits.resample(db_ramp, func(db: float) -> float: return DawUnits.volume_db_to_linear(db), 0.02)
	worst = 0.0
	for tick in range(0, 3841, 40):
		var db: float = -60.0 + 60.0 * float(tick) / 3840.0
		worst = maxf(worst, absf(_eval_out(out, tick) - DawUnits.volume_db_to_linear(db)))
	_assert(worst <= 0.02, "dB ramp to gain within 1%% of range (worst %.4f, %d points)" % [worst, out.size()])

	# The other direction: a linear gain ramp becomes dB points.
	var gain_ramp := [_lane_point(0, 0.0), _lane_point(3840, 1.0)]
	out = DawUnits.resample(gain_ramp, func(g: float) -> float: return DawUnits.linear_to_db(g), 0.72)
	worst = 0.0
	for tick in range(40, 3841, 40):
		worst = maxf(worst, absf(_eval_out(out, tick) - DawUnits.linear_to_db(float(tick) / 3840.0)))
	_assert(worst <= 0.72, "gain ramp to dB within 1%% of the 72 dB range (worst %.3f)" % worst)

	# Step: hold flag on the left point, value unchanged.
	out = DawUnits.resample([_lane_point(0, 0.25, true), _lane_point(480, 0.75)], func(v: float) -> float: return v, 0.01)
	_assert(out.size() == 2 and out[0].step and not out[1].step and out[0].value == 0.25, "STEP point emits a hold")


func _test_clap_preset() -> void:
	var file := FileAccess.open(ProjectSettings.globalize_path("res://tests/fixtures/dawproject/sonara_test_01.dawproject"), FileAccess.READ)
	_assert(file != null, "fixture opens")
	var zip := ZIPReader.new()
	zip.open(ProjectSettings.globalize_path(FIXTURE))
	var preset_path := ""
	for f in zip.get_files():
		if f.ends_with(".clap-preset"):
			preset_path = f
	var bytes := zip.read_file(preset_path)
	zip.close()
	var unwrapped: Dictionary = ClapPreset.unwrap(bytes)
	_assert(unwrapped.ok and unwrapped.clap_id == "nakst.Apricot", "unwrap gives nakst.Apricot")
	_assert(unwrapped.state.size() == 16133, "unwrap gives 16133 state bytes (got %d)" % unwrapped.state.size())
	_assert(ClapPreset.wrap(unwrapped.clap_id, unwrapped.state) == bytes, "wrap is byte-identical to the fixture")
	_assert(not ClapPreset.unwrap("nope, no magic".to_utf8_buffer()).ok, "file without the clap magic is an error")
	_assert(not ClapPreset.unwrap(PackedByteArray([0x63, 0x6c, 0x61, 0x70, 0xff, 0, 0, 0])).ok, "oversized id length is an error")


func _test_report() -> void:
	var report := TransferReport.new()
	_assert(report.is_empty(), "new report is empty")
	for i in 212:
		report.add(TransferReport.NOTE_CHANNEL, "Lead", "2")
	report.add(TransferReport.NOTE_CHANNEL, "Bass", "1")
	report.add(TransferReport.CLAP_MISSING, "Pad", "Foo Synth")
	_assert(report.entries().size() == 3, "aggregates by (kind, subject): 3 entries")
	_assert(report.entry_text(report.entries()[0]) == "Lead: 212 notes on MIDI channel 2 moved to channel 0", "entry reads as the requirement example: %s" % report.entry_text(report.entries()[0]))
	_assert(report.count_of(TransferReport.NOTE_CHANNEL) == 213, "count_of sums a kind")
	_assert(report.to_text().split("\n").size() == 3, "to_text has one line per entry")


func _test_sfz() -> void:
	var dir := "user://dawproject_sfz_test"
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.make_dir_recursive_absolute(dir + "/samples")
	for f in ["samples/kick one.wav", "samples/snare.wav", "extra.sfz"]:
		var fh := FileAccess.open(dir + "/" + f, FileAccess.WRITE)
		fh.store_string("x")
		fh.close()
	var extra := FileAccess.open(dir + "/extra.sfz", FileAccess.WRITE)
	extra.store_string("<region> sample=snare.wav lokey=38\n")
	extra.close()
	var sfz := FileAccess.open(dir + "/main.sfz", FileAccess.WRITE)
	sfz.store_string("// comment sample=ignored.wav\n<control> default_path=samples/\n#include \"extra.sfz\"\n<region> sample=kick one.wav lokey=36 hikey=36\n<region> sample=gone.wav lokey=40\n<region> sample=*sine\n")
	sfz.close()
	var abs_dir := ProjectSettings.globalize_path(dir)
	var result: Dictionary = SfzFiles.collect(abs_dir + "/main.sfz")
	var files: PackedStringArray = result.files
	_assert(files.has(abs_dir + "/main.sfz"), "SFZ itself is collected")
	_assert(files.has(abs_dir + "/extra.sfz"), "#include is collected")
	_assert(files.has(abs_dir + "/samples/kick one.wav"), "sample with spaces resolved through default_path")
	_assert(files.has(abs_dir + "/samples/snare.wav"), "included file's sample resolved through default_path")
	_assert(files.size() == 4, "exactly four files (got %d)" % files.size())
	_assert(result.missing.size() == 1 and result.missing[0].ends_with("gone.wav"), "missing sample listed; comment and *sine ignored")
