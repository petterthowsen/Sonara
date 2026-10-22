# test_midi_send_targets.gd
# Headless tests for the MIDI Send model and view (spec 049, REQ-007, REQ-008, REQ-016, REQ-017,
# REQ-004): children mode re-resolves when the sender's nesting changes or a channel is removed,
# list mode keeps only valid channels, the target list is re-sent to the engine, the mode and
# list round-trip through the project JSON (a preset leaves the targets out), the engine's
# `blocked` status marks a row, and a MIDI Send is refused inside a container or slot. No live OSC
# socket is needed: the AudioEngineOSC autoload queues sends in `_pending_sends`.
#
# Project and DeviceInstance reference autoloads by bare name, so they are load()ed in run_tests().
# Run: godot --headless --path Godot -s tests/test_midi_send_targets.gd -- --test
extends TestBase

const SEND_ID := "sonara.builtin.midi_send"
const CHAIN_ID := "sonara.builtin.chain"
const LAYER_ID := "sonara.builtin.layer"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _preset_script: GDScript
var _drop_util: GDScript
var _factory: GDScript
var _osc: Node


func suite_name() -> String:
	return "MIDI Send targets"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_preset_script = load("res://data/DevicePreset.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_factory = load("res://devices/DeviceViewFactory.gd")
	_osc = root.get_node_or_null("AudioEngineOSC")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	_device(SEND_ID, _device_script.DeviceCategory.NoteEffect)
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	_device(LAYER_ID, _device_script.DeviceCategory.Instrument, true)
	_test_children_mode_follows_nesting()
	_test_child_toggles()
	_test_channel_removal()
	_test_list_filtering()
	_test_targets_are_sent()
	_test_toggle_targets()
	_test_blocked_status()
	_test_json_round_trip()
	_test_preset_leaves_out_targets()
	_test_drop_rules()
	await _test_view()


# --- helpers ---------------------------------------------------------------

func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


## Project with a Choir group (channel `group`) holding a MIDI Send, children `b` and `c` nested
## under it, a loose instrument `d`. Returns the pieces.
func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var group: Object = project.create_group_track("Choir").channel
	var b: Object = project.create_instrument_track("B").channel
	var c: Object = project.create_instrument_track("C").channel
	var d: Object = project.create_instrument_track("D").channel
	project.nest_channel(b, group)
	project.nest_channel(c, group, b)
	var send: Object = _device_instance_script.new(_device(SEND_ID, _device_script.DeviceCategory.NoteEffect), group.id, -1)
	group.add_device(send)
	_osc._pending_sends.clear()
	return {"project": project, "group": group, "b": b, "c": c, "d": d, "send": send}


## The int args of the last queued `midi_send/targets` send for `send`, or null if none.
func _last_targets(send: Object) -> Variant:
	var addr: String = send.osc_addr("midi_send/targets")
	var found: Variant = null
	for entry in _osc._pending_sends:
		if _entry_address(entry) == addr:
			found = _entry_args(entry)
	return found


func _entry_address(entry: Variant) -> String:
	if entry is Dictionary:
		return str(entry.get("address", entry.get("addr", "")))
	if entry is Array and entry.size() > 0:
		return str(entry[0])
	return ""


func _entry_args(entry: Variant) -> Array:
	if entry is Dictionary:
		return Array(entry.get("args", []))
	if entry is Array and entry.size() > 1:
		return Array(entry[1])
	return []


# --- tests -----------------------------------------------------------------

func _test_children_mode_follows_nesting() -> void:
	var s := _setup()
	_assert(s.send.is_midi_send(), "the device is a MIDI Send")
	_assert(s.send.midi_send_mode == "children", "children is the default mode")
	_assert(Array(s.send.resolved_midi_send_targets()) == [s.b.id, s.c.id], "children mode resolves the direct children")
	s.project.unnest_channel(s.c)
	_assert(Array(s.send.resolved_midi_send_targets()) == [s.b.id], "un-nesting a child drops it")
	s.project.nest_channel(s.d, s.group)
	_assert(Array(s.send.resolved_midi_send_targets()) == [s.d.id, s.b.id] or Array(s.send.resolved_midi_send_targets()).has(s.d.id),
		"nesting a channel adds it")
	var sent: Variant = _last_targets(s.send)
	_assert(sent != null and sent.has(s.d.id) and sent.has(s.b.id), "a nesting change re-sends the targets: %s" % [sent])
	_osc._pending_sends.clear()


func _test_child_toggles() -> void:
	var s := _setup()
	s.send.toggle_midi_send_child(s.b.id, false)
	_assert(Array(s.send.resolved_midi_send_targets()) == [s.c.id], "a switched-off child is left out")
	_assert(_last_targets(s.send) == [s.c.id], "toggling a child re-sends the targets")
	s.project.nest_channel(s.d, s.group)
	_assert(Array(s.send.resolved_midi_send_targets()).has(s.d.id), "a child nested later sends by default")
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.project.to_json()))
	var send: Object = _project_script.from_json(data).get_channel_by_id(s.group.id).devices[0]
	_assert(Array(send.midi_send_excluded) == [s.b.id], "the switched-off children survive save and load")
	var preset: Object = _preset_script.capture_now(s.send, "Test")
	_assert(not preset.device.has("midi_send_excluded"), "a preset leaves out the excluded ids")
	s.send.toggle_midi_send_child(s.b.id, true)
	_assert(Array(s.send.resolved_midi_send_targets()).has(s.b.id), "switching a child back on sends to it")
	s.send.toggle_midi_send_child(s.c.id, false)
	s.project.remove_channel(s.c.id)
	_assert(s.send.midi_send_excluded.is_empty(), "a removed child leaves the exclusion list")
	_osc._pending_sends.clear()


