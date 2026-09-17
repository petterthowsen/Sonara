# test_simple_layout_generator.gd
# Headless tests for Simple View layout generation (REQ-002 – REQ-008).
# Run: godot --headless --path Godot -s tests/test_simple_layout_generator.gd -- --test
extends TestBase


const DRAGONFLY_FIXTURE := "res://tests/fixtures/simple_view/dragonfly_hall_params.json"


func suite_name() -> String:
	return "Simple View generator tests"


func run_tests() -> void:
	_test_kind_inference()
	_test_control_kinds()
	_test_hidden_readonly_excluded()
	_test_compounds()
	_test_grouping_module_and_role()
	_test_main_page_importance()
	_test_no_overlap_in_bounds()
	_test_generate_500_params_under_100ms()
	_test_dragonfly_hall_fixture()


## ----------------------------------------------------------------------------
## Helpers
## ----------------------------------------------------------------------------

func _device(id: String, name: String, category := Device.DeviceCategory.Effect, features: Array[String] = []) -> Device:
	var d := Device.new(id, name, category)
	d.features = features
	return d


func _float(id: int, name: String, unit := "", min_v := 0.0, max_v := 1.0) -> DeviceParameter:
	var p := DeviceParameter.new(id, name, unit)
	p.min_value = min_v
	p.max_value = max_v
	return p


func _enum(id: int, name: String, count: int) -> DeviceParameter:
	var p := DeviceParameter.new(id, name)
	p.param_type = "enum"
	var values: Array[String] = []
	for i in range(count):
		values.append("v%d" % i)
	p.enum_values = values
	return p


func _bool(id: int, name: String) -> DeviceParameter:
	var p := DeviceParameter.new(id, name)
	p.param_type = "bool"
	return p


func _items(params: Array, kind := DeviceKind.GENERIC) -> Array[Dictionary]:
	var strategy := SimpleLayoutGenerator.strategy_for(kind)
	return CompoundDetector.detect(ParamClassifier.classify(params, strategy))


## Control holding `param_id`, with its page index under "page" and the page's group title under "group_title".
func _find(layout: SimpleLayout, param_id: int) -> Dictionary:
	for i in range(layout.pages.size()):
		var page: Dictionary = layout.pages[i]
		for c in page.controls:
			if param_id in c.params:
				var title := ""
				for g in page.groups:
					if g.id == c.get("group", ""):
						title = g.title
				return {"control": c, "page": i, "group": c.get("group", ""), "group_title": title}
	return {}


## Each visible param appears exactly once and the layout validates.
func _check_layout(layout: SimpleLayout, params: Array, what: String) -> void:
	var problems := layout.validate()
	_assert(problems.is_empty(), "%s: valid layout %s" % [what, problems])
	var expected: Array[int] = []
	for p in params:
		if ParamClassifier.is_visible(p):
			expected.append(p.id)
	expected.sort()
	var ids := layout.param_ids()
	ids.sort()
	_assert(ids == expected, "%s: every visible parameter placed once" % what)


## ----------------------------------------------------------------------------
## Tests
## ----------------------------------------------------------------------------

func _test_kind_inference() -> void:
	_assert(DeviceKind.infer(_device("x.verb", "Something", Device.DeviceCategory.Effect, ["audio-effect", "reverb"])) == DeviceKind.REVERB,
		"reverb feature → reverb")
	_assert(DeviceKind.infer(_device("sonara.builtin.thing", "Thing", Device.DeviceCategory.Instrument)) == DeviceKind.SYNTH,
		"builtin instrument without tags → synth")
	_assert(DeviceKind.infer(_device("x.foo", "Foo", Device.DeviceCategory.Effect, ["audio-effect"])) == DeviceKind.GENERIC,
		"audio-effect named Foo → generic")
	_assert(DeviceKind.infer(_device("michaelwillis.dragonfly.plate", "Dragonfly Plate Reverb")) == DeviceKind.REVERB,
		"Dragonfly Plate Reverb (no tags) → reverb")
	_assert(DeviceKind.infer(_device("sonara.builtin.delay", "Delay")) == DeviceKind.DELAY, "builtin delay → delay")
	_assert(DeviceKind.infer(_device("sonara.builtin.polysynth", "PolySynth", Device.DeviceCategory.Utility)) == DeviceKind.SYNTH,
		"polysynth by name → synth")
	_assert(DeviceKind.infer(_device("sonara.builtin.polysynth", "PolySynth", Device.DeviceCategory.Instrument)) == DeviceKind.SYNTH,
		"builtin polysynth → synth")
	_assert(DeviceKind.infer(_device("x.comp", "Bus Compressor", Device.DeviceCategory.Effect, ["audio-effect", "compressor"])) == DeviceKind.COMPRESSOR,
		"compressor feature → compressor")
	_assert(DeviceKind.infer(_device("x.eq", "Para EQ")) == DeviceKind.EQ, "EQ by name → eq")
	_assert(DeviceKind.infer(_device("x.seq", "Step Sequencer")) == DeviceKind.GENERIC, "'sequencer' is not an eq")
	_assert(DeviceKind.infer(null) == DeviceKind.GENERIC, "null → generic")


