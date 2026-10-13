# test_mixer_multi_route.gd
# Headless tests: the mixer output menu applies a route to every selected channel.
# Run: godot --headless --path Godot -s tests/test_mixer_multi_route.gd -- --test
extends TestBase

var _mixer: Object
var _project: Object
var _a: Object
var _b: Object
var _c: Object
var _bus: Object
var _bus2: Object


func suite_name() -> String:
	return "Mixer multi-channel output routing"


func run_tests() -> void:
	await _setup()
	_test_applies_to_selection()
	_test_menu_channel_not_selected()
	_test_skips_invalid()
	_test_hardware_and_undo()


func _setup() -> void:
	_project = (load("res://data/Project.gd") as GDScript).new()
	_mixer = (load("res://mixer/Mixer.tscn") as PackedScene).instantiate()
	_mixer.size = Vector2(1400, 600)
	root.add_child(_mixer)
	_mixer._on_project_opened(_project)
	_a = _project.create_instrument_track("A").channel
	_b = _project.create_instrument_track("B").channel
	_c = _project.create_instrument_track("C").channel
	_bus = _project.create_bus_channel("Bus")
	_bus2 = _project.create_bus_channel("Bus2")
	await process_frame
	await process_frame


## What MixerChannel._on_output_menu_selected does for the strip of `menu_ch`.
func _pick(menu_ch: Object, item_id: int) -> void:
	var edit: GDScript = load("res://mixer/ChannelMultiEdit.gd")
	edit.apply_route(menu_ch, item_id, _mixer.get_multi_edit_peers(menu_ch), _project)


func _reset() -> void:
	for ch in [_a, _b, _c, _bus, _bus2]:
		ch.set_route(1)


func _test_applies_to_selection() -> void:
	_reset()
	_mixer.select_channel(_a)
	_mixer.select_channel(_b, true)
	_pick(_a, _bus.id)
	_assert(_a.output_channel_id == _bus.id and _b.output_channel_id == _bus.id, "route applies to all selected")
	_assert(_c.output_channel_id == 1, "unselected channel unchanged")


func _test_menu_channel_not_selected() -> void:
	_reset()
	_mixer.select_channel(_a)
	_mixer.select_channel(_b, true)
	_pick(_c, _bus.id)
	_assert(_c.output_channel_id == _bus.id, "menu channel routed")
	_assert(_a.output_channel_id == 1 and _b.output_channel_id == 1, "selection untouched when menu channel is outside it")


func _test_skips_invalid() -> void:
	_reset()
	_c.parent_channel_id = 9999  # nested strip: its route belongs to the grouping
	_bus2.set_route(_bus.id)  # Bus2 -> Bus
	_mixer.select_channel(_a)
	_mixer.select_channel(_bus, true)
	_mixer.select_channel(_bus2, true)
	_mixer.select_channel(_c, true)
	_pick(_a, _bus.id)
	_assert(_c.output_channel_id == 1, "route-locked channel skipped")
	_c.parent_channel_id = -1
	_assert(_a.output_channel_id == _bus.id, "primary routed")
	_assert(_bus.output_channel_id == 1, "channel routing to itself skipped")
	_assert(_bus2.output_channel_id == _bus.id, "bus2 unchanged (already there)")
	# The validity check is the single-channel one (is_valid_route_target); it has no cycle case
	# beyond subtree membership, so only that is covered here.
	var menu: GDScript = load("res://mixer/ChannelOutputMenu.gd")
	_assert(not menu.is_valid_route_target(_bus, _bus, _project), "self is not a valid target")
	# Master is never rerouted.
	var master = _project.get_channel_by_id(1)
	_mixer.select_channel(_a)
	_mixer.select_channel(master, true)
	var master_dev: int = master.device_output_id
	_pick(_a, _bus.id)
	_assert(master.device_output_id == master_dev and master.output_channel_id != _bus.id, "master skipped")


func _test_hardware_and_undo() -> void:
	_reset()
	_mixer.select_channel(_a)
	_mixer.select_channel(_b, true)
	var hw := 1000  # AudioConfig.HARDWARE_OUTPUT_BASE (not named: autoload compile order)
	var recorded: Array = []
	var history: GDScript = load("res://history/HistoryUtil.gd")
	history.test_recorder = func(cmd): recorded.append(cmd)
	_pick(_a, hw)
	history.test_recorder = Callable()
	_assert(recorded.size() == 1, "one undo step for the whole gesture")
	_assert(_a.output_channel_id == hw and _b.output_channel_id == hw, "hardware route applies to all")
