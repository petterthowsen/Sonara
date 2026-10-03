# test_simple_layout_generator.gd
# Headless tests for Simple View layout generation (REQ-002 – REQ-008).
# Run: godot --headless --path Godot -s tests/test_simple_layout_generator.gd -- --test
extends TestBase


const DRAGONFLY_FIXTURE := "res://tests/fixtures/simple_view/dragonfly_hall_params.json"
const APRICOT_FIXTURE := "res://tests/fixtures/simple_view/apricot_params.json"
const EXTRABOLD_FIXTURE := "res://tests/fixtures/simple_view/extrabold_params.json"
const LIBRESTRINGS_FIXTURE := "res://tests/fixtures/simple_view/librestrings_params.json"


func suite_name() -> String:
	return "Simple View generator tests"


func run_tests() -> void:
	_test_kind_inference()
	_test_drum_kind_inference()
	_test_builtin_drum_layout()
	_test_drum_tune_note_name()
	_test_control_kinds()
	_test_integer_enum_spinbox()
	_test_hidden_readonly_excluded()
	_test_compounds()
	_test_grouping_module_and_role()
	_test_builtin_eq_layout()
	_test_compounds_stay_in_their_module()
	_test_name_sections()
	_test_main_page_importance()
	_test_pages_grow_sideways()
	_test_group_blocks_and_columns()
	_test_family_is_aligned()
	_test_group_prefix_is_stripped()
	_test_primary_controls_first()
	_test_numbered_modules_form_a_family()
	_test_families_share_a_page()
	_test_no_overlap_in_bounds()
	_test_generate_500_params_under_100ms()
	_test_dragonfly_hall_fixture()
	_test_builtin_reverb()
	_test_apricot_fixture()
	_test_extrabold_fixture()
	_test_librestrings_fixture()
	_test_compressor_faders()


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
	return CompoundDetector.detect(ParamClassifier.classify(params, strategy), strategy.compound_kinds())


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


func _test_drum_kind_inference() -> void:
	_assert(DeviceKind.infer(_device("sonara.builtin.kick", "Kick", Device.DeviceCategory.Instrument)) == DeviceKind.DRUM,
		"a device named Kick infers drum")
	_assert(DeviceKind.infer(_device("x.drum", "Thing", Device.DeviceCategory.Effect, ["drum"])) == DeviceKind.DRUM,
		"the drum feature infers drum")
	_assert(DeviceKind.infer(_device("clap:/x/Reverb", "Big Reverb")) == DeviceKind.REVERB,
		"an id token 'clap' does not make a reverb a drum")
	for n in ["Snare", "Closed Hat", "HiHat", "Clap"]:
		_assert(DeviceKind.infer(_device("x.thing", n, Device.DeviceCategory.Instrument)) == DeviceKind.DRUM,
			"%s infers drum" % n)


## The built-in EQ names every band's parameters alike ("Freq", "Gain", "Q") and tells them apart
## by module. Each band gets its own group of labelled knobs; Band 1 used to be the only one with an
## EQ compound, because the bands' identical stems collided.
func _test_builtin_eq_layout() -> void:
	var params: Array = []
	for b in range(1, 9):
		var base := (b - 1) * 10
		for p in [_bool(base, "Enabled"), _enum(base + 1, "Type", 7), _float(base + 2, "Freq", "Hz", 20.0, 20000.0),
				_float(base + 3, "Gain", "dB", -24.0, 24.0), _float(base + 4, "Q", "", 0.1, 30.0)]:
			p.module = "Band %d" % b
			params.append(p)
	var layout := SimpleLayoutGenerator.generate(_device("sonara.builtin.eq", "EQ"), params)
	for b in range(1, 9):
		var base := (b - 1) * 10
		for offset in [2, 3, 4]:
			var found := _find(layout, base + offset)
			_assert(found.control.kind == SimpleControlKinds.KNOB and found.control.params.size() == 1,
				"band %d param %d is its own knob (%s)" % [b, offset, found.control.kind])
			_assert(found.group_title == "Band %d" % b, "band %d param %d sits in its band (%s)" % [b, offset, found.group_title])


## Same-named parts in different modules never combine: "Attack"/"Decay" in Amp and "Sustain"/
## "Release" in Filter are two envelopes, not one across both.
func _test_compounds_stay_in_their_module() -> void:
	var params: Array = []
	for p in [_float(0, "Freq", "Hz", 20.0, 20000.0), _float(1, "Gain", "dB", -24.0, 24.0), _float(2, "Q", "", 0.1, 30.0)]:
		p.module = "Low"
		params.append(p)
	for p in [_float(3, "Freq", "Hz", 20.0, 20000.0), _float(4, "Gain", "dB", -24.0, 24.0), _float(5, "Q", "", 0.1, 30.0)]:
		p.module = "High"
		params.append(p)
	var items := _items(params)
	var eq_params: Array = []
	for item in items:
		if item.kind == SimpleControlKinds.EQ_BAND:
			eq_params.append(item.params)
	_assert(eq_params == [[0, 1, 2], [3, 4, 5]], "one EQ compound per module %s" % [eq_params])

	var split: Array = []
	for p in [_float(10, "Attack", "s", 0.0, 5.0), _float(11, "Decay", "s", 0.0, 5.0)]:
		p.module = "Amp"
		split.append(p)
	for p in [_float(12, "Sustain"), _float(13, "Release", "s", 0.0, 5.0)]:
		p.module = "Filter"
		split.append(p)
	var envs: Array = []
	for item in _items(split):
		if item.kind == SimpleControlKinds.ENVELOPE:
			envs.append(item.params)
	_assert(envs == [[10, 11], [12, 13]], "envelope parts stay in their module %s" % [envs])


