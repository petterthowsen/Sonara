# test_simple_layout_model.gd
# Headless tests for the Simple View layout model and store (REQ-010, REQ-016, REQ-017).
# Run: godot --headless --path Godot -s tests/test_simple_layout_model.gd -- --test
extends TestBase


var _tmp_dir := ""


func suite_name() -> String:
	return "Simple View layout model tests"


func run_tests() -> void:
	_tmp_dir = OS.get_temp_dir().path_join("sonara_simple_layout_test_%d" % Time.get_ticks_usec())
	SimpleLayoutStore.base_dir_override = _tmp_dir
	_test_roundtrip_json()
	_test_unknown_version_rejected()
	_test_validate_finds_overlap_and_bounds()
	_test_find_free_rect()
	_test_resize_grid_reflows()
	_test_reconcile_param_changes()
	_test_corrupt_file_not_overwritten()
	_test_missing_file_generated_and_saved()
	_test_path_for_distinct_ids()
	_test_simple_units()
	_cleanup()


func _control(kind: String, params: Array, rect: Array, group := "") -> Dictionary:
	var c := {"kind": kind, "params": params, "rect": rect}
	if not group.is_empty():
		c["group"] = group
	return c


func _sample_layout() -> SimpleLayout:
	var layout := SimpleLayout.new()
	layout.device_id = "test.device"
	layout.kind = "reverb"
	layout.pages = [{
		"title": "Main",
		"groups": [{"id": "mix", "title": "Mix", "rect": [0, 0, 2, 1]}],
		"controls": [
			_control("knob", [1], [0, 0, 1, 1], "mix"),
			_control("knob", [2], [1, 0, 1, 1], "mix"),
			_control("xy", [3, 4], [4, 0, 2, 2]),
			_control("envelope", [5, 6, 7, 8], [3, 2, 3, 2]),
		],
	}]
	layout.pages[0].controls[0]["label"] = "Dry"
	layout.pages[0].controls[0]["unit"] = "%"
	return layout


func _param(id: int, name: String) -> DeviceParameter:
	return DeviceParameter.new(id, name)


func _test_roundtrip_json() -> void:
	var layout := _sample_layout()
	var text := JSON.stringify(layout.to_dict(), "\t")
	var parsed: Variant = JSON.parse_string(text)
	var back := SimpleLayout.from_dict(parsed)
	_assert(back != null, "round trip parses")
	if back == null:
		return
	_assert(JSON.stringify(back.to_dict(), "\t") == text, "round trip JSON is identical")
	_assert(back.pages[0].controls[0].params[0] is int, "params come back as ints")
	_assert(back.pages[0].controls[0].label == "Dry" and back.pages[0].controls[0].unit == "%", "label and unit kept")
	_assert(back.validate().is_empty(), "sample layout is valid: %s" % [back.validate()])


func _test_unknown_version_rejected() -> void:
	var d := _sample_layout().to_dict()
	d.version = 99
	_assert(SimpleLayout.from_dict(d) == null, "unknown version rejected")
	_assert(SimpleLayout.from_dict([1, 2]) == null, "non-dictionary rejected")
	var bad := _sample_layout().to_dict()
	bad.pages[0].controls[0].rect = [0, 0]
	_assert(SimpleLayout.from_dict(bad) == null, "malformed rect rejected")


func _test_validate_finds_overlap_and_bounds() -> void:
	var layout := _sample_layout()
	layout.pages[0].controls.append(_control("knob", [10], [0, 0, 1, 1]))
	layout.pages[0].controls.append(_control("knob", [11], [6, 0, 1, 1]))
	layout.pages[0].controls.append(_control("xy", [12], [0, 3, 2, 1]))
	var problems := layout.validate()
	_assert(problems.size() == 3, "overlap, out of bounds and param count reported: %s" % [problems])


func _test_find_free_rect() -> void:
	var layout := _sample_layout()
	_assert(layout.find_free_rect(0, 1, 1) == [2, 0, 1, 1], "first free 1×1 is after the two knobs")
	_assert(layout.find_free_rect(0, 3, 2) == [0, 1, 3, 2], "first free 3×2 is below the knobs")
	_assert(layout.find_free_rect(0, 6, 4) == [], "no room for a full page")
	_assert(layout.find_free_rect(5, 1, 1) == [], "missing page gives []")


func _test_resize_grid_reflows() -> void:
	var layout := _sample_layout()
	var before := layout.param_ids()
	before.sort()
	layout.resize_grid(4, 4)
	var after := layout.param_ids()
	after.sort()
	_assert(after == before, "every control kept after 6×4 → 4×4: %s" % [after])
	_assert(layout.validate().is_empty(), "no overlaps or out-of-bounds after shrink: %s" % [layout.validate()])
	_assert(layout.pages[0].controls[0].rect == [0, 0, 1, 1], "a control that still fits stays put")

	var tiny := _sample_layout()
	tiny.resize_grid(2, 2)
	_assert(tiny.validate().is_empty(), "2×2 shrink is valid: %s" % [tiny.validate()])
	_assert(tiny.pages.size() >= 2, "overflow adds pages")
	for page in tiny.pages:
		for g in page.groups:
			var r := GridPacker.rect_from_array(g.rect)
			_assert(r.end.x <= 2 and r.end.y <= 2, "group rect inside the 2×2 grid: %s" % [g.rect])


