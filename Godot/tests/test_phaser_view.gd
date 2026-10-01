# test_phaser_view.gd
# The Phaser's parameters (dumped from the engine by `dump_phaser_view_fixture`) must generate a
# readable Simple View layout: one Main page, one group per module, nothing dropped.
# Run: godot --headless --path Godot -s tests/test_phaser_view.gd -- --test
extends TestBase


const FIXTURE := "res://tests/fixtures/simple_view/phaser_params.json"
const PARAM_COUNT := 15


func suite_name() -> String:
	return "Phaser Simple View tests"


func run_tests() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	_assert(data is Dictionary, "phaser fixture loads")
	if not data is Dictionary:
		return

	var device := Device.new(data.device.id, data.device.name, Device.DeviceCategory.Effect)
	var params: Array = []
	var by_name := {}
	for p in data.params:
		var param := DeviceParameter.new(int(p.id), p.name, p.get("unit", ""))
		param.min_value = p.min
		param.max_value = p.max
		param.default_value = p.default
		param.is_logarithmic = p.get("logarithmic", false)
		param.module = p.get("module", "")
		if p.get("type") == "enum":
			param.param_type = "enum"
			var values: Array[String] = []
			values.assign(p.enum_values)
			param.enum_values = values
		params.append(param)
		by_name[p.name] = param.id

	_assert(params.size() == PARAM_COUNT, "fixture has all %d parameters (%d)" % [PARAM_COUNT, params.size()])
	_assert(DeviceKind.infer(device) == DeviceKind.GENERIC, "the phaser takes the generic strategy")

	var layout := SimpleLayoutGenerator.generate(device, params)
	var problems := layout.validate()
	_assert(problems.is_empty(), "layout validates %s" % [problems])

	var placed := layout.param_ids()
	placed.sort()
	var expected: Array[int] = []
	for p in params:
		expected.append(p.id)
	expected.sort()
	_assert(placed == expected, "every parameter is placed once (%s)" % [placed])

	_assert(layout.pages.size() == 1, "the phaser fits one page (%d)" % layout.pages.size())
	_assert(layout.pages[0].title == "Main", "the page is Main (%s)" % layout.pages[0].title)

	var titles: Array = layout.pages[0].groups.map(func(g): return g.title)
	titles.sort()
	_assert(titles == ["Envelope", "LFO", "Output", "Phaser", "Tone"],
		"one group per module: %s" % [titles])

	# The core controls and the LFO are the point of the device; they must be reachable without
	# hunting, and Mix must not be buried.
	var at := func(name: String) -> Dictionary: return _find(layout, by_name[name])
	for n in ["Stages", "Sweep", "Spread", "Feedback"]:
		_assert(at.call(n).group_title == "Phaser", "%s sits in the Phaser group (%s)" % [n, at.call(n).group_title])
	_assert(at.call("Mix").group_title == "Output", "Mix sits in the Output group")
	_assert(at.call("Rate").group_title == "LFO", "Rate sits in the LFO group")
	_assert(at.call("Depth").group_title == "LFO", "Depth sits in the LFO group")
	_assert(at.call("Amount").group_title == "Envelope", "Amount sits in the Envelope group")
	_assert(at.call("High Cut").group_title == "Tone", "High Cut sits in the Tone group")

	# Each module group holds exactly its own parameters, so nothing reads as "LFO LFO Rate".
	_assert(at.call("Rate").control.params == [by_name["Rate"]],
		"Rate's control holds just Rate (%s)" % [at.call("Rate").control.params])
	_assert(at.call("Stereo Phase").control.kind == SimpleControlKinds.KNOB,
		"Stereo Phase is a knob (%s)" % [at.call("Stereo Phase").control.kind])
	_assert(at.call("Shape").control.kind == SimpleControlKinds.TOGGLE,
		"two-choice Shape is a toggle (%s)" % [at.call("Shape").control.kind])
	_assert(at.call("Sync").control.kind == SimpleControlKinds.DROPDOWN,
		"25-choice Sync is a dropdown (%s)" % [at.call("Sync").control.kind])

	# No group runs off the page.
	var right := 0
	for c in layout.pages[0].controls:
		right = maxi(right, int(c.rect[0]) + int(c.rect[2]))
	_assert(right <= SimpleLayout.MAX_PAGE_COLUMNS, "the page is %d columns wide" % right)


## Control holding `param_id`, with its group id under "group" and title under "group_title".
func _find(layout: SimpleLayout, param_id: int) -> Dictionary:
	for page in layout.pages:
		for c in page.controls:
			if param_id in c.params:
				var title := ""
				for g in page.groups:
					if g.id == c.get("group", ""):
						title = g.title
				return {"control": c, "group": c.get("group", ""), "group_title": title}
	return {}