## The Phase 1 Kick parameter table: modules drive grouping, so the layout shows the device's own
## sections (Body, Punch, Click, Noise, Mode, Global) with Tune and Decay as the large knobs.
func _test_builtin_drum_layout() -> void:
	var params: Array = []
	var add := func(p: DeviceParameter, module: String) -> void:
		p.module = module
		params.append(p)
	# Tune and Decay come first: they are the large knobs and sort first within Body.
	add.call(_float(0, "Tune", "Hz", 20.0, 200.0), "Body")
	add.call(_float(2, "Decay", "ms", 30.0, 3000.0), "Body")
	add.call(_bool(1, "Keytrack"), "Body")
	add.call(_float(3, "Curve", "", -1.0, 1.0), "Body")
	add.call(_float(4, "Amp Attack", "ms", 0.0, 10.0), "Body")
	add.call(_float(5, "Start Phase", "°", 0.0, 90.0), "Body")
	add.call(_float(6, "Level"), "Body")
	add.call(_float(7, "Drive", "dB", 0.0, 24.0), "Body")
	add.call(_float(10, "Sweep", "st", 0.0, 48.0), "Punch")
	add.call(_float(11, "Sweep Time", "ms", 5.0, 200.0), "Punch")
	add.call(_float(20, "Level"), "Click")
	add.call(_float(21, "Tone", "Hz", 1000.0, 8000.0), "Click")
	add.call(_enum(22, "Type", 2), "Click")
	add.call(_float(30, "Level"), "Noise")
	add.call(_float(31, "Decay", "ms", 10.0, 1000.0), "Noise")
	add.call(_float(32, "Color", "Hz", 200.0, 12000.0), "Noise")
	add.call(_bool(40, "Gate"), "Mode")
	add.call(_float(41, "Gate Release", "ms", 10.0, 2000.0), "Mode")
	add.call(_float(42, "Glide", "ms", 0.0, 500.0), "Mode")
	add.call(_float(90, "Velocity"), "Global")
	add.call(_float(91, "Output", "dB", -60.0, 12.0), "Global")
	add.call(_float(92, "Humanize"), "Global")

	var device := _device("sonara.builtin.kick", "Kick", Device.DeviceCategory.Instrument)
	_assert(DeviceKind.infer(device) == DeviceKind.DRUM, "Kick → drum")
	var layout := SimpleLayoutGenerator.generate(device, params)
	_assert(layout.kind == DeviceKind.DRUM, "generated with the Drum strategy")
	_check_layout(layout, params, "Kick")

	var tune := _find(layout, 0)
	var decay := _find(layout, 2)
	_assert(tune.group_title == "Body", "Tune is in the Body module (%s)" % tune.group_title)
	_assert(decay.group_title == "Body", "Decay is in the Body module (%s)" % decay.group_title)
	var body: Array = []
	for page in layout.pages:
		for c in page.controls:
			if c.get("group", "") == tune.group:
				body.append(c)
	body.sort_custom(func(a, b):
		return (a.rect[1] < b.rect[1]) if (a.rect[1] != b.rect[1]) else (a.rect[0] < b.rect[0]))
	_assert(6 in body[0].params and 7 in body[1].params, "Level and Drive (primary) sort first in Body")
	_assert(0 in body[2].params, "Tune follows them in Body")
	_assert(2 in body[3].params, "Decay follows Tune in Body")


## The drum Tune knob shows a note name (E0 at 41.2 Hz), and Decay is left alone.
func _test_drum_tune_note_name() -> void:
	var strategy := DrumStrategy.new()
	var tune := _float(0, "Tune", "Hz", 20.0, 200.0)
	var keytrack := _bool(1, "Keytrack")
	var decay := _float(2, "Decay", "ms", 30.0, 3000.0)
	var params := [tune, keytrack, decay]
	var knob := {"kind": SimpleControlKinds.KNOB, "params": [0], "rect": [0, 0, 1, 1]}
	var marked: Dictionary = strategy.decorate_control(knob, params)
	_assert(marked.get("unit", "") == "note", "the Tune knob is marked as a note (%s)" % [marked.get("unit", "")])
	_assert(not knob.has("unit"), "the original layout control is left alone")
	_assert(SimpleUnits.format(tune, tune.value_to_normalized(41.2), "note") == "E0",
		"41.2 Hz reads as E0 (%s)" % [SimpleUnits.format(tune, tune.value_to_normalized(41.2), "note")])
	var decay_knob := {"kind": SimpleControlKinds.KNOB, "params": [2], "rect": [1, 0, 1, 1]}
	_assert(not strategy.decorate_control(decay_knob, params).has("unit"), "Decay keeps its ms unit")
	var keytrack_control := {"kind": SimpleControlKinds.TOGGLE, "params": [1], "rect": [2, 0, 1, 1]}
	_assert(not strategy.decorate_control(keytrack_control, params).has("unit"), "a bool Keytrack control is untouched")


