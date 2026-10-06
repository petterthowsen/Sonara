# test_device_gui_embed.gd
# Headless tests for the DeviceInstance side of embedded plugin GUIs (spec 022, T-005): the embed
# methods send the documented `gui/*` OSC messages, and `gui/opened` / `gui/size` from the engine
# update gui_size / gui_resizable / gui_floating and emit gui_opened / gui_size_changed.
#
# Project and DeviceInstance reference autoloads (AudioEngineOSC) by bare name, so they are
# loaded with load() inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_device_gui_embed.gd -- --test
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _osc: Node


func suite_name() -> String:
	return "Device GUI embed tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_osc = root.get_node("AudioEngineOSC")
	_test_embed_messages()
	_test_builtin_sends_nothing()
	_test_gui_opened_received()
	_test_gui_size_received()
	_test_gui_embedded_received()
	_test_disconnect_stops_listening()


func _device(device_id: String, type: int) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, _device_script.DeviceCategory.Effect, type)
		registry._devices[device_id] = device
	return device


func _plugin() -> Object:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Synth").channel
	var inst: Object = _device_instance_script.new(_device("test.clap.reverb", _device_script.DeviceType.CLAP), ch.id, 0)
	ch.add_device(inst)
	inst.connect_to_engine()
	return inst


## Sends queued since `from` as [address, args] pairs (the test OSC client never binds, so all
## sends queue).
func _sends_since(from: int) -> Array:
	var out: Array = []
	for i in range(from, _osc._pending_sends.size()):
		var item: Dictionary = _osc._pending_sends[i]
		out.append([item.address, item.args])
	return out


func _test_embed_messages() -> void:
	var inst := _plugin()
	var rect := Rect2i(10, 20, 920, 345)
	var cases := [
		[func(): inst.open_gui_embedded(0x3a00007, rect), "gui/open", [0x3a00007, 10, 20, 920, 345]],
		[func(): inst.embed_gui(0x3a00007, rect, Vector2i(5, 6)), "gui/embed", [0x3a00007, 10, 20, 920, 345, 5, 6]],
		[func(): inst.embed_gui(77, rect), "gui/embed", [77, 10, 20, 920, 345, 0, 0]],
		[func(): inst.set_gui_bounds(rect, Vector2i(0, 40)), "gui/bounds", [10, 20, 920, 345, 0, 40]],
		[func(): inst.unembed_gui(), "gui/unembed", []],
		[func(): inst.set_gui_visible(false), "gui/visible", [0]],
		[func(): inst.set_gui_visible(true), "gui/visible", [1]],
		[func(): inst.request_gui_size(Vector2i(640, 480)), "gui/size", [640, 480]],
	]
	for c in cases:
		var mark: int = _osc._pending_sends.size()
		c[0].call()
		var sent := _sends_since(mark)
		var expected := [inst.osc_addr(c[1]), c[2]]
		_assert(sent.size() == 1 and sent[0] == expected,
			"%s sends %s (got %s)" % [c[1], expected, sent])
	inst.disconnect_from_engine()


func _test_builtin_sends_nothing() -> void:
	var inst: Object = _device_instance_script.new(_device("test.builtin.fx", _device_script.DeviceType.BuiltIn), 2, 0)
	var mark: int = _osc._pending_sends.size()
	inst.embed_gui(1, Rect2i(0, 0, 10, 10))
	inst.set_gui_bounds(Rect2i(0, 0, 10, 10))
	inst.set_gui_visible(true)
	inst.request_gui_size(Vector2i(10, 10))
	inst.unembed_gui()
	_assert(_sends_since(mark).is_empty(), "a device without a native GUI sends no gui/* messages")


func _test_gui_opened_received() -> void:
	var inst := _plugin()
	var got: Array = []
	inst.gui_opened.connect(func(size: Vector2i, resizable: bool, floating: bool) -> void:
		got.append([size, resizable, floating]))
	_osc._on_osc_message_received(inst.osc_addr("gui/opened"), [920, 345, 0, 0], 0)
	_assert(inst.gui_size == Vector2i(920, 345) and not inst.gui_resizable and not inst.gui_floating,
		"gui/opened stores size, resizable and floating")
	_assert(got == [[Vector2i(920, 345), false, false]], "gui/opened emits gui_opened (got %s)" % [got])
	_osc._on_osc_message_received(inst.osc_addr("gui/opened"), [800, 600, 1, 1], 0)
	_assert(inst.gui_resizable and inst.gui_floating and got.size() == 2,
		"a second open reports again, here resizable and floating")
	_osc._on_osc_message_received(inst.osc_addr("gui/opened"), [1, 2], 0)
	_assert(got.size() == 2 and inst.gui_size == Vector2i(800, 600), "a short gui/opened is ignored")
	inst.disconnect_from_engine()


func _test_gui_size_received() -> void:
	var inst := _plugin()
	var got: Array = []
	inst.gui_size_changed.connect(func(size: Vector2i) -> void: got.append(size))
	_osc._on_osc_message_received(inst.osc_addr("gui/size"), [1024, 768], 0)
	_assert(inst.gui_size == Vector2i(1024, 768) and got == [Vector2i(1024, 768)],
		"gui/size updates gui_size and emits gui_size_changed")
	_osc._on_osc_message_received(inst.osc_addr("gui/size"), [1024, 768], 0)
	_assert(got.size() == 1, "an unchanged size doesn't emit again")
	inst.disconnect_from_engine()


func _test_gui_embedded_received() -> void:
	var inst := _plugin()
	var got: Array = []
	inst.gui_embedded.connect(func(xid: int) -> void: got.append(xid))
	_osc._on_osc_message_received(inst.osc_addr("gui/embedded"), [0x7a00059], 0)
	_assert(inst.gui_parent_xid == 0x7a00059 and got == [0x7a00059], "gui/embedded records the parent window")
	_osc._on_osc_message_received(inst.osc_addr("gui/embedded"), [0], 0)
	_assert(inst.gui_parent_xid == 0 and got.size() == 2, "0 means out of every Godot window")
	_osc._on_osc_message_received(inst.osc_addr("gui/embedded"), [0x7a00006], 0)
	_osc._on_osc_message_received(inst.osc_addr("gui/closed"), [], 0)
	_assert(inst.gui_parent_xid == 0, "a closed GUI is in no window")
	inst.disconnect_from_engine()


func _test_disconnect_stops_listening() -> void:
	var inst := _plugin()
	inst.disconnect_from_engine()
	var got: Array = []
	inst.gui_opened.connect(func(_s, _r, _f) -> void: got.append(true))
	_osc._on_osc_message_received(inst.osc_addr("gui/opened"), [920, 345, 0, 0], 0)
	_assert(got.is_empty() and inst.gui_size == Vector2i.ZERO, "a disconnected device ignores gui/opened")
