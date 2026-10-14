# test_connect_handshake.gd
# Issue #119: a lost /status/connected left the project in CONNECTING forever. The handshake is
# now resent while CONNECTING and gives up with connection_failed after HANDSHAKE_MAX_ATTEMPTS.
extends TestBase

var P: GDScript

var _failed_reason := ""


func suite_name() -> String:
	return "Connect handshake"


func run_tests() -> void:
	P = load("res://data/Project.gd")
	_test_step_decision()
	await _test_retry_then_fail()
	_test_cancel_stops_watchdog()


func _test_step_decision() -> void:
	_assert(P.handshake_step(1, 3) == P.HandshakeStep.RETRY, "first unanswered send retries")
	_assert(P.handshake_step(2, 3) == P.HandshakeStep.RETRY, "still retrying below the cap")
	_assert(P.handshake_step(3, 3) == P.HandshakeStep.FAIL, "fails once the cap is reached")


func _count(osc: Node, address: String) -> int:
	return osc._pending_sends.filter(func(i) -> bool: return i.address == address).size()


func _test_retry_then_fail() -> void:
	var osc: Node = root.get_node_or_null("AudioEngineOSC")
	_assert(osc != null, "setup: AudioEngineOSC autoload present")
	if osc == null:
		return
	osc._pending_sends.clear()
	var project = P.new()
	project.connection_failed.connect(func(r: String) -> void: _failed_reason = r)
	project.connect_to_engine()
	_assert(project.get_connection_state() == P.ConnectionState.CONNECTING, "connect enters CONNECTING")
	_assert(_count(osc, "/project/init") == 1, "one init sent immediately")
	var waits := int(P.HANDSHAKE_RETRY_SEC * 1000.0) + 200
	await create_timer(waits / 1000.0).timeout
	_assert(_count(osc, "/project/init") == 2, "init resent after the retry interval: %d" % _count(osc, "/project/init"))
	_assert(project.get_connection_state() == P.ConnectionState.CONNECTING, "still CONNECTING mid-retries")
	# Skip the wait: pretend all attempts were used.
	project._handshake_attempts = P.HANDSHAKE_MAX_ATTEMPTS
	await create_timer(waits / 1000.0).timeout
	_assert(project.get_connection_state() == P.ConnectionState.DISCONNECTED, "gives up to DISCONNECTED")
	_assert(not _failed_reason.is_empty(), "connection_failed carries a reason")
	var inits := _count(osc, "/project/init")
	await create_timer(waits / 1000.0).timeout
	_assert(_count(osc, "/project/init") == inits, "no more resends after failing")


func _test_cancel_stops_watchdog() -> void:
	var osc: Node = root.get_node_or_null("AudioEngineOSC")
	if osc == null:
		return
	var project = P.new()
	project.connect_to_engine()
	var id: int = project._handshake_id
	project.disconnect_from_engine()
	_assert(project._handshake_id != id, "disconnect invalidates the pending watchdog")
	_assert(project.get_connection_state() == P.ConnectionState.DISCONNECTED, "cancelled connect is DISCONNECTED")