func _test_control_kinds() -> void:
	var params := [_bool(0, "On"), _enum(1, "Mode", 4), _enum(2, "Scale", 12), _float(3, "Amount"), _enum(4, "Two", 2)]
	var kinds := []
	for e in ParamClassifier.classify(params, GenericStrategy.new()):
		kinds.append(e.kind)
	_assert(kinds == ["toggle", "segmented", "dropdown", "knob", "toggle"], "bool/4-enum/12-enum/float/2-enum kinds: %s" % [kinds])


func _labels_enum(id: int, name: String, labels: Array[String]) -> DeviceParameter:
	var p := DeviceParameter.new(id, name)
	p.param_type = "enum"
	p.enum_values = labels
	return p


func _test_integer_enum_spinbox() -> void:
	var octave := _labels_enum(0, "Osc A Octave", ["-2", "-1", "0", "+1", "+2"])
	_assert(ParamClassifier.is_integer_enum(octave), "-2…+2 labels are an integer enum")
	_assert(ParamClassifier.control_kind(octave) == SimpleControlKinds.SPINBOX, "an integer enum gets a spin box")
	_assert(not ParamClassifier.is_integer_enum(_labels_enum(1, "Gap", ["1", "2", "4"])),
		"non-consecutive numbers are not an integer enum")
	_assert(not ParamClassifier.is_integer_enum(_labels_enum(2, "Mixed", ["1", "2", "Three"])),
		"a non-numeric label is not an integer enum")
	_assert(ParamClassifier.control_kind(_labels_enum(3, "Bit", ["0", "1"])) == SimpleControlKinds.TOGGLE,
		"a two-value integer enum stays a toggle")


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

	_assert(not adsr[0].has("stages"), "full ADSR leaves stages at the default")

	var ads := _items([_float(0, "Attack", "s"), _float(1, "Decay", "s"), _float(2, "Sustain")])
	_assert(ads.size() == 1 and ads[0].kind == "envelope" and ads[0].params == [0, 1, 2] and ads[0].stages == "ads",
		"ADS (no release) → envelope with stages 'ads'")

	var asr := _items([_float(0, "Env Attack", "s"), _float(1, "Env Sustain"), _float(2, "Env Release", "s")])
	_assert(asr.size() == 1 and asr[0].stages == "asr" and asr[0].params == [0, 1, 2], "ASR → envelope with stages 'asr'")

	var ad := _items([_float(0, "Attack", "s"), _float(1, "Decay", "s")])
	_assert(ad.size() == 1 and ad[0].stages == "ad", "AD → envelope with stages 'ad'")

	var comp := _items([_float(0, "Attack", "ms", 0, 100), _float(1, "Release", "ms", 0, 1000)])
	var kinds := comp.map(func(i): return i.kind)
	_assert(kinds == ["knob", "knob"], "attack + release alone (compressor) → 2 knobs: %s" % [kinds])

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


## Section title and label NameSections gives each item, keyed by the item's first param id.
func _sections(params: Array, kind := DeviceKind.GENERIC) -> Dictionary:
	var items := _items(params, kind)
	var found := NameSections.find(items)
	var out := {}
	for item in items:
		if found.has(item.index):
			out[item.params[0]] = [found[item.index].title, found[item.index].label]
	return out


