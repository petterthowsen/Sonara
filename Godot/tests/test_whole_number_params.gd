# Whole-number parameters (semitones, octaves, %, MIDI keys) show real units and type in real units.
# Run: godot --headless --path Godot -s tests/test_whole_number_params.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Whole-number parameters"


func run_tests() -> void:
	var st := _param("st", -48.0, 48.0)
	_assert(st.is_whole_number(), "semitones are whole")
	_assert(st.format_value(7.0) == "7 st", "semitones read '7 st' (got %s)" % st.format_value(7.0))
	_assert(st.edit_text(-12.0) == "-12", "edit text is the bare number")
	_assert(is_equal_approx(st.parse_edit_text("5 st"), 5.0), "unit suffix is accepted")
	_assert(is_nan(st.parse_edit_text("abc")), "junk is rejected")

	var pct := _param("%", 0.0, 100.0)
	_assert(pct.format_value(50.0) == "50%", "percent reads '50%%' (got %s)" % pct.format_value(50.0))

	var key := _param("key", 0.0, 127.0)
	_assert(key.format_value(60.0) == "C3", "key 60 is C3 (got %s)" % key.format_value(60.0))
	_assert(is_equal_approx(key.parse_edit_text("C3"), 60.0), "note name parses")
	_assert(is_equal_approx(key.parse_edit_text("61"), 61.0), "key number parses")

	var curved := _param("%", 0.0, 100.0)
	curved.display_curve = PackedFloat32Array([0.0, 50.0])
	_assert(not curved.is_whole_number(), "plugin params with a display curve are left alone")
	_assert(not _param("", 0.0, 1.0).is_whole_number(), "unitless params are left alone")


func _param(unit: String, lo: float, hi: float) -> DeviceParameter:
	var p := DeviceParameter.new(0, "P", unit)
	p.min_value = lo
	p.max_value = hi
	return p