func _test_channel_removal() -> void:
	var s := _setup()
	s.send.set_midi_send_mode("list")
	s.send.set_midi_send_targets(PackedInt32Array([s.b.id, s.d.id]))
	s.project.remove_channel(s.d.id)
	_assert(Array(s.send.midi_send_targets) == [s.b.id], "a removed channel leaves the list")
	s.send.set_midi_send_mode("children")
	s.project.remove_channel(s.b.id)
	_assert(Array(s.send.resolved_midi_send_targets()) == [s.c.id], "a removed child leaves children mode")
	_osc._pending_sends.clear()


func _test_list_filtering() -> void:
	var s := _setup()
	s.send.set_midi_send_mode("list")
	s.send.set_midi_send_targets(PackedInt32Array([s.group.id, 1, 1000, 999, s.d.id, s.d.id, s.b.id]))
	var resolved := Array(s.send.resolved_midi_send_targets())
	_assert(resolved == [s.d.id, s.b.id], "list mode drops the sender, master, hardware outputs, missing ids and duplicates: %s" % [resolved])
	var valid: Array = s.send.midi_send_valid_channels().map(func(ch): return ch.id)
	_assert(not valid.has(1) and not valid.has(s.group.id), "the picker offers neither master nor the sender")
	_assert(valid.has(s.b.id) and valid.has(s.c.id) and valid.has(s.d.id), "the picker offers the other user channels")
	_osc._pending_sends.clear()


func _test_targets_are_sent() -> void:
	var s := _setup()
	s.send.set_midi_send_mode("list")
	_assert(_last_targets(s.send) == [], "switching to an empty list sends zero ids (clears the targets)")
	s.send.set_midi_send_targets(PackedInt32Array([s.d.id]))
	_assert(_last_targets(s.send) == [s.d.id], "setting the list sends it")
	_osc._pending_sends.clear()
	s.send.sync_to_engine()
	_assert(_last_targets(s.send) == [s.d.id], "sync_to_engine re-sends the targets")
	_osc._pending_sends.clear()


func _test_toggle_targets() -> void:
	var s := _setup()
	s.send.set_midi_send_mode("list")
	s.send.toggle_midi_send_target(s.d.id, true)
	_assert(Array(s.send.midi_send_targets) == [s.d.id], "toggle on adds the target")
	s.send.toggle_midi_send_target(s.group.id, true)
	_assert(Array(s.send.midi_send_targets) == [s.d.id], "the sender can't be added")
	s.send.toggle_midi_send_target(s.d.id, false)
	_assert(s.send.midi_send_targets.is_empty(), "toggle off removes the target")
	_osc._pending_sends.clear()


func _test_blocked_status() -> void:
	var s := _setup()
	var changes := [0]
	s.send.midi_send_blocked_changed.connect(func() -> void: changes[0] += 1)
	s.send._on_midi_send_blocked_received([s.b.id])
	_assert(Array(s.send.midi_send_blocked) == [s.b.id] and changes[0] == 1, "a blocked status is stored and signalled")
	s.send._on_midi_send_blocked_received([s.b.id])
	_assert(changes[0] == 1, "an unchanged status doesn't signal again")
	s.send._on_midi_send_blocked_received([])
	_assert(s.send.midi_send_blocked.is_empty() and changes[0] == 2, "an empty status clears the marks")
	_osc._pending_sends.clear()