func _test_name_sections() -> void:
	var osc := _sections([_float(0, "Oscillator 1 Volume"), _float(1, "Oscillator 2 Volume"),
		_float(2, "Oscillator 1 Fine Pitch"), _float(3, "Oscillator 2 Fine Pitch")])
	_assert(osc.get(0) == ["Oscillator 1", "Volume"] and osc.get(2) == ["Oscillator 1", "Fine Pitch"]
		and osc.get(3) == ["Oscillator 2", "Fine Pitch"], "numbered family: one section per instance, short labels %s" % [osc])

	var glued := _sections([_float(0, "Osc1 Level"), _float(1, "Osc1 Tune"), _float(2, "Osc2 Level"), _float(3, "Osc2 Tune")])
	_assert(glued.get(1) == ["Osc1", "Tune"] and glued.get(2) == ["Osc2", "Level"], "glued numbers split too %s" % [glued])

	var steps: Array = []
	for i in range(16):
		steps.append(_float(i, "Step %d Pitch" % (i + 1)))
	var seq := _sections(steps)
	_assert(seq.get(2) == ["Step", "Pitch 3"], "many thin instances: one section, numbered labels %s" % [seq.get(2)])

	# ZeroEQ: 5 global params and 11 bands of 6 → a section per band, not one "Band" section.
	var zero: Array = [_bool(0, "Bypass"), _float(1, "Output Gain"), _float(2, "Analyzer")]
	for b in range(1, 12):
		zero.append(_bool(zero.size(), "Band %d On" % b))
		for n in ["Type", "Freq", "Gain", "Q", "Slope"]:
			zero.append(_float(zero.size(), "Band %d %s" % [b, n]))
	var zero_layout := SimpleLayoutGenerator.generate(null, zero)
	var band_titles: Array = []
	for page in zero_layout.pages:
		for group in page.groups:
			band_titles.append(group.title)
	_assert(band_titles.has("Band 1") and band_titles.has("Band 11") and not band_titles.has("Band"),
		"11-band EQ: one group per band %s" % [band_titles])

	var words := _sections([_float(0, "Filter Cutoff"), _float(1, "Filter Key Track"), _float(2, "Matrix Amount 1"),
		_float(3, "Matrix Amount 2"), _float(4, "Pitch Bend Up"), _float(5, "Pitch Bend Down")])
	_assert(words.get(1) == ["Filter", "Key Track"], "shared first word forms a section %s" % [words.get(1)])
	_assert(words.get(3) == ["Matrix", "Amount 2"], "a numbered list keeps a word in its label %s" % [words.get(3)])
	_assert(words.get(5) == ["Pitch Bend", "Down"], "the longest shared prefix is the section %s" % [words.get(5)])

	var knobs: Array = []
	for i in range(10):
		knobs.append(_float(i, "Knob %d" % i))
	_assert(_sections(knobs).is_empty(), "'Knob N' alone isn't a section")
	_assert(_sections([_float(0, "Dry Level"), _float(1, "Wet Level"), _float(2, "Low Cut"), _float(3, "Size")]).is_empty(),
		"names that mostly don't share sections leave grouping to the strategy")

	var amp := [_float(0, "Amp Attack Time"), _float(1, "Amp Decay Time"), _float(2, "Amp Sustain Level"),
		_float(3, "Amp Release Time"), _float(4, "Amp Gain")]
	var amp_items := _items(amp, DeviceKind.SYNTH)
	_assert(amp_items.size() == 2 and amp_items[0].kind == SimpleControlKinds.ENVELOPE,
		"Attack Time … Sustain Level form an envelope")
	_assert(_sections(amp, DeviceKind.SYNTH).get(0) == ["Amp", "Envelope"], "a compound in its section is labelled by kind")
	var lfo := _items([_float(0, "LFO 1 Attack"), _float(1, "LFO 1 Decay"), _float(2, "LFO 1 Sustain")])
	_assert(lfo[0].label == "LFO 1", "compound labels keep the name's spelling (%s)" % lfo[0].label)


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
	_assert(layout.pages.size() == 1, "a 37-param reverb fits on one page that grows sideways (%d pages)" % layout.pages.size())
	_assert(layout.pages[0].title == "Main", "first page is Main")
	for n in ["Mix", "Decay", "Size"]:
		var p := params.filter(func(x): return x.name == n)[0] as DeviceParameter
		_assert(_find(layout, p.id).get("page", -1) == 0, "reverb %s on page 1" % n)
	var mix_x := int(_find(layout, params.filter(func(x): return x.name == "Mix")[0].id).control.rect[0])
	var extra_x := int(_find(layout, 0).control.rect[0])
	_assert(mix_x < extra_x, "the important Mix group sits left of the unimportant extras (%d vs %d)" % [mix_x, extra_x])

	var synth_params: Array = []
	for i in range(100):
		synth_params.append(_float(i, ["Cutoff", "Osc Wave", "LFO Rate", "Volume", "Thing"][i % 5] + " %d" % i))
	var synth := SimpleLayoutGenerator.generate(_device("x.syn", "Syn", Device.DeviceCategory.Instrument), synth_params)
	_check_layout(synth, synth_params, "100-param synth")
	_assert(synth.pages[0].title == "Main", "synth starts on Main")
	_assert(_find(synth, 0).get("page", -1) == 0, "cutoff on Main")
	var lfo_page: int = _find(synth, 2).get("page", -1)
	_assert(lfo_page > 0 and synth.pages[lfo_page].title == "Modulation", "LFO rate on the Modulation page")
	_assert(_find(synth, 1).get("page", -1) == 0, "oscillator on Main")
	_check_page_widths(synth, "100-param synth")


## Pages are at most `MAX_PAGE_COLUMNS` wide and have distinct titles.
func _check_page_widths(layout: SimpleLayout, what: String) -> void:
	var titles := {}
	for page in layout.pages:
		var right := 0
		for c in page.controls:
			right = maxi(right, int(c.rect[0]) + int(c.rect[2]))
		_assert(right <= SimpleLayout.MAX_PAGE_COLUMNS, "%s: page '%s' is %d columns wide" % [what, page.title, right])
		_assert(not titles.has(page.title), "%s: page title '%s' used once" % [what, page.title])
		titles[page.title] = true


## Small groups share a page side by side; a group too big for one page continues on the next,
## with a distinct title.
func _test_pages_grow_sideways() -> void:
	var small := [_float(0, "Mix"), _float(1, "Output"), _float(2, "Freq"), _float(3, "Reso"),
		_float(4, "Time"), _float(5, "Rate"), _float(6, "Thing")]
	var layout := SimpleLayoutGenerator.generate(_device("x.small", "Small Groups"), small)
	_check_layout(layout, small, "small groups")
	_assert(layout.pages.size() == 1, "five small groups share one page (%d pages)" % layout.pages.size())
	_assert(layout.pages[0].groups.size() == 5, "every group keeps its own box (%d)" % layout.pages[0].groups.size())

	var many: Array = []
	for i in range(150):
		many.append(_float(i, "Knob %d" % i))
	var big := SimpleLayoutGenerator.generate(_device("x.big", "Big Generic"), many)
	_check_layout(big, many, "150-knob group")
	_assert(big.pages.size() == 2, "150 knobs need two 24×4 pages (%d)" % big.pages.size())
	_assert(big.pages[0].title == "Main" and big.pages[1].title == "Controls",
		"the continuation is titled after its group: %s" % [big.pages.map(func(p): return p.title)])
	_check_page_widths(big, "150-knob group")

	var huge: Array = []
	for i in range(300):
		huge.append(_float(i, "Knob %d" % i))
	var three := SimpleLayoutGenerator.generate(_device("x.huge", "Huge Generic"), huge)
	_check_page_widths(three, "300-knob group")
	_assert(three.pages.size() == 4 and three.pages[2].title == "Controls 2",
		"repeated continuation titles are numbered: %s" % [three.pages.map(func(p): return p.title)])


