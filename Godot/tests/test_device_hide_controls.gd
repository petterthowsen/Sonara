# test_device_hide_controls.gd
# Headless tests for hiding a device's controls in the device lane: closing the View of a slotted
# device (PolySynth, Delay, Reverb, M/S and L/R Split; spec 040/043) or any container hides the
# devices in its slots too, nested slots included. The hiding is derived from the parent's
# state, so the children's own View toggles and open slots are untouched and everything comes
# back as it was when the controls are shown again. Hidden panels also drop their view
# subscriptions (_on_view_hidden) and take them up again on show.
# Run: godot --headless --path Godot -s tests/test_device_hide_controls.gd -- --test
#
# Classes that reference autoloads are loaded with load() instead of named.
extends TestBase

const CHAIN_ID := "sonara.builtin.chain"
const POLY_ID := "sonara.builtin.polysynth"
const DELAY_ID := "sonara.builtin.delay"
const SAT_ID := "sonara.builtin.saturator"

const COUNTING_VIEW := """extends DeviceView
var shown := 0
var unsubscribed := 0
func _on_bind() -> void:
	pass
func _on_view_shown() -> void:
	shown += 1
func _on_view_hidden() -> void:
	unsubscribed += 1
"""

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _add_cmd: GDScript
var _view_script: GDScript
var _nodes: Array[Node] = []


func suite_name() -> String:
	return "Device hide controls"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_view_script = GDScript.new()
	_view_script.source_code = COUNTING_VIEW
	_view_script.reload()
	_device(CHAIN_ID, true)
	_device(SAT_ID)
	var poly := _device(POLY_ID, true)
	poly.slots.append({"key": "note_fx", "name": "Note FX", "kind": "note"})
	poly.slots.append({"key": "fx", "name": "FX", "kind": "audio"})
	_device(DELAY_ID)
	await _test_hiding_controls_hides_slot_children()
	await _test_children_state_is_preserved()
	await _test_views_unsubscribe_while_hidden()
	await _test_survives_save_and_load()


