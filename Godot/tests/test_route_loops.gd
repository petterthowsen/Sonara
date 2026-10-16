# test_route_loops.gd
# Output routes and sends can't close a feedback loop (#117): the output menu disables a target
# whose routes and sends lead back to the channel, a multi-selection skips the peers it would
# loop, and the sends panel blocks a send that would loop.
# Run: godot --headless --path Godot -s tests/test_route_loops.gd -- --test
extends TestBase

const PANEL_SCENE := "res://mixer/sends_panel/SendsPanel.tscn"

var _menu: GDScript
var _edit: GDScript
var _kind: GDScript
var _project: Object
var _a: Object
var _b: Object
var _c: Object
var _inst: Object


func suite_name() -> String:
	return "Routing loop prevention"


func run_tests() -> void:
	_menu = load("res://mixer/ChannelOutputMenu.gd")
	_edit = load("res://mixer/ChannelMultiEdit.gd")
	_kind = load("res://components/ValueEditKind.gd")
	_project = (load("res://data/Project.gd") as GDScript).new()
	_inst = _project.create_instrument_track("Inst").channel
	_a = _project.create_bus_channel("A")
	_b = _project.create_bus_channel("B")
	_c = _project.create_bus_channel("C")
	_test_direct_loop()
	_test_chain_loop()
	_test_send_closes_route_loop()
	_test_route_closes_send_loop()
	_test_diamond_allowed()
	_test_menu_disables_loop_target()
	_test_multi_route_skips_looping_peer()
	_test_multi_send_skips_looping_peer()
	await _test_sends_panel_blocks_loop()


func _reset() -> void:
	for ch in [_inst, _a, _b, _c]:
		ch.set_route(1)
		for send in ch.send_channels.duplicate():
			ch.remove_send(send.target_channel_id)


## An Array[Channel] without naming the class at compile time (autoloads aren't up yet).
func _peers(list: Array) -> Array:
	var out := Array([], TYPE_OBJECT, &"RefCounted", load("res://data/Channel.gd"))
	out.assign(list)
	return out


func _route_ok(from: Object, to: Object) -> bool:
	return _menu.is_valid_route_target(from, to, _project)


func _send_ok(from: Object, to: Object) -> bool:
	return _menu.is_valid_send_target(from, to, _project)


func _test_direct_loop() -> void:
	_reset()
	_assert(_route_ok(_b, _a), "B -> A allowed with nothing routed")
	_b.set_route(_a.id)
	_assert(not _route_ok(_a, _b), "A -> B rejected once B -> A")
	_assert(_route_ok(_a, _c), "A -> C still allowed")


func _test_chain_loop() -> void:
	_reset()
	_a.set_route(_b.id)
	_b.set_route(_c.id)
	_assert(not _route_ok(_c, _a), "C -> A rejected for A -> B -> C")
	_assert(not _route_ok(_c, _b), "C -> B rejected for A -> B -> C")
	_assert(not _send_ok(_c, _a), "a send C -> A is rejected too")


func _test_send_closes_route_loop() -> void:
	_reset()
	_a.add_send(_b.id, -12.0)
	_assert(not _route_ok(_b, _a), "B -> A rejected while A sends to B")
	_a.set_send_amount(_b.id, -60.0)
	_assert(not _route_ok(_b, _a), "a send at -inf still counts")
	_assert(_send_ok(_a, _b), "the existing send stays editable")


func _test_route_closes_send_loop() -> void:
	_reset()
	_b.set_route(_a.id)
	_assert(not _send_ok(_a, _b), "a send A -> B rejected while B -> A")
	_assert(_send_ok(_inst, _b), "an instrument can still send to B")


func _test_diamond_allowed() -> void:
	_reset()
	_a.set_route(_c.id)
	_b.set_route(_c.id)
	_assert(_send_ok(_a, _b), "A -> C, B -> C: a send A -> B makes no loop")
	_a.add_send(_b.id, -12.0)
	_assert(_route_ok(_inst, _a) and _route_ok(_inst, _b), "an instrument can route into the diamond")
	_assert(not _route_ok(_c, _a), "C -> A still rejected")


func _test_menu_disables_loop_target() -> void:
	_reset()
	_b.set_route(_a.id)
	var popup := PopupMenu.new()
	_menu.populate(popup, _a, _project)
	var index := popup.get_item_index(_b.id)
	_assert(index >= 0, "the looping target is still listed")
	_assert(index >= 0 and popup.is_item_disabled(index), "the looping target is disabled")
	_assert(index >= 0 and popup.get_item_tooltip(index).contains("feedback loop"), "its tooltip says why")
	var c_index := popup.get_item_index(_c.id)
	_assert(c_index >= 0 and not popup.is_item_disabled(c_index), "a valid target stays enabled")
	popup.free()


func _test_multi_route_skips_looping_peer() -> void:
	_reset()
	_b.set_route(_a.id)
	_edit.apply_route(_c, _b.id, _peers([_a]), _project)
	_assert(_c.output_channel_id == _b.id, "the primary is routed")
	_assert(_a.output_channel_id == 1, "the peer that would loop is skipped")


func _test_multi_send_skips_looping_peer() -> void:
	_reset()
	_b.set_route(_a.id)
	_inst.add_send(_b.id, -12.0)
	_edit.apply_send(_inst, _b.id, -60.0, -12.0, _peers([_a, _c]), _kind.Kind.TYPED, _project)
	_assert(_a.get_send(_b.id) == null, "the peer whose send would loop gets none")
	_assert(_c.get_send(_b.id) != null, "the other peer gets the send")


func _test_sends_panel_blocks_loop() -> void:
	_reset()
	_b.set_route(_a.id)
	var panel: Control = load(PANEL_SCENE).instantiate()
	root.add_child(panel)
	panel.bind_to_channel(_a, _project)
	await process_frame
	var blocked: Object = panel._find_send_control(_b.id)
	var free_knob: Object = panel._find_send_control(_c.id)
	_assert(blocked != null and blocked.knob.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the looping send knob is blocked")
	_assert(free_knob != null and free_knob.knob.mouse_filter == Control.MOUSE_FILTER_STOP, "another bus's knob is not")
	if blocked:
		blocked.knob.value = -6.0
	_assert(_a.get_send(_b.id) == null, "turning the blocked knob creates no send")

	_b.set_route(1)
	panel._refresh_blocked()
	_assert(blocked.knob.mouse_filter == Control.MOUSE_FILTER_STOP, "unblocked once the loop is gone")
	blocked.knob.value = -6.0
	_assert(_a.get_send(_b.id) != null, "then the send can be made")
	panel.queue_free()
	await process_frame