func _knob_sizes(n: int) -> Array[Vector2i]:
	var sizes: Array[Vector2i] = []
	for i in range(n):
		sizes.append(Vector2i(1, 1))
	return sizes


## Group blocks: a few knobs take one row, more take two rows, big groups the full height; blocks
## stack in columns in order.
func _test_group_blocks_and_columns() -> void:
	_assert(GridPacker.group_block(_knob_sizes(4), 4, 24).size == Vector2i(4, 1), "4 knobs → one row")
	_assert(GridPacker.group_block(_knob_sizes(8), 4, 24).size == Vector2i(4, 2), "8 knobs → 4×2")
	_assert(GridPacker.group_block(_knob_sizes(32), 4, 24).size == Vector2i(8, 4), "32 knobs → 8×4")
	var env: Array[Vector2i] = [Vector2i(3, 2), Vector2i(1, 1)]
	_assert(GridPacker.group_block(env, 4, 24).size == Vector2i(4, 2), "envelope + knob → 4×2")
	_assert(GridPacker.group_block(_knob_sizes(6), 1, 24).size == Vector2i(6, 1), "a one-row page gets one-row blocks")

	var groups: Array = []
	for g in [["A", 8], ["B", 8], ["C", 2], ["D", 2], ["E", 2]]:
		var items: Array = []
		for i in range(g[1]):
			items.append({"kind": SimpleControlKinds.KNOB, "params": [groups.size() * 100 + i]})
		groups.append({"id": g[0], "title": g[0], "page": "", "items": items})
	var page: Dictionary = GridPacker.pack_pages(groups, 4, 24)[0]
	var rects := {}
	for g in page.groups:
		rects[g.id] = g.rect
	_assert(rects.A == [0, 0, 4, 2] and rects.B == [0, 2, 4, 2], "A and B stack in the first column %s" % [rects])
	_assert(rects.C == [4, 0, 2, 1] and rects.D == [4, 1, 2, 1] and rects.E == [4, 2, 2, 1],
		"small groups stack in the next column, in order %s" % [rects])


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
		var rows := rng.randi_range(1, 6)
		var layout := SimpleLayoutGenerator.generate(device, params, rows)
		_assert(layout.kind == kind, "random set %d: generated as %s" % [iteration, kind])
		var problems := layout.validate()
		if not problems.is_empty() or iteration % 10 == 0:
			_check_layout(layout, params, "random set %d (%d params, %d rows)" % [iteration, params.size(), rows])
		else:
			var ids := layout.param_ids()
			var visible := params.filter(func(p): return ParamClassifier.is_visible(p)).size()
			_assert(ids.size() == visible, "random set %d: %d params placed" % [iteration, visible])
		for page in layout.pages:
			for g in page.groups:
				var r := GridPacker.rect_from_array(g.rect)
				_assert(r.position.x >= 0 and r.position.y >= 0 and r.end.x <= SimpleLayout.MAX_PAGE_COLUMNS and r.end.y <= rows,
					"random set %d: group rect in bounds" % iteration)
	# Each strategy on the same random-ish names.
	for kind in kinds:
		var params: Array = []
		for id in range(60):
			params.append(_float(id, "%s %d" % [names[id % names.size()], id / names.size()], "s", 0, 5))
		var strategy := SimpleLayoutGenerator.strategy_for(kind)
		var items := CompoundDetector.detect(ParamClassifier.classify(params, strategy), strategy.compound_kinds())
		var layout := SimpleLayout.new()
		layout.pages = SimpleLayoutGenerator.build_pages(items, strategy, 4)
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


func _test_builtin_reverb() -> void:
	# The Phase 7 parameter table (Sonara Reverb). Modules drive grouping.
	var params: Array = []
	var by_name := {}
	var add := func(p: DeviceParameter) -> void:
		params.append(p)
		by_name[p.name] = p.id
	var float_param := func(id: int, name: String, unit: String, module: String, min_v: float, max_v: float, log_v := false) -> void:
		var p := _float(id, name, unit, min_v, max_v)
		p.module = module
		p.is_logarithmic = log_v
		add.call(p)
	var enum_param := func(id: int, name: String, module: String, count: int) -> void:
		var p := _enum(id, name, count)
		p.module = module
		add.call(p)
	var bool_param := func(id: int, name: String, module: String) -> void:
		var p := _bool(id, name)
		p.module = module
		add.call(p)

	enum_param.call(0, "Algorithm", "Space", 3)
	float_param.call(1, "Size", "%", "Space", 0.0, 100.0)
	float_param.call(2, "Decay", "s", "Space", 0.1, 30.0, true)
	float_param.call(3, "Pre-Delay", "ms", "Space", 0.0, 500.0)
	float_param.call(4, "Diffusion", "%", "Space", 0.0, 100.0)
	float_param.call(5, "Early", "%", "Space", 0.0, 100.0)
	float_param.call(10, "Low Mult", "×", "Decay EQ", 0.25, 2.0, true)
	float_param.call(11, "Low Freq", "Hz", "Decay EQ", 50.0, 1000.0, true)
	float_param.call(12, "High Mult", "×", "Decay EQ", 0.1, 1.0, true)
	float_param.call(13, "High Freq", "Hz", "Decay EQ", 1000.0, 20000.0, true)
	float_param.call(20, "Rate", "Hz", "Modulation", 0.05, 5.0, true)
	float_param.call(21, "Depth", "%", "Modulation", 0.0, 100.0)
	float_param.call(30, "Low Cut", "Hz", "Tone", 20.0, 1000.0, true)
	float_param.call(31, "High Cut", "Hz", "Tone", 1000.0, 20000.0, true)
	float_param.call(40, "Ducking", "%", "Dynamics", 0.0, 100.0)
	bool_param.call(41, "Freeze", "Dynamics")
	float_param.call(50, "Width", "%", "Output", 0.0, 200.0)
	float_param.call(51, "Mix", "%", "Output", 0.0, 100.0)

	var device := _device("sonara.builtin.reverb", "Reverb", Device.DeviceCategory.Effect)
	_assert(DeviceKind.infer(device) == DeviceKind.REVERB, "sonara.builtin.reverb → reverb")
	var layout := SimpleLayoutGenerator.generate(device, params)
	_check_layout(layout, params, "builtin reverb")
	_assert(layout.kind == DeviceKind.REVERB, "generated with the Reverb strategy")
	for n in ["Mix", "Decay", "Size"]:
		_assert(_find(layout, by_name[n]).page == 0, "reverb %s on the Main page" % n)
	_assert(_find(layout, by_name["Algorithm"]).control.kind == SimpleControlKinds.SEGMENTED,
		"Algorithm is a segmented control (%s)" % _find(layout, by_name["Algorithm"]).control.kind)
	_assert(_find(layout, by_name["Freeze"]).control.kind == SimpleControlKinds.TOGGLE,
		"Freeze is a toggle")


