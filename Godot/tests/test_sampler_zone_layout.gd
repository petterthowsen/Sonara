# Sampler multisample range math (spec 023, REQ-020 and REQ-047): root keys from file names, the
# default key layout, and the batch assign / distribute operations. Pure functions, no model.
# Run: godot --headless --path Godot -s tests/test_sampler_zone_layout.gd -- --test
extends TestBase

var _layout: GDScript
var _zone: GDScript


func suite_name() -> String:
	return "Sampler zone layout"


func run_tests() -> void:
	_layout = load("res://devices/builtin/sampler/ZoneLayout.gd")
	_zone = load("res://data/SamplerZone.gd")
	_test_parse_root()
	_test_layout_from_names()
	_test_layout_fallback()
	_test_layout_mixed()
	_test_layout_at_key()
	_test_assign()
	_test_distribute_velocity()
	_test_distribute_uneven()
	_test_distribute_notes()
	_test_set_root_from_name()


func _zones(count: int, roots: Array = []) -> Array:
	var out: Array = []
	for i in count:
		var z: Object = _zone.new(i + 1, "/tmp/z%d.wav" % i)
		if i < roots.size():
			z.root = roots[i]
		out.append(z)
	return out


func _test_parse_root() -> void:
	var cases := {
		"Piano_C3.wav": 60, "Piano_E3.wav": 64, "Piano_G#3.wav": 68, "C#3": 61, "Db3": 61,
		"c-1": 12, "C-2": 0, "G8": 127, "pad-060.wav": 60, "127": 127, "000": 0,
		"kick.wav": -1, "snare": -1, "Strings_A2_soft": 57, "bass b2": 59, "Bb1": 46,
		"/some/dir/Piano_D3.wav": 62, "999": -1, "G#8": -1,
	}
	for name in cases:
		_assert(_layout.parse_root(name) == cases[name], "parse_root(%s) = %d (got %d)" % [name, cases[name], _layout.parse_root(name)])
	_assert(_layout.parse_root("C3_vel_100") == 60, "a note name wins over a number")


func _test_layout_from_names() -> void:
	var out: Array = _layout.layout([60, 64, 68])
	_assert(out[0] == {"root": 60, "key_lo": 0, "key_hi": 62}, "REQ-020: C3 covers 0-62 (%s)" % [out[0]])
	_assert(out[1] == {"root": 64, "key_lo": 63, "key_hi": 66}, "REQ-020: E3 covers 63-66 (%s)" % [out[1]])
	_assert(out[2] == {"root": 68, "key_lo": 67, "key_hi": 127}, "REQ-020: G#3 covers 67-127 (%s)" % [out[2]])
	out = _layout.layout([68, 60, 64])
	_assert(out[0]["key_lo"] == 67 and out[1]["key_hi"] == 62, "results follow the input order, not the root order")
	out = _layout.layout([60, 60])
	_assert(out[0] == out[1] and out[0]["key_lo"] == 0 and out[0]["key_hi"] == 127, "equal roots share one full range")
	out = _layout.layout([60])
	_assert(out[0]["key_lo"] == 0 and out[0]["key_hi"] == 127, "a single zone covers every key")


func _test_layout_fallback() -> void:
	var out: Array = _layout.layout([-1, -1, -1])
	_assert(out.map(func(o): return o["key_lo"]) == [60, 61, 62], "no names: consecutive keys from C3")
	_assert(out.all(func(o): return o["key_lo"] == o["key_hi"] and o["root"] == o["key_lo"]), "each zone is one key with its root on it")
	out = _layout.layout([-1, -1], 65)
	_assert(out.map(func(o): return o["root"]) == [65, 66], "a map drop starts at the key under the pointer")
	out = _layout.layout([-1, -1], 127)
	_assert(out.map(func(o): return o["key_lo"]) == [127, 127], "keys past 127 clamp to 127")


func _test_layout_mixed() -> void:
	var out: Array = _layout.layout([-1, 60, 64, -1])
	_assert(out[1]["key_lo"] == 0 and out[1]["key_hi"] == 62, "mixed: detected zones keep the halfway layout")
	_assert(out[2]["key_hi"] == 64, "mixed: the highest detected zone stops at its root")
	_assert(out[0]["root"] == 65 and out[3]["root"] == 66, "mixed: unnamed zones follow the highest detected zone, in order")
	_assert(out[0]["key_lo"] == 65 and out[0]["key_hi"] == 65, "mixed: unnamed zones get single keys")


