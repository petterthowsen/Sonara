# test_pitch_shifter_view.gd
# The Pitch Shifter's parameters (dumped from the engine by `dump_pitch_shifter_view_fixture`) must generate a
# readable Simple View layout: one Main page, one group per module, nothing dropped.
# Run: godot --headless --path Godot -s tests/test_pitch_shifter_view.gd -- --test
extends TestBase


const FIXTURE := "res://tests/fixtures/simple_view/pitch_shifter_params.json"
const PARAM_COUNT := 8


func suite_name() -> String:
	return "Pitch Shifter Simple View tests"


func run_tests() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	_assert(data is Dictionary, "pitch shifter fixture loads")
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
	_assert(DeviceKind.infer(device) == DeviceKind.GENERIC, "the pitch shifter takes the generic strategy")

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

	_assert(layout.pages.size() == 1, "the pitch shifter fits one page (%d)" % layout.pages.size())

	var titles: Array = layout.pages[0].groups.map(func(g): return g.title)
	titles.sort()
	_assert(titles == ["Feedback", "Grain", "Output", "Pitch"],
		"one group per module: %s" % [titles])

	var at := func(name: String) -> Dictionary: return _find(layout, by_name[name])
	for n in ["Pitch", "Fine"]:
		_assert(at.call(n).group_title == "Pitch", "%s sits in the Pitch group (%s)" % [n, at.call(n).group_title])
	for n in ["Grain", "Sync", "Jitter"]:
		_assert(at.call(n).group_title == "Grain", "%s sits in the Grain group (%s)" % [n, at.call(n).group_title])
	_assert(at.call("Mix").group_title == "Output", "Mix sits in the Output group")

	# Pitch steps in whole semitones; Fine is continuous.
	var pitch_param: DeviceParameter = null
	for p in params:
		if p.id == by_name["Pitch"]:
			pitch_param = p
	_assert(pitch_param != null and pitch_param.is_whole_number(), "Pitch is a whole-number parameter")
	_assert(pitch_param.format_value(7.0).begins_with("7"), "Pitch reads in semitones (%s)" % pitch_param.format_value(7.0))
	_assert(at.call("Sync").control.kind == SimpleControlKinds.DROPDOWN,
		"25-choice Sync is a dropdown (%s)" % [at.call("Sync").control.kind])

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