func _test_apricot_fixture() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(APRICOT_FIXTURE))
	_assert(data is Dictionary, "Apricot fixture loads")
	if not data is Dictionary:
		return
	var features: Array[String] = []
	features.assign(data.device.features)
	var device := _device(data.device.id, data.device.name, Device.DeviceCategory.Instrument, features)
	var params: Array = []
	var by_id := {}
	for p in data.params:
		var param := _float(int(p.id), p.name, "", p.min, p.max)
		param.default_value = p.default
		param.is_read_only = p.read_only
		params.append(param)
		by_id[p.name] = param.id
	var layout := SimpleLayoutGenerator.generate(device, params)
	_check_layout(layout, params, "Apricot")
	_check_page_widths(layout, "Apricot")
	var titles: Array = layout.pages.map(func(p): return p.title)
	_assert(titles == ["Main", "Modulation", "Effects", "Arp"], "Apricot pages %s" % [titles])

	var at := func(name: String) -> Dictionary: return _find(layout, by_id[name])
	var osc1: Dictionary = at.call("Oscillator 1 Volume")
	_assert(osc1.group_title == "Oscillator 1" and osc1.control.get("label") == "Volume" and osc1.page == 0,
		"Oscillator 1 Volume → 'Volume' in Oscillator 1 on Main (%s)" % [osc1])
	_assert(at.call("Oscillator 2 Unison Voices").group_title == "Oscillator 2", "oscillators get a group each")
	_assert(at.call("Filter Cutoff").control.get("label") == "Cutoff", "Filter Cutoff → 'Cutoff'")
	var amp: Dictionary = at.call("Amp Attack Time")
	_assert(amp.control.kind == SimpleControlKinds.ENVELOPE and amp.group_title == "Amp", "amp ADSR is an envelope in Amp")
	var env2: Dictionary = at.call("Mod Env 2 Decay Time")
	_assert(env2.group_title == "Mod Env 2" and layout.pages[env2.page].title == "Modulation", "Mod Env 2 on Modulation")
	_assert(at.call("LFO 1 Rate").group_title == "LFO 1", "LFO 1 group")
	_assert(at.call("Matrix Amount 3").control.get("label") == "Amount 3", "matrix amounts keep their number")
	var delay: Dictionary = at.call("Delay Feedback")
	_assert(delay.group_title == "Delay" and layout.pages[delay.page].title == "Effects", "Delay group on Effects")
	_assert(at.call("EQ Low Gain").group_title == "EQ", "EQ group")

	var osc1_rect: Array = layout.pages[0].groups.filter(func(g): return g.title == "Oscillator 1")[0].rect
	var osc2_rect: Array = layout.pages[0].groups.filter(func(g): return g.title == "Oscillator 2")[0].rect
	_assert(osc1_rect[2] == 4 and osc1_rect[3] == 2 and osc2_rect[0] == osc1_rect[0] and osc2_rect[1] == osc1_rect[1] + 2,
		"Oscillator 2 sits right under Oscillator 1, both 4×2 (%s, %s)" % [osc1_rect, osc2_rect])

	# Oscillator 1, 2, 3 sit together, in order.
	var main: Dictionary = layout.pages[0]
	var order: Array = main.groups.map(func(g): return g.title)
	var first := order.find("Oscillator 1")
	_assert(first >= 0 and order.slice(first, first + 3) == ["Oscillator 1", "Oscillator 2", "Oscillator 3"],
		"oscillator sections stay together %s" % [order])