func _test_control_kinds() -> void:
	var params := [_bool(0, "On"), _enum(1, "Mode", 4), _enum(2, "Scale", 12), _float(3, "Amount"), _enum(4, "Two", 2)]
	var kinds := []
	for e in ParamClassifier.classify(params, GenericStrategy.new()):
		kinds.append(e.kind)
	_assert(kinds == ["toggle", "segmented", "dropdown", "knob", "toggle"], "bool/4-enum/12-enum/float/2-enum kinds: %s" % [kinds])


func _test_hidden_readonly_excluded() -> void:
	var hidden := _float(1, "Hidden")
	hidden.is_hidden = true
	var readonly := _float(2, "Meter")
	readonly.is_read_only = true
	var bypass := _bool(3, "Bypass")
	bypass.is_bypass = true
	var params := [_float(0, "Gain"), hidden, readonly, bypass, _float(4, "Mix")]
	var layout := SimpleLayoutGenerator.generate(_device("x.g", "Generic"), params)
	var ids := layout.param_ids()
	ids.sort()
	_assert(ids == [0, 4], "hidden, read-only and bypass left out: %s" % [ids])


func _test_compounds() -> void:
	var xy := _items([_float(0, "position_x"), _float(1, "position_y")])
	_assert(xy.size() == 1 and xy[0].kind == "xy" and xy[0].params == [0, 1], "position_x + position_y → one xy")
	_assert(xy.size() == 1 and xy[0].label == "Position", "xy label from the stem")

	var eq := _items([_float(5, "band1_gain"), _float(4, "band1_freq"), _float(6, "band1_q")])
	_assert(eq.size() == 1 and eq[0].kind == "eq_band" and eq[0].params == [4, 5, 6], "band1 freq/gain/q → one eq_band in [freq, gain, q] order")

	var single := _items([_float(0, "pan_x")])
	_assert(single.size() == 1 and single[0].kind == "knob", "pan_x alone → knob")

	var adsr := _items([_float(0, "Amp Attack", "s", 0, 10), _float(1, "Amp Decay", "s", 0, 10),
		_float(2, "Amp Sustain"), _float(3, "Amp Release", "ms", 0, 5000), _float(4, "Cutoff")])
	_assert(adsr.size() == 2 and adsr[0].kind == "envelope" and adsr[0].params == [0, 1, 2, 3], "full ADSR → envelope")

	var partial := _items([_float(0, "Attack", "s"), _float(1, "Decay", "s"), _float(2, "Sustain")])
	var kinds := partial.map(func(i): return i.kind)
	_assert(kinds == ["knob", "knob", "knob"], "ADSR missing release → 3 knobs: %s" % [kinds])

	var not_time := _items([_float(0, "Attack", "dB", -60, 0), _float(1, "Decay", "s"), _float(2, "Sustain"), _float(3, "Release", "s")])
	_assert(not_time.size() == 4, "ADSR with a non-time attack stays single controls")

	var mixed := _items([_float(0, "Gain"), _float(1, "Pad X"), _float(2, "Pad Y"), _float(3, "Out")])
	_assert(mixed.size() == 3 and mixed[1].kind == "xy", "compound sits at its first parameter's position")

	var stepped := _enum(1, "Pos Y", 4)
	_assert(_items([_float(0, "Pos X"), stepped]).size() == 2, "non-float parts don't form compounds")


