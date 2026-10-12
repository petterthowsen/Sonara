# Spec 038 REQ-007: saved Transpose Scale Type values survive the longer scale catalogue.
# Run: godot --headless --path Godot -s tests/test_scale_migration.gd -- --test
extends TestBase

const TRANSPOSE := "sonara.builtin.transpose"
const LAYER := "sonara.builtin.layer"

var _device_script: GDScript
var _instance_script: GDScript
var _project_script: GDScript
var _preset_script: GDScript


func suite_name() -> String:
	return "Scale catalogue migration"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_preset_script = load("res://data/DevicePreset.gd")
	_register(TRANSPOSE, false)
	_register(LAYER, true)
	_register(load("res://data/SlotChain.gd").CHAIN_ID, true)
	_test_helper()
	_test_walker()
	_test_project()
	_test_preset()


func _register(device_id: String, container: bool) -> void:
	var registry: Object = root.get_node("AssetService").device_registry
	if registry._devices.get(device_id) != null:
		return
	var category: int = _device_script.DeviceCategory.NoteEffect
	var device: Object = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
	device.is_container = container
	registry._devices[device_id] = device


func _new_index(id: String) -> int:
	for i in MusicalScale.TYPES.size():
		if MusicalScale.TYPES[i]["id"] == id:
			return i - 1
	return -1


func _id_for_norm(norm: float) -> String:
	var index := roundi(norm * float(MusicalScale.TYPES.size() - 2))
	return MusicalScale.TYPES[index + 1]["id"]


func _node(values: Dictionary, children: Array = []) -> Dictionary:
	return {"id": "x", "device_id": TRANSPOSE, "channel_id": 1, "position": 0,
		"parameter_values": values, "children": children}


func _test_helper() -> void:
	_assert(MusicalScale.LEGACY_TYPE_IDS.size() == 12, "12 legacy ids")
	_assert(MusicalScale.migrate_v1_type_norm(0.0) == 0.0, "Major stays 0.0")
	_assert(_id_for_norm(MusicalScale.migrate_v1_type_norm(4.0 / 11.0)) == "dorian", "4/11 -> Dorian")
	_assert(_id_for_norm(MusicalScale.migrate_v1_type_norm(1.0)) == "blues", "1.0 -> Blues")
	_assert(is_equal_approx(MusicalScale.migrate_v1_type_norm(1.0), float(_new_index("blues")) / 46.0),
		"Blues re-normalized with 46 as the divisor")
	for i in 12:
		var id := _id_for_norm(MusicalScale.migrate_v1_type_norm(float(i) / 11.0))
		_assert(id == MusicalScale.LEGACY_TYPE_IDS[i], "legacy index %d keeps %s" % [i, MusicalScale.LEGACY_TYPE_IDS[i]])


func _test_walker() -> void:
	var inner := _node({"12": 4.0 / 11.0, "3": 0.25})
	var outer := _node({"12": 1.0}, [inner, {"device_id": "other", "parameter_values": {"12": 1.0}}])
	_instance_script.migrate_scale_catalogue(outer)
	_assert(_id_for_norm(outer["parameter_values"]["12"]) == "blues", "outer Transpose -> Blues")
	_assert(_id_for_norm(inner["parameter_values"]["12"]) == "dorian", "child Transpose -> Dorian")
	_assert(inner["parameter_values"]["3"] == 0.25, "other params untouched")
	_assert(outer["children"][1]["parameter_values"]["12"] == 1.0, "non-Transpose devices untouched")


func _test_project() -> void:
	var j: Dictionary = _project_script.new().to_json()
	j["format_version"] = 2
	var channel: Dictionary = j["channels"][0]
	var layer := _node({}, [_node({"12": 4.0 / 11.0})])
	layer["device_id"] = LAYER
	channel["devices"] = [_node({"12": 1.0}), layer]
	var track: Dictionary = {"id": 7, "type": "MIDI", "name": "T", "default_channel_id": channel["id"],
		"automation_lanes": [
			{"id": "a", "target": "device/0/param/12", "points": [{"id": 0, "tick": 0, "value": 1.0}]},
			{"id": "b", "target": "device/0/param/3", "points": [{"id": 0, "tick": 0, "value": 1.0}]},
		]}
	j["tracks"] = [track]
	var p: Object = _project_script.from_json(j.duplicate(true))
	_assert(p.format_version == 2, "loaded project reports its file version")
	var ch: Object = p.channels[0]
	_assert(ch.devices.size() == 2, "both devices loaded (%d)" % ch.devices.size())
	if ch.devices.size() < 2:
		return
	_assert(_id_for_norm(ch.devices[0].parameter_values[12]) == "blues", "channel Transpose loads as Blues")
	_assert(_id_for_norm(ch.devices[0]._restored_parameter_values[12]) == "blues", "restored value is migrated too")
	var nested: Object = ch.devices[1].children[0]
	while nested.device.device_id != TRANSPOSE and not nested.children.is_empty():
		nested = nested.children[0]  # the Layer wraps its slots in Chain devices
	_assert(_id_for_norm(nested.parameter_values[12]) == "dorian", "nested Transpose loads as Dorian")
	var lanes: Array = p.tracks[0].automation_lanes
	_assert(lanes.size() == 2, "two lanes loaded")
	if lanes.size() == 2:
		_assert(_id_for_norm(lanes[0].points[0].value) == "blues", "param 12 lane point remapped")
		_assert(lanes[1].points[0].value == 1.0, "other lane untouched")
	# A current-version project is not touched.
	j["format_version"] = 3
	var q: Object = _project_script.from_json(j.duplicate(true))
	_assert(q.channels[0].devices[0].parameter_values[12] == 1.0, "a version-3 project is not remapped")


func _test_preset() -> void:
	var data := {"format": _preset_script.FORMAT, "version": 1, "name": "Old", "device_id": TRANSPOSE,
		"device": _node({"12": 4.0 / 11.0}), "returns": []}
	var preset: Object = _preset_script.from_json(data)
	_assert(preset.file_version == 1, "preset keeps its file version")
	var inst: Object = preset.instantiate(1)
	_assert(inst != null, "v1 preset instantiates")
	if inst != null:
		_assert(_id_for_norm(inst.parameter_values[12]) == "dorian", "v1 preset Transpose loads as Dorian")
	var fresh: Object = _preset_script.from_json({"format": _preset_script.FORMAT, "version": 2, "name": "New", "device_id": TRANSPOSE,
		"device": _node({"12": 1.0}), "returns": []})
	var inst2: Object = fresh.instantiate(1)
	_assert(inst2 != null and inst2.parameter_values[12] == 1.0, "v2 preset values are not remapped")
	_assert(_preset_script.VERSION == 2, "presets save version 2")