## Inside a group, primary controls (Volume, Amount) come first and fine-tuning ones (Fine, Phase)
## last, each tier in parameter order.
func _test_primary_controls_first() -> void:
	var names := ["Fine", "Shape Bend", "Phase", "Volume", "Pan", "Amount"]
	var items: Array[Dictionary] = []
	for i in names.size():
		items.append({"index": i, "module": "Osc", "importance": 0.5, "label": "", "name": names[i],
			"kind": SimpleControlKinds.KNOB, "params": [i]})
	items.append({"index": 6, "module": "Osc", "importance": 0.5, "label": "", "name": "Extra",
		"kind": SimpleControlKinds.KNOB, "params": [6]})
	var groups := SimpleLayoutGenerator.group_items(items, GenericStrategy.new())
	var order: Array = groups[0].items.map(func(it): return it.name)
	_assert(order == ["Volume", "Amount", "Shape Bend", "Pan", "Extra", "Fine", "Phase"],
		"primary first, fine-tuning last %s" % [order])


## Labels drop the group's own name ("Filter Drive" in Filter → "Drive") unless that would make two
## labels in the group the same.
func _test_group_prefix_is_stripped() -> void:
	var names := ["Filter Cutoff", "Filter Drive", "Filter", "Filter Env Amount", "Drive"]
	var items: Array[Dictionary] = []
	for i in names.size():
		items.append({"index": i, "module": "Filter", "importance": 0.5, "label": "", "name": names[i],
			"kind": SimpleControlKinds.KNOB, "params": [i]})
	var groups := SimpleLayoutGenerator.group_items(items, GenericStrategy.new())
	var shown := {}  # what the control displays: the label, else the parameter name
	for item in groups[0].items:
		shown[item.name] = item.label if not item.label.is_empty() else item.name
	_assert(shown["Filter Cutoff"] == "Cutoff", "prefix dropped %s" % [shown])
	_assert(shown["Filter"] == "Filter", "a label that is just the group name stays")
	_assert(shown["Filter Drive"] == "Filter Drive" and shown["Drive"] == "Drive",
		"ambiguous 'Drive' keeps its full name %s" % [shown])
	_assert(shown["Filter Env Amount"] == "Env Amount", "multi-word remainder kept")


## Numbered module names ("Osc 1", "Osc 2") form a family, so they end up side by side or stacked.
func _test_numbered_modules_form_a_family() -> void:
	var items: Array[Dictionary] = []
	var modules := ["Filter", "Amp Env", "Osc 1", "Osc 2", "Noise"]
	for i in modules.size() * 2:
		items.append({"index": i, "module": modules[i / 2], "importance": 0.5, "label": "P%d" % i,
			"kind": SimpleControlKinds.KNOB, "params": [i]})
	var groups := SimpleLayoutGenerator.group_items(items, GenericStrategy.new())
	var titles: Array = groups.map(func(g): return g.title)
	var osc1 := titles.find("Osc 1")
	_assert(titles.find("Osc 2") == osc1 + 1, "Osc 1 and Osc 2 are adjacent %s" % [titles])
	_assert(groups[osc1].family == groups[osc1 + 1].family, "Osc 1 and Osc 2 share a family")
	var rects := {}
	for g in GridPacker.pack_pages(groups, 4, 16)[0].groups:
		rects[g.title] = g.rect
	_assert(rects["Osc 1"][0] == rects["Osc 2"][0] or rects["Osc 1"][1] == rects["Osc 2"][1],
		"Osc 1 and Osc 2 aligned %s %s" % [rects["Osc 1"], rects["Osc 2"]])


## A family (Oscillator 1, 2) is aligned in one column and singles backfill the column before it,
## so related groups never sit diagonally: Amp Env + Noise | Osc 1 over Osc 2.
func _test_family_is_aligned() -> void:
	var knobs := func(n: int) -> Array:
		var items := []
		for i in n:
			items.append({"kind": SimpleControlKinds.KNOB, "params": [i]})
		return items
	var groups := [{"id": "amp", "title": "Amp Env", "page": "Main", "items": knobs.call(4)}]
	for i in 2:
		groups.append({"id": "osc%d" % (i + 1), "title": "Osc %d" % (i + 1), "page": "Main",
			"family": "osc", "items": knobs.call(4)})
	groups.append({"id": "noise", "title": "Noise", "page": "Main", "items": knobs.call(4)})
	var rects := {}
	for g in GridPacker.pack_pages(groups, 4, 12)[0].groups:
		rects[g.id] = g.rect
	_assert(rects.osc1[0] == rects.osc2[0] and rects.osc2[1] > rects.osc1[1],
		"Osc 2 sits under Osc 1 %s %s" % [rects.osc1, rects.osc2])
	_assert(rects.amp[0] == rects.noise[0] and rects.amp[0] != rects.osc1[0],
		"Amp Env and Noise share a column %s %s" % [rects.amp, rects.noise])


## A family of groups that doesn't fit beside what's on a page starts a new page, titled after the
## family, instead of leaving its last group on a page of its own; a family too big for any page
## still fills the page it starts on.
func _test_families_share_a_page() -> void:
	var knobs := func(n: int) -> Array:
		var items := []
		for i in n:
			items.append({"kind": SimpleControlKinds.KNOB, "params": [i]})
		return items
	var groups := [{"id": "big", "title": "Big", "page": "Main", "items": knobs.call(20)}]
	for i in 3:
		groups.append({"id": "slot_%d" % (i + 1), "title": "Slot %d" % (i + 1), "page": "Main",
			"family": "slot", "family_title": "Slot", "items": knobs.call(6)})
	# Big is 5×4 and each slot 3×2 on a 10-column page: two slots fit beside Big, the third doesn't.
	var pages := GridPacker.pack_pages(groups, 4, 10)
	var titles: Array = pages.map(func(p): return p.title)
	_assert(titles == ["Main", "Slot"], "slot family moves to its own page %s" % [titles])
	_assert(pages[1].groups.size() == 3, "all three slots on one page")

	var many := []
	for i in 12:
		many.append({"id": "part_%d" % i, "title": "Part %d" % i, "page": "Main", "family": "part",
			"items": knobs.call(8)})
	pages = GridPacker.pack_pages([groups[1]] + many, 4, 10)
	_assert(pages[0].groups.size() > 1, "a family too big for a page starts beside what's there (%d groups on Main)" % pages[0].groups.size())