func _test_reconcile_param_changes() -> void:
	var layout := SimpleLayout.new()
	layout.device_id = "test.reconcile"
	layout.pages = [{"title": "Main", "groups": [], "controls": [
		_control("knob", [1], [2, 1, 1, 1]),
		_control("knob", [2], [0, 0, 1, 1]),
		_control("knob", [99], [1, 0, 1, 1]),
	]}]
	var result := layout.reconcile([_param(1, "One"), _param(2, "Two"), _param(3, "Three")])
	_assert(result.removed == [99], "99 removed: %s" % [result.removed])
	_assert(result.added == [3], "3 added: %s" % [result.added])
	var ids := layout.param_ids()
	ids.sort()
	_assert(ids == [1, 2, 3], "layout holds 1, 2, 3: %s" % [ids])
	_assert(layout.pages[0].controls[0].rect == [2, 1, 1, 1], "param 1 kept its cell")
	_assert(layout.pages[0].controls[1].rect == [0, 0, 1, 1], "param 2 kept its cell")
	_assert(layout.validate().is_empty(), "reconciled layout valid")

	var hidden := _param(2, "Two")
	hidden.is_hidden = true
	var again := layout.reconcile([_param(1, "One"), hidden, _param(3, "Three")])
	_assert(again.removed == [2], "a parameter that became hidden is removed")

	var compound := SimpleLayout.new()
	compound.pages = [{"title": "Main", "groups": [], "controls": [_control("xy", [5, 6], [0, 0, 2, 2])]}]
	var r2 := compound.reconcile([_param(5, "Pos X")])
	_assert(r2.removed == [6] and r2.added == [5], "a compound missing a part becomes a single control")


## SimpleUnits display formatting (REQ-013): %, s→ms and Hz→kHz above 1000.
func _test_simple_units() -> void:
	var pct := _param(0, "Dry")
	pct.min_value = 0.0
	pct.max_value = 1.0
	_assert(SimpleUnits.format(pct, 0.35, "%") == "35%", "%% shows 35 for normalized 0.35: %s" % SimpleUnits.format(pct, 0.35, "%"))

	var attack := _param(1, "Attack")
	attack.unit = "s"
	attack.min_value = 0.0
	attack.max_value = 2.0
	var half_normalized := attack.value_to_normalized(0.5)
	_assert(SimpleUnits.format(attack, half_normalized, "ms") == "500.0 ms", "s converts to ms: %s" % SimpleUnits.format(attack, half_normalized, "ms"))

	var cutoff := _param(2, "Cutoff")
	cutoff.unit = "Hz"
	cutoff.min_value = 20.0
	cutoff.max_value = 20000.0
	var hz_normalized := cutoff.value_to_normalized(2000.0)
	_assert(SimpleUnits.format(cutoff, hz_normalized, "Hz") == "2.00 kHz", "Hz switches to kHz above 1000: %s" % SimpleUnits.format(cutoff, hz_normalized, "Hz"))
	_assert(SimpleUnits.format(cutoff, cutoff.value_to_normalized(500.0), "Hz") == "500 Hz", "Hz stays Hz at or below 1000: %s" % SimpleUnits.format(cutoff, cutoff.value_to_normalized(500.0), "Hz"))


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _test_corrupt_file_not_overwritten() -> void:
	SimpleLayoutStore.clear_cache()
	var device := Device.new("test.corrupt", "Corrupt Reverb", Device.DeviceCategory.Effect)
	var params := [_param(0, "Dry Level"), _param(1, "Decay")]
	var path := SimpleLayoutStore.path_for(device.device_id)
	var garbage := "{ this is not json"
	_write(path, garbage)
	var layout := SimpleLayoutStore.load_or_generate(device, params)
	_assert(layout != null and layout.param_ids().size() == 2, "broken file gives a generated layout")
	_assert(FileAccess.get_file_as_string(path) == garbage, "broken file left unchanged")

	SimpleLayoutStore.clear_cache()
	var future := _sample_layout().to_dict()
	future.version = 2
	var future_text := JSON.stringify(future)
	_write(path, future_text)
	var layout2 := SimpleLayoutStore.load_or_generate(device, params)
	_assert(layout2 != null and layout2.generated, "unknown version gives a generated layout")
	_assert(FileAccess.get_file_as_string(path) == future_text, "unknown-version file left unchanged")
	SimpleLayoutStore.clear_cache()


func _test_missing_file_generated_and_saved() -> void:
	SimpleLayoutStore.clear_cache()
	var device := Device.new("test.fresh", "Fresh Delay", Device.DeviceCategory.Effect)
	var params := [_param(0, "Time"), _param(1, "Feedback")]
	var layout := SimpleLayoutStore.load_or_generate(device, params)
	var path := SimpleLayoutStore.path_for(device.device_id)
	_assert(FileAccess.file_exists(path), "generated layout saved")
	SimpleLayoutStore.clear_cache()
	var loaded := SimpleLayoutStore.load_layout(device.device_id)
	_assert(loaded.status == SimpleLayoutStore.LoadStatus.OK, "saved file loads")
	if loaded.layout != null:
		_assert(JSON.stringify(loaded.layout.to_dict()) == JSON.stringify(layout.to_dict()), "loaded layout matches saved")
	SimpleLayoutStore.clear_cache()


func _test_path_for_distinct_ids() -> void:
	var a := SimpleLayoutStore.path_for("clap:com.x/y")
	var b := SimpleLayoutStore.path_for("clap_com.x_y")
	_assert(a != b, "ids that sanitize alike get different files: %s vs %s" % [a, b])
	var file := a.get_file()
	_assert(RegEx.create_from_string("^[A-Za-z0-9._-]+$").search(file) != null, "file name is safe: %s" % file)
	_assert(a.get_base_dir() == _tmp_dir, "path is under the base dir")
	_assert(SimpleLayoutStore.path_for("clap:com.x/y") == a, "path_for is stable")


func _cleanup() -> void:
	SimpleLayoutStore.base_dir_override = ""
	var dir := DirAccess.open(_tmp_dir)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(_tmp_dir)