func _test_grouping_module_and_role() -> void:
	var size := _float(0, "Size")
	size.module = "Early/Size"
	var send := _float(1, "Send")
	send.module = "Early/Send"
	var late := _float(2, "Level")
	late.module = "Late/Level"
	var strategy := GenericStrategy.new()
	var groups := SimpleLayoutGenerator.group_items(_items([size, send, late]), strategy)
	var early: Array = groups.filter(func(g): return g.title == "Early")
	_assert(early.size() == 1 and early[0].items.size() == 2, "Early/Size and Early/Send form group Early")

	var reverb := ReverbStrategy.new()
	var params := [_float(0, "Dry Level"), _float(1, "Decay"), _float(2, "Size"), _float(3, "Low Cut"), _float(4, "Wet Level")]
	var rgroups := SimpleLayoutGenerator.group_items(_items(params, DeviceKind.REVERB), reverb)
	var mix_group: Dictionary = {}
	for g in rgroups:
		if g.items.any(func(i): return i.params == [0]):
			mix_group = g
	_assert(not mix_group.is_empty() and mix_group.items.any(func(i): return i.params == [4]),
		"reverb without modules: Dry Level and Wet Level share a group")

	var flat := [_float(0, "A"), _float(1, "B")]
	flat[0].module = "a"
	flat[1].module = "b"
	_assert(not SimpleLayoutGenerator.modules_group_parameters(_items(flat)), "one flat module per parameter isn't grouping")


func _test_main_page_importance() -> void:
	var params: Array = []
	var id := 0
	for i in range(30):
		params.append(_float(id, "Extra %d" % i))
		id += 1
	for n in ["Tone Low Cut", "Spin", "Mix", "Width", "Decay", "Size", "Wander"]:
		params.append(_float(id, n))
		id += 1
	var reverb := _device("x.rev", "Big Reverb", Device.DeviceCategory.Effect, ["reverb"])
	var layout := SimpleLayoutGenerator.generate(reverb, params)
	_check_layout(layout, params, "30+ param reverb")
	_assert(layout.pages.size() > 1, "reverb spans several pages")
	_assert(layout.pages[0].title == "Main", "first page is Main")
	for n in ["Mix", "Decay", "Size"]:
		var p := params.filter(func(x): return x.name == n)[0] as DeviceParameter
		_assert(_find(layout, p.id).get("page", -1) == 0, "reverb %s on page 1" % n)
	_assert(_find(layout, 0).get("page", -1) != 0, "unimportant parameter not on Main")

	var synth_params: Array = []
	for i in range(100):
		synth_params.append(_float(i, ["Cutoff", "Osc Wave", "LFO Rate", "Volume", "Thing"][i % 5] + " %d" % i))
	var synth := SimpleLayoutGenerator.generate(_device("x.syn", "Syn", Device.DeviceCategory.Instrument), synth_params)
	_check_layout(synth, synth_params, "100-param synth")
	var cells := 0
	for c in synth.pages[0].controls:
		cells += int(c.rect[2]) * int(c.rect[3])
	_assert(cells <= synth.columns * synth.rows, "synth page 1 holds at most one grid of cells (%d)" % cells)


