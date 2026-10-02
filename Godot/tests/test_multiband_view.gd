# test_multiband_view.gd
# Multiband FX panel (spec 016 phase G2): only active bands are offered as slots, the view shows
# one row per active band and follows band toggles, the crossover strip clamps a dragged edge
# between its active neighbours and writes the `Low Edge`, and disabling the open band closes it.
# Run: godot --headless --path Godot -s tests/test_multiband_view.gd -- --test
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _instance_script: GDScript
var _param: GDScript
var Multiband: GDScript
var _strip_script: GDScript


func suite_name() -> String:
	return "Multiband FX view"


func run_tests() -> void:
	Multiband = load("res://data/Multiband.gd")
	_strip_script = load("res://devices/builtin/MultibandStrip.gd")
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_param = load("res://data/DeviceParameter.gd")
	_register_multiband()
	_test_slot_keys_only_active()
	await _test_view()
	_test_strip_clamps_edges()


func _register_multiband() -> void:
	var registry: Object = root.get_node("AssetService").device_registry
	for id in ["sonara.builtin.chain", Multiband.DEVICE_ID]:
		if registry._devices.has(id):
			continue
		var device: Object = _device_script.new(id, id, _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
		device.is_container = true
		registry._devices[id] = device
	var device: Object = registry._devices[Multiband.DEVICE_ID]
	if device.parameters.size() > 0:
		return
	var edges := {2: 60.0, 3: 200.0, 4: 700.0, 5: 2500.0, 6: 8000.0}
	var mix = _param.new(Multiband.ID_MIX, "Mix", "%")
	mix.max_value = 100.0
	mix.default_value = 100.0
	device.add_parameter(mix)
	var out = _param.new(Multiband.ID_OUTPUT, "Output", "dB")
	out.min_value = -24.0
	out.max_value = 24.0
	device.add_parameter(out)
	for p in range(1, 7):
		var active = _param.new(Multiband.param_id(p, 0), "Band %d Active" % p)
		active.param_type = "bool"
		active.default_value = 1.0 if p in [1, 3, 5] else 0.0
		device.add_parameter(active)
		if p >= 2:
			var edge = _param.new(Multiband.param_id(p, 1), "Band %d Low Edge" % p, "Hz")
			edge.min_value = 20.0
			edge.max_value = 20000.0
			edge.is_logarithmic = true
			edge.default_value = edges[p]
			device.add_parameter(edge)
		var gain = _param.new(Multiband.param_id(p, 2), "Band %d Gain" % p, "dB")
		gain.min_value = -24.0
		gain.max_value = 24.0
		device.add_parameter(gain)
		for off in [3, 4]:
			var flag = _param.new(Multiband.param_id(p, off), "Band %d Flag" % p)
			flag.param_type = "bool"
			device.add_parameter(flag)


func _multiband() -> Object:
	var ch: Object = _project_script.new().create_instrument_track("Inst").channel
	var mb: Object = _instance_script.new(root.get_node("AssetService").device_registry._devices[Multiband.DEVICE_ID], ch.id, -1)
	ch.add_device(mb)
	return mb


func _test_slot_keys_only_active() -> void:
	var mb: Object = _multiband()
	_assert(mb.slot_keys().size() == 3, "only the three active bands are slots")
	mb.set_parameter_normalized(Multiband.param_id(4, 0), 1.0)
	_assert(mb.slot_keys().size() == 4, "enabling a band offers its slot")
	var inactive_key: String = mb.children[1].id
	mb.set_slot_open(inactive_key, true)
	_assert(not mb.is_slot_open(inactive_key), "an inactive band can't be opened")
	var key: String = mb.children[3].id
	mb.set_slot_open(key, true)
	_assert(mb.is_slot_open(key), "an active band opens")
	mb.set_parameter_normalized(Multiband.param_id(4, 0), 0.0)
	_assert(not mb.is_slot_open(key), "disabling the open band closes its slot")
	_assert(mb.slot_color(mb.children[0].id) != mb.slot_color(mb.children[2].id), "bands get distinct colors")


func _test_view() -> void:
	var mb: Object = _multiband()
	var view: Object = load("res://devices/builtin/MultibandDefaultView.tscn").instantiate()
	root.add_child(view)
	view.bind_to_device(mb)
	await root.get_tree().process_frame
	_assert(view._rows.size() == 3, "one row per active band")
	_assert(view._toggles[0].button_pressed and not view._toggles[1].button_pressed and view._toggles[2].button_pressed, "toggles show the active set")
	view._apply_toggle(4, true)
	await root.get_tree().process_frame
	_assert(view._rows.size() == 4, "enabling a band adds its row")
	_assert(view._toggles[3].button_pressed, "its toggle turns on")
	view._apply_toggle(4, false)
	_assert(view._rows.size() == 3, "disabling removes the row")
	view._apply_toggle(1, false)
	view._apply_toggle(3, false)
	_assert(Multiband.active_positions(mb).size() == 2, "two bands remain, the third disable is refused")
	_assert(view._toggles[Multiband.active_positions(mb)[0] - 1].disabled, "the last two toggles are locked on")
	view.queue_free()


func _test_strip_clamps_edges() -> void:
	var mb: Object = _multiband()
	mb.set_parameter_normalized(Multiband.param_id(4, 0), 1.0)  # active {1,3,4,5}
	var strip: Object = _strip_script.new()
	root.add_child(strip)
	strip.size = Vector2(600, 72)
	strip.bind(mb)
	var limits: Vector2 = strip.edge_limits(4)
	_assert(is_equal_approx(limits.x, Multiband.edge_hz(mb, 3) * Multiband.MIN_RATIO), "lower limit is the neighbour edge times the ratio")
	_assert(is_equal_approx(limits.y, Multiband.edge_hz(mb, 5) / Multiband.MIN_RATIO), "upper limit is the next edge over the ratio")
	var low: Vector2 = strip.edge_limits(3)
	_assert(is_equal_approx(low.x, Multiband.FREQ_MIN), "the first crossover may go down to 20 Hz")
	# Drag band 4's handle far past band 5's.
	var x_start: float = strip._x_of(Multiband.edge_hz(mb, 4))
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(x_start, 20)
	strip._gui_input(press)
	var move := InputEventMouseMotion.new()
	move.position = Vector2(590, 20)
	strip._gui_input(move)
	_assert(Multiband.edge_hz(mb, 4) <= limits.y * 1.001, "the dragged edge stops short of its upper neighbour")
	_assert(Multiband.edge_hz(mb, 4) < Multiband.edge_hz(mb, 5), "crossovers keep their order")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	strip._gui_input(release)
	strip.queue_free()