## Generate a layout from a probe-dumped fixture whose params carry `stepped` (see
## extrabold_params.json). Returns `{layout, params, by_name}`, or {} when it doesn't load.
func _generate_from_probe_fixture(path: String) -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_assert(data is Dictionary, "%s loads" % path.get_file())
	if not data is Dictionary:
		return {}
	var features: Array[String] = []
	features.assign(data.device.features)
	var device := _device(data.device.id, data.device.name, Device.DeviceCategory.Instrument, features)
	var params: Array = []
	var by_name := {}
	for p in data.params:
		var param: DeviceParameter
		if not p.stepped:
			param = _float(int(p.id), p.name, "", p.min, p.max)
		elif p.min == 0.0 and p.max == 1.0:
			param = _float(int(p.id), p.name)
			param.param_type = "bool"
		else:
			param = _enum(int(p.id), p.name, int(p.max - p.min) + 1)
		param.default_value = p.default
		params.append(param)
		by_name[p.name] = param.id
	var layout := SimpleLayoutGenerator.generate(device, params)
	_check_layout(layout, params, data.device.name)
	_check_page_widths(layout, data.device.name)
	return {"layout": layout, "params": params, "by_name": by_name}


func _test_extrabold_fixture() -> void:
	var generated := _generate_from_probe_fixture(EXTRABOLD_FIXTURE)
	if generated.is_empty():
		return
	var layout: SimpleLayout = generated.layout
	var by_name: Dictionary = generated.by_name
	var titles: Array = layout.pages.map(func(p): return p.title)
	_assert(titles == ["Main", "Modulation", "Effects"], "ExtraBold pages %s" % [titles])

	var at := func(name: String) -> Dictionary: return _find(layout, by_name[name])
	var slot1: Dictionary = at.call("Effect Slot 1 Amount")
	_assert(layout.pages[slot1.page].title == "Effects" and slot1.group_title == "Effect Slot 1",
		"Effect Slot 1 in its own group on Effects (%s)" % [slot1])
	for n in ["Effect Slot 2 Type", "Effect Slot 3 Type", "Effect Slot 3 Multiply by Mod Wheel", "Bypass FX"]:
		_assert(at.call(n).page == slot1.page, "%s on the Effects page with Effect Slot 1" % n)
	for n in ["Oscillator 1 Volume", "Oscillator 3 FM Amount", "Filter Cutoff", "Master Volume", "Legato"]:
		_assert(at.call(n).page == 0, "%s on Main" % n)


## A flat instrument: Vibrato alone would make a one-knob Modulation page, so it stays on Main and
## joins Controls beside Dynamics and Pressure.
func _test_librestrings_fixture() -> void:
	var generated := _generate_from_probe_fixture(LIBRESTRINGS_FIXTURE)
	if generated.is_empty():
		return
	var layout: SimpleLayout = generated.layout
	var titles: Array = layout.pages.map(func(p): return p.title)
	_assert(titles == ["Main"], "LibreStrings has only a Main page %s" % [titles])
	var at := func(name: String) -> Dictionary: return _find(layout, generated.by_name[name])
	var vibrato: Dictionary = at.call("Vibrato")
	_assert(vibrato.group == at.call("Dynamics").group and vibrato.group == at.call("Pressure").group,
		"Vibrato shares a group with Dynamics and Pressure (%s)" % vibrato.group_title)
	var group_ids: Array = layout.pages[0].groups.map(func(g): return g.id)
	_assert(not "modulation" in group_ids, "no one-knob Modulation group %s" % [group_ids])


## Compressor Threshold, Ratio and Makeup are faders (opt-in through `fader_roles`), three rows
## tall; the group holding them takes the page height. A generic device keeps its knobs.
func _test_compressor_faders() -> void:
	var params := [_float(0, "Threshold", "dB", -60, 0), _float(1, "Ratio"), _float(2, "Knee", "dB", 0, 24),
		_float(3, "Makeup", "dB", -12, 24)]
	var layout := SimpleLayoutGenerator.generate(
		_device("x.comp", "Comp", Device.DeviceCategory.Effect, ["audio-effect", "compressor"]), params)
	var by_param := {}
	for page in layout.pages:
		for control in page.controls:
			by_param[control.params[0]] = control
	_assert(by_param[0].kind == "fader" and by_param[1].kind == "fader" and by_param[3].kind == "fader",
		"threshold, ratio and makeup are faders")
	_assert(by_param[2].kind == "knob", "knee stays a knob")
	_assert(by_param[0].rect[3] == 3, "a fader keeps its three rows (%s)" % [by_param[0].rect])
	var generic := SimpleLayoutGenerator.generate(_device("x.fx", "Fx"), [_float(0, "Output Gain", "dB", -12, 12)])
	_assert(generic.pages[0].controls[0].kind == "knob", "a generic device keeps its knobs")