func _test_no_overlap_in_bounds() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4004
	var names := ["Gain", "Mix", "Attack", "Decay", "Sustain", "Release", "Pos X", "Pos Y", "Band 1 Freq",
		"Band 1 Gain", "Band 1 Q", "Rate", "Depth", "Cutoff", "Reso", "Thing"]
	var kinds := [DeviceKind.GENERIC, DeviceKind.SYNTH, DeviceKind.REVERB, DeviceKind.DELAY, DeviceKind.COMPRESSOR, DeviceKind.EQ]
	for iteration in range(40):
		var params: Array = []
		for id in range(rng.randi_range(0, 90)):
			var name: String = names[rng.randi() % names.size()]
			var roll := rng.randi() % 10
			var p: DeviceParameter
			if roll == 0:
				p = _bool(id, name)
			elif roll == 1:
				p = _enum(id, name, rng.randi_range(2, 20))
			else:
				p = _float(id, name, "s" if rng.randi() % 2 == 0 else "", 0.0, 10.0)
			p.is_hidden = rng.randi() % 15 == 0
			if rng.randi() % 4 == 0:
				p.module = ["Osc/A", "Osc/B", "Filter/Main", "Amp"][rng.randi() % 4]
			params.append(p)
		var kind: String = kinds[iteration % kinds.size()]
		var device := _device("x.rand", kind, Device.DeviceCategory.Effect, [])
		var cols := rng.randi_range(2, 8)
		var rows := rng.randi_range(2, 6)
		var layout := SimpleLayoutGenerator.generate(device, params, cols, rows)
		_assert(layout.kind == kind, "random set %d: generated as %s" % [iteration, kind])
		var problems := layout.validate()
		if not problems.is_empty() or iteration % 10 == 0:
			_check_layout(layout, params, "random set %d (%d params, %d×%d)" % [iteration, params.size(), cols, rows])
		else:
			var ids := layout.param_ids()
			var visible := params.filter(func(p): return ParamClassifier.is_visible(p)).size()
			_assert(ids.size() == visible, "random set %d: %d params placed" % [iteration, visible])
		for page in layout.pages:
			for g in page.groups:
				var r := GridPacker.rect_from_array(g.rect)
				_assert(r.position.x >= 0 and r.position.y >= 0 and r.end.x <= cols and r.end.y <= rows,
					"random set %d: group rect in bounds" % iteration)
	# Each strategy on the same random-ish names.
	for kind in kinds:
		var params: Array = []
		for id in range(60):
			params.append(_float(id, "%s %d" % [names[id % names.size()], id / names.size()], "s", 0, 5))
		var strategy := SimpleLayoutGenerator.strategy_for(kind)
		var items := CompoundDetector.detect(ParamClassifier.classify(params, strategy))
		var layout := SimpleLayout.new()
		layout.pages = SimpleLayoutGenerator.build_pages(items, strategy, 6, 4)
		_check_layout(layout, params, "%s strategy" % kind)


func _test_generate_500_params_under_100ms() -> void:
	var params: Array = []
	for i in range(500):
		params.append(_float(i, ["Cutoff", "Osc Wave", "Attack", "Decay", "Sustain", "Release", "Volume", "Param"][i % 8] + " %d" % (i / 8)))
	var device := _device("x.big", "Big Synth", Device.DeviceCategory.Instrument)
	SimpleLayoutGenerator.generate(device, params)  # warm up script caches
	var start := Time.get_ticks_usec()
	var layout := SimpleLayoutGenerator.generate(device, params)
	var ms := (Time.get_ticks_usec() - start) / 1000.0
	print("500-param layout: %.1f ms, %d pages" % [ms, layout.pages.size()])
	_assert(ms < 100.0, "500 params generate in under 100 ms (%.1f ms)" % ms)
	_check_layout(layout, params, "500-param synth")


func _test_dragonfly_hall_fixture() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(DRAGONFLY_FIXTURE))
	_assert(data is Dictionary, "fixture loads")
	if not data is Dictionary:
		return
	var features: Array[String] = []
	features.assign(data.device.features)
	var device := _device(data.device.id, data.device.name, Device.DeviceCategory.Effect, features)
	var params: Array = []
	for p in data.params:
		var param := _float(int(p.id), p.name, "", p.min, p.max)
		param.default_value = p.default
		param.module = p.module
		params.append(param)
	var layout := SimpleLayoutGenerator.generate(device, params)
	_check_layout(layout, params, "Dragonfly Hall")
	_assert(layout.kind == DeviceKind.REVERB, "Dragonfly Hall is a reverb")

	var by_name := {}
	for p in params:
		by_name[p.name] = _find(layout, p.id)
	var dry: Dictionary = by_name["Dry Level"]
	_assert(dry.group == by_name["Early Level"].group and dry.group == by_name["Late Level"].group,
		"Dry, Early and Late levels share a group (%s)" % dry.group_title)
	_assert(dry.page == by_name["Early Level"].page, "dry and wet levels on the same page")
	for n in ["Dry Level", "Decay", "Size"]:
		_assert(by_name[n].page == 0, "%s on the Main page" % n)
	_assert(layout.pages[0].title == "Main", "first page titled Main")
