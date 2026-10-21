# Layer panel view: the scene's Mapping… button, `%Rows` box and Mix knob bind whether the device
# arrives before or after the view enters the tree; the rows match the Layer's children and
# follow children being added and removed (only `%Rows` is refilled); the Mix knob follows its
# parameter, and a Layer without one hides it.
# Run: godot --headless --path Godot -s tests/test_layer_view.gd -- --test
extends TestBase

const SCENE := "res://devices/builtin/layer/LayerDefaultView.tscn"
const LAYER_ID := "sonara.builtin.layer"
const P_MIX := 0

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript


func suite_name() -> String:
	return "Layer view"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	await _test_bind_before_tree()
	await _test_bind_after_tree()
	await _test_rows_follow_children()
	await _test_missing_mix_hides_knob()


## A Layer device definition, with or without its Mix parameter.
func _layer_device(with_mix: bool) -> Object:
	var device: Object = _device_script.new(LAYER_ID, "Layer", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	if with_mix:
		var mix := DeviceParameter.new(P_MIX, "Mix", "%")
		mix.min_value = 0.0
		mix.max_value = 100.0
		mix.default_value = 100.0
		device.add_parameter(mix)
	return device


func _slot(ch: Object, name: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get("sonara.builtin.polysynth")
	if device == null:
		device = _device_script.new("sonara.builtin.polysynth", "PolySynth", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
		registry._devices["sonara.builtin.polysynth"] = device
	var inst: Object = _device_instance_script.new(device, ch.id, 0)
	inst.name = name
	return inst


func _layer(names: Array, with_mix := true) -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Layers").channel
	var device := _layer_device(with_mix)
	root.get_node("AssetService").device_registry._devices[LAYER_ID] = device
	var layer: Object = _device_instance_script.new(device, ch.id, 0)
	ch.add_device(layer)
	var slots: Array = []
	for n in names:
		var slot := _slot(ch, n)
		ch.add_device(slot, -1, layer)
		slots.append(slot)
	return {"project": project, "channel": ch, "layer": layer, "slots": slots}


func _mount(inst: Object, bind_first: bool) -> Control:
	var view: Control = load(SCENE).instantiate()
	if bind_first:
		view.bind_to_device(inst)
	root.add_child(view)
	if not bind_first:
		view.bind_to_device(inst)
	await process_frame
	return view


func _row_names(view: Control) -> Array:
	var out: Array = []
	for row in view.rows_box.get_children():
		out.append(row.instance.get_display_name())
	return out


func _check_bound(view: Control, d: Dictionary, label: String) -> void:
	_assert(view.mapping_button != null and view.rows_box != null and view.mix_knob != null, "%s: scene nodes resolve" % label)
	_assert(view.mapping_button.text == "Mapping…" and view.mix_knob.text == "MIX", "%s: captions come from the scene" % label)
	_assert(view.get_child_count() == 3, "%s: the view keeps its scene children (got %d)" % [label, view.get_child_count()])
	_assert(_row_names(view) == ["Kick", "Snare"], "%s: one row per child, in order (got %s)" % [label, _row_names(view)])
	_assert(view.mix_knob.visible, "%s: Mix knob shown" % label)
	var layer: Object = d.layer
	_assert(is_equal_approx(view.mix_knob.knob.value, layer.get_parameter_normalized(P_MIX)), "%s: Mix knob starts at the parameter" % label)
	layer.set_parameter_normalized(P_MIX, 0.25)
	_assert(is_equal_approx(view.mix_knob.knob.value, 0.25), "%s: Mix knob follows the parameter" % label)
	view.mix_knob.knob.value = 0.75  # emits value_changed like a drag
	_assert(is_equal_approx(layer.get_parameter_normalized(P_MIX), 0.75), "%s: turning the Mix knob sets the parameter" % label)


func _test_bind_before_tree() -> void:
	var d := _layer(["Kick", "Snare"])
	var view := await _mount(d.layer, true)
	_check_bound(view, d, "bound before tree")
	view.queue_free()
	await process_frame


func _test_bind_after_tree() -> void:
	var d := _layer(["Kick", "Snare"])
	var view := await _mount(d.layer, false)
	_check_bound(view, d, "bound after tree")
	view.queue_free()
	await process_frame


func _test_rows_follow_children() -> void:
	var d := _layer(["Kick", "Snare"])
	var view := await _mount(d.layer, true)
	var mapping: Button = view.mapping_button
	var knob: Control = view.mix_knob
	d.channel.add_device(_slot(d.channel, "Hat"), -1, d.layer)
	_assert(_row_names(view) == ["Kick", "Snare", "Hat"], "adding a child adds its row (got %s)" % [_row_names(view)])
	d.channel.remove_device_instance(d.slots[0])
	_assert(_row_names(view) == ["Snare", "Hat"], "removing a child removes its row (got %s)" % [_row_names(view)])
	_assert(view.mapping_button == mapping and is_instance_valid(mapping) and view.mix_knob == knob and is_instance_valid(knob),
		"a rebuild keeps the scene's button and knob")
	_assert(view.get_child(0) == mapping and view.get_child(1) == view.rows_box and view.get_child(2) == knob,
		"Mapping…, rows, Mix stay in order")
	view.queue_free()
	await process_frame


func _test_missing_mix_hides_knob() -> void:
	var d := _layer(["Kick"], false)
	var view := await _mount(d.layer, true)
	_assert(not view.mix_knob.visible, "no Mix parameter hides the Mix knob")
	_assert(_row_names(view) == ["Kick"], "rows still built")
	view.queue_free()
	await process_frame