func _test_json_round_trip() -> void:
	var s := _setup()
	s.send.set_midi_send_mode("list")
	s.send.set_midi_send_targets(PackedInt32Array([s.d.id, s.b.id]))
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.project.to_json()))
	var loaded: Object = _project_script.from_json(data)
	var send: Object = loaded.get_channel_by_id(s.group.id).devices[0]
	_assert(send.midi_send_mode == "list" and Array(send.midi_send_targets) == [s.d.id, s.b.id], "mode and list survive save and load")
	s.send.set_midi_send_mode("children")
	data = JSON.parse_string(JSON.stringify(s.project.to_json()))
	loaded = _project_script.from_json(data)
	send = loaded.get_channel_by_id(s.group.id).devices[0]
	_assert(send.midi_send_mode == "children", "children mode survives save and load")
	# A device saved before this spec has neither key and loads in children mode.
	var legacy: Dictionary = s.send.to_json()
	legacy.erase("midi_send_mode")
	legacy.erase("midi_send_targets")
	var old: Object = _device_instance_script.from_json(legacy)
	_assert(old.midi_send_mode == "children" and old.midi_send_targets.is_empty(), "a missing mode reads as children")
	_osc._pending_sends.clear()


func _test_preset_leaves_out_targets() -> void:
	var s := _setup()
	s.send.set_midi_send_mode("list")
	s.send.set_midi_send_targets(PackedInt32Array([s.d.id]))
	var preset: Object = _preset_script.capture_now(s.send, "Test")
	_assert(not preset.device.has("midi_send_targets"), "a preset leaves out the target ids")
	_assert(preset.device.get("midi_send_mode") == "list", "a preset keeps the mode")
	_osc._pending_sends.clear()


func _test_drop_rules() -> void:
	var s := _setup()
	var send_device: Object = _device(SEND_ID, _device_script.DeviceCategory.NoteEffect)
	var chain_device: Object = _device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	var chain: Object = _device_instance_script.new(chain_device, s.b.id, -1)
	s.b.add_device(chain)
	_assert(_drop_util.device_fits_host(send_device, null), "MIDI Send fits the top-level chain")
	_assert(not _drop_util.device_fits_host(send_device, chain), "MIDI Send is refused inside a container")
	_assert(_drop_util.device_fits_channel(send_device, s.group), "MIDI Send fits a group channel")
	_assert(_drop_util.device_fits_channel(send_device, s.d), "MIDI Send fits an instrument channel")
	_assert(not _drop_util.device_fits_channel(send_device, s.project.get_channel_by_id(1)), "MIDI Send is refused on master")
	var copy: Object = _device_instance_script.new(send_device, s.d.id, -1)
	_assert(not _drop_util.can_drop_instance_on_host(s.d, copy, chain), "can_drop_instance_on_host refuses a container host")
	_assert(not _drop_util.can_drop_instance_on_host(s.d, copy, chain, true), "a copy is refused in a container host too")
	_assert(not _drop_util.copy_fits_host(copy, chain), "copy_fits_host refuses a container host")
	_assert(_drop_util.copy_fits_host(copy, null), "copy_fits_host accepts the top-level chain")
	_assert(_drop_util.can_drop_instance_on_host(s.d, copy, null, true), "a copy fits the top-level chain of a non-instrument channel")
	_osc._pending_sends.clear()


func _test_view() -> void:
	var s := _setup()
	var device: Object = _device(SEND_ID, _device_script.DeviceCategory.NoteEffect)
	_factory.register_builtin_views(device)
	var view: Control = _factory.create(s.send, _device_script.ViewType.Panel)
	_assert(view != null, "the factory builds a Panel view for MIDI Send")
	if view == null:
		return
	root.add_child(view)
	view.bind_to_device(s.send)
	await process_frame
	var rows: Node = view.get_node("%TargetList")
	_assert(rows.get_child_count() == 2, "children mode shows one row per child: %d" % rows.get_child_count())
	_assert(view.get_node("%AddButton").visible == false, "the add picker is hidden in children mode")
	s.c.set_name("Tenors")
	await process_frame
	var names: Array = rows.get_children().map(func(r): return r.get_node("%NameLabel").text)
	_assert(names.has("Tenors"), "a renamed target updates its row: %s" % [names])
	s.send.change_midi_send_mode("list")
	await process_frame
	_assert(view.get_node("%AddButton").visible, "list mode shows the add picker")
	_assert(rows.get_child_count() == 0 and view.get_node("%EmptyLabel").visible, "an empty list shows the empty hint")
	s.send.toggle_midi_send_target(s.d.id, true)
	s.send.toggle_midi_send_target(s.b.id, true)
	s.send._on_midi_send_blocked_received([s.b.id])
	await process_frame
	var marked := 0
	for row in rows.get_children():
		if row.get_node("%BlockedLabel").visible:
			marked += 1
			_assert(row.channel_id == s.b.id, "the blocked row is the refused target")
	_assert(marked == 1, "exactly the blocked row is marked")
	s.project.remove_channel(s.d.id)
	await process_frame
	_assert(rows.get_child_count() == 1, "a deleted target disappears")
	view.queue_free()
	await process_frame
	_osc._pending_sends.clear()
