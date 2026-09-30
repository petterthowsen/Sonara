# scratch_chorus_layout.gd — throwaway: prints the generated Simple View layout for the chorus.
extends TestBase


func suite_name() -> String:
	return "scratch chorus layout"


static func _p(id: int, name: String, unit: String, module: String, type := "float", lo := 0.0, hi := 1.0, logv := false, skew := 1.0, enum_values: Array[String] = []) -> DeviceParameter:
	var p := DeviceParameter.new(id, name, unit)
	p.module = module
	p.param_type = type
	p.min_value = lo
	p.max_value = hi
	p.is_logarithmic = logv
	p.skew = skew
	p.enum_values = enum_values
	return p


func run_tests() -> void:
	var device := Device.new("sonara.builtin.chorus", "Chorus", Device.DeviceCategory.Effect)
	var modes: Array[String] = ["Classic", "Dimension", "Ensemble"]
	var syncs: Array[String] = ["Off", "1/4", "1/8."]
	device.add_parameter(_p(0, "Chorus Mode", "", "Chorus", "enum", 0.0, 1.0, false, 1.0, modes))
	device.add_parameter(_p(1, "Chorus Rate", "Hz", "Chorus", "float", 0.02, 10.0, true))
	device.add_parameter(_p(2, "Chorus Sync", "", "Chorus", "enum", 0.0, 1.0, false, 1.0, syncs))
	device.add_parameter(_p(3, "Chorus Depth", "%", "Chorus", "float", 0.0, 100.0, false, 2.0))
	device.add_parameter(_p(4, "Chorus Delay", "ms", "Chorus", "float", 0.5, 40.0, true))
	device.add_parameter(_p(5, "Chorus Feedback", "%", "Chorus", "float", 0.0, 90.0))
	device.add_parameter(_p(10, "Tone", "Hz", "Tone", "float", 1000.0, 20000.0, true))
	device.add_parameter(_p(11, "Low Cut", "Hz", "Tone", "float", 20.0, 1000.0, true))
	device.add_parameter(_p(20, "Width", "%", "Output", "float", 0.0, 200.0))
	device.add_parameter(_p(21, "Mix", "%", "Output", "float", 0.0, 100.0))

	var kind := DeviceKind.infer(device)
	print("KIND: ", kind)
	var layout := SimpleLayoutGenerator.generate(device, device.parameters, 4)
	for i in range(layout.pages.size()):
		var page: Dictionary = layout.pages[i]
		print("PAGE ", i, " ", page.get("title", ""))
		for group in page.groups:
			print("  GROUP ", group.get("title", ""))
		for c in page.controls:
			print("    ctrl kind=", c.get("kind", ""), " params=", c.get("params", []), " label=", c.get("label", ""), " group=", c.get("group", ""))
	_assert(layout.pages.size() >= 1, "layout generated")