func _test_layout_at_key() -> void:
	var out: Array = _layout.layout([60, 64], 40)
	_assert(out[0]["key_lo"] == 40 and out[0]["key_hi"] == 62, "at_key: the lowest zone starts at the pointer key")
	out = _layout.layout([60, 64], 70)
	_assert(out[0]["key_lo"] <= out[0]["key_hi"], "at_key above a root never gives an empty range")


func _test_assign() -> void:
	var zs := _zones(2)
	var v: Dictionary = _layout.assign_velocity(zs, 90, 30)
	_assert(v[1] == {"vel_lo": 30, "vel_hi": 90} and v[2] == v[1], "assign_velocity orders and applies to every zone")
	v = _layout.assign_velocity(zs, 0, 500)
	_assert(v[1] == {"vel_lo": 1, "vel_hi": 127}, "assign_velocity clamps to 1-127")
	var k: Dictionary = _layout.assign_note(zs, 64, 64)
	_assert(k[1] == {"key_lo": 64, "key_hi": 64}, "assign_note with one value is a single key")
	k = _layout.assign_note(zs, -5, 200)
	_assert(k[2] == {"key_lo": 0, "key_hi": 127}, "assign_note clamps to 0-127")


func _test_distribute_velocity() -> void:
	var v: Dictionary = _layout.distribute_velocity(_zones(4), 1, 127)
	var got := [v[1], v[2], v[3], v[4]].map(func(r): return [r["vel_lo"], r["vel_hi"]])
	_assert(got == [[1, 32], [33, 64], [65, 96], [97, 127]], "REQ-047: four zones on 1-127 stretch (%s)" % [got])
	v = _layout.distribute_velocity(_zones(2), 1, 127, false, 20)
	got = [v[1], v[2]].map(func(r): return [r["vel_lo"], r["vel_hi"]])
	_assert(got == [[1, 20], [21, 40]], "gaps: equal slices of the given size from the low end (%s)" % [got])
	v = _layout.distribute_velocity(_zones(3), 100, 110, false, 8)
	got = [v[1], v[2], v[3]].map(func(r): return [r["vel_lo"], r["vel_hi"]])
	_assert(got == [[100, 107], [108, 110], [110, 110]], "gaps: slices past the range end stack on its last step (%s)" % [got])


func _test_distribute_uneven() -> void:
	var v: Dictionary = _layout.distribute_velocity(_zones(3), 1, 10)
	var got := [v[1], v[2], v[3]].map(func(r): return [r["vel_lo"], r["vel_hi"]])
	_assert(got == [[1, 4], [5, 7], [8, 10]], "uneven split covers the range without gaps (%s)" % [got])
	v = _layout.distribute_velocity(_zones(5), 10, 12)
	got = [v[1], v[2], v[3], v[4], v[5]].map(func(r): return r["vel_lo"])
	_assert(got == [10, 10, 11, 11, 12], "more zones than steps: single steps shared in order (%s)" % [got])
	_assert([v[1], v[5]].all(func(r): return r["vel_lo"] == r["vel_hi"]), "more zones than steps: no empty range")
	_assert(_layout.distribute_velocity([], 1, 127).is_empty(), "no zones: nothing to do")
	v = _layout.distribute_velocity(_zones(1), 1, 127)
	_assert(v[1] == {"vel_lo": 1, "vel_hi": 127}, "one zone fills the range")


func _test_distribute_notes() -> void:
	var zs := _zones(3, [72, 60, 66])
	var k: Dictionary = _layout.distribute_notes(zs, 48, 83)
	_assert(k[2]["key_lo"] == 48 and k[3]["key_lo"] == 60 and k[1]["key_lo"] == 72, "distribute_notes orders by root key")
	_assert(k[1]["key_hi"] == 83 and k[2]["key_hi"] == 59, "distribute_notes fills the range")
	k = _layout.distribute_notes(_zones(2, [60, 60]), 0, 127)
	_assert(k[1]["key_lo"] == 0 and k[2]["key_lo"] == 64, "equal roots keep list order")


func _test_set_root_from_name() -> void:
	var zs := _zones(3)
	zs[0].set_path("/x/Piano_C3.wav")
	zs[1].set_path("/x/kick.wav")
	zs[2].set_path("/x/Piano_G3.wav")
	var r: Dictionary = _layout.set_root_from_name(zs)
	_assert(r.size() == 2 and r[1] == {"root": 60} and r[3] == {"root": 67}, "set_root_from_name changes only zones with a note in the name (%s)" % [r])
