# test_key_change_sync.gd
# Spec 034 G-002: Project owns the key change map and sends /project/scale_map on every change
# when CONNECTED (first connect, reconnect and engine restart all go through
# _on_engine_confirmed_connected), and never sends while disconnected.
#
# Headless the OSC client never becomes ready, so sends queue in AudioEngineOSC._pending_sends.
extends TestBase

var _osc: Node


func suite_name() -> String:
	return "Key change sync"


func run_tests() -> void:
	_osc = root.get_node_or_null("AudioEngineOSC")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	_test_disconnected_is_silent()
	_test_connected_sends_map()
	_test_confirmed_connected_resyncs()
	_test_setter_reconnects()


func _scale_map_sends() -> Array:
	return _osc._pending_sends.filter(func(item) -> bool: return item.address == "/project/scale_map")


func _test_disconnected_is_silent() -> void:
	var project: Object = load("res://data/Project.gd").new()
	_osc._pending_sends.clear()
	project._connection_state = project.ConnectionState.DISCONNECTED
	project.key_change_map.add_change(1920, 2, "dorian")
	_assert(_scale_map_sends().is_empty(), "nothing sent while disconnected")


func _test_connected_sends_map() -> void:
	var project: Object = load("res://data/Project.gd").new()
	_osc._pending_sends.clear()
	project._connection_state = project.ConnectionState.CONNECTED
	project.key_change_map.add_change(1920, 0, "none")
	project.key_change_map.add_change(3840, 2, "dorian")
	var sent := _scale_map_sends()
	_assert(sent.size() == 2, "each edit sends one /project/scale_map: %d" % sent.size())
	_assert(sent[0].args == [1920, 0], "first edit sends the single change")
	var expected := MusicalScale.make(2, "dorian").mask()
	_assert(sent[1].args == [1920, 0, 3840, expected], "second edit sends the whole map: %s" % [sent[1].args])
	# Ticks >= 1 and 12-bit masks over the wire.
	var ok := true
	for i in range(0, sent[1].args.size(), 2):
		ok = ok and int(sent[1].args[i]) >= 1 and int(sent[1].args[i + 1]) >= 0 and int(sent[1].args[i + 1]) <= 0x0FFF
	_assert(ok, "args are (tick >= 1, 12-bit mask) pairs")
	# A direct engine sync also replaces the whole map.
	_osc._pending_sends.clear()
	project._sync_key_change_map_to_engine()
	sent = _scale_map_sends()
	_assert(sent.size() == 1 and sent[0].args == [1920, 0, 3840, expected], "direct sync sends the current map")


func _test_confirmed_connected_resyncs() -> void:
	# A fresh project connects and confirms like a first connect / engine restart would.
	var project: Object = load("res://data/Project.gd").new()
	_osc._pending_sends.clear()
	project._connection_state = project.ConnectionState.DISCONNECTED
	project.key_change_map.add_change(1920, 2, "dorian")
	_assert(_scale_map_sends().is_empty(), "queued map edit while connecting sends nothing")
	project._connection_state = project.ConnectionState.CONNECTED
	project._sync_key_change_map_to_engine()
	var sent := _scale_map_sends()
	_assert(sent.size() == 1 and sent[0].args == [1920, MusicalScale.make(2, "dorian").mask()],
		"the map is re-sent once connected: %s" % [sent])


func _test_setter_reconnects() -> void:
	var project: Object = load("res://data/Project.gd").new()
	var replacement = load("res://data/KeyChangeMap.gd").new()
	project._connection_state = project.ConnectionState.CONNECTED
	_osc._pending_sends.clear()
	project.key_change_map = replacement
	replacement.add_change(1920, 2, "dorian")
	var sent := _scale_map_sends()
	_assert(sent.size() >= 1 and sent[-1].args == [1920, MusicalScale.make(2, "dorian").mask()],
		"the setter reconnects changed to the new map (from_json replacement keeps syncing)")