func _device(device_id: String, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


func _inst(device_id: String, ch: Object) -> Object:
	return _device_instance_script.new(root.get_node("AssetService").device_registry._devices[device_id], ch.id, -1)


func _settle() -> void:
	await process_frame
	await process_frame


func _lane(ch: Object) -> Control:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	var lane: Control = (load("res://devices/device_lane/DeviceLane.tscn") as PackedScene).instantiate()
	lane.size = Vector2(1600, 400)
	root.add_child(lane)
	_nodes.append(lane)
	lane.bind_to_channel(ch)
	await _settle()
	return lane


## PolySynth with a Chain in its FX slot, the Chain holding a Saturator; both slots open.
## Returns {ch, poly, chain, sat}.
func _rig() -> Dictionary:
	var ch: Object = _project_script.new().create_instrument_track("Inst").channel
	var poly := _inst(POLY_ID, ch)
	ch.add_device(poly)
	var chain := _inst(CHAIN_ID, ch)
	_add_cmd.new(ch, chain, -1, poly.children[1]).do()
	var sat := _inst(SAT_ID, ch)
	_add_cmd.new(ch, sat, -1, chain).do()
	poly.set_slot_open("fx", true)
	chain.set_slot_open(chain.CHAIN_SLOT, true)
	return {"ch": ch, "poly": poly, "chain": chain, "sat": sat}


## Close or open `panel`'s View the way the header toggle does (no view scene exists headless).
func _set_view_open(panel: Control, open: bool) -> void:
	panel.view_button.visible = true
	panel.view_button.button_pressed = open
	await _settle()


func _shown(panel: Control) -> bool:
	return panel != null and panel.is_visible_in_tree()


func _test_hiding_controls_hides_slot_children() -> void:
	var r := _rig()
	var lane := await _lane(r.ch)
	var poly_panel: Control = lane.find_device_panel(r.poly)
	_assert(_shown(lane.find_device_panel(r.chain)) and _shown(lane.find_device_panel(r.sat)),
		"slot children and nested slot children show while the controls are shown")
	_assert(not poly_panel.controls_hidden(), "controls start shown")
	await _set_view_open(poly_panel, false)
	_assert(poly_panel.controls_hidden() and _shown(poly_panel), "closing the View hides the controls, the device itself stays")
	_assert(not _shown(lane.find_device_panel(r.chain)), "the device in the FX slot is hidden")
	_assert(not _shown(lane.find_device_panel(r.sat)), "the device in the nested slot is hidden too")
	_assert(lane.devices.items()[0].slot_groups().is_empty(), "hidden slots don't take part in the lane's panel list")
	await _set_view_open(poly_panel, true)
	_assert(_shown(lane.find_device_panel(r.chain)) and _shown(lane.find_device_panel(r.sat)),
		"showing the controls brings both back")


func _test_children_state_is_preserved() -> void:
	var r := _rig()
	var lane := await _lane(r.ch)
	var poly_panel: Control = lane.find_device_panel(r.poly)
	var chain_panel: Control = lane.find_device_panel(r.chain)
	await _set_view_open(chain_panel, false)  # the child collapsed on its own
	_assert(not _shown(lane.find_device_panel(r.sat)), "a collapsed Chain hides its own slot")
	await _set_view_open(poly_panel, false)
	_assert(chain_panel.controls_hidden() and r.chain.is_slot_open(r.chain.CHAIN_SLOT) and Array(r.poly.open_slot_keys()) == ["fx"],
		"hiding the parent changes neither the child's View toggle nor any open slot")
	await _set_view_open(poly_panel, true)
	_assert(_shown(chain_panel) and chain_panel.controls_hidden() and not _shown(lane.find_device_panel(r.sat)),
		"showing the parent restores the child collapsed, its own slot still hidden")
	await _set_view_open(chain_panel, true)
	_assert(_shown(lane.find_device_panel(r.sat)), "and opening the child shows its slot again")


func _test_views_unsubscribe_while_hidden() -> void:
	var r := _rig()
	var lane := await _lane(r.ch)
	var poly_panel: Control = lane.find_device_panel(r.poly)
	var sat_panel: Control = lane.find_device_panel(r.sat)
	var view: Object = _view_script.new()
	view.bind_to_device(r.sat)
	sat_panel.view_host.add_child(view)
	sat_panel._panel_view = view
	view.show_view()
	await _settle()
	_assert(view.shown == 1 and view.unsubscribed == 0, "the nested view is subscribed while shown")
	await _set_view_open(poly_panel, false)
	_assert(view.unsubscribed == 1 and sat_panel.is_suspended(), "hiding an ancestor's controls unsubscribes the nested view")
	await _set_view_open(poly_panel, true)
	_assert(view.shown == 2 and view.unsubscribed == 1 and not sat_panel.is_suspended(), "showing them subscribes it again, once")
	sat_panel._panel_view = null
	view.queue_free()


func _test_survives_save_and_load() -> void:
	var r := _rig()
	var json: Dictionary = r.poly.to_json() if r.poly.has_method("to_json") else {}
	_assert(not json.is_empty(), "the PolySynth serializes")
	var loaded: Object = _device_instance_script.from_json(json)
	_assert(loaded != null and Array(loaded.open_slot_keys()) == ["fx"] and loaded.children[1].children.size() == 1,
		"open slots and slot children round-trip")
	var ch: Object = _project_script.new().create_instrument_track("Loaded").channel
	ch.add_device(loaded)
	var lane := await _lane(ch)
	_assert(_shown(lane.find_device_panel(loaded.children[1].children[0])), "after loading, the children show again (hiding is not saved)")
	await _set_view_open(lane.find_device_panel(loaded), false)
	_assert(not _shown(lane.find_device_panel(loaded.children[1].children[0])), "and a loaded device hides its children like a new one")
