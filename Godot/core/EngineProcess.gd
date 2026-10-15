## Owns the engine process from the UI side (spec 046, ADR 0022): attaches to a running engine,
## starts one from the install folder when none answers, and stops the one it started on quit.
##
## Inert in test mode and in a duplicate instance (see Sonara.is_duplicate_instance).
extends Node

## Fired after ensure_running() decided what to do. `launched` is true when a new engine started.
signal engine_ready(launched: bool)

const ENGINE_PORT := 7000
const ENGINE_ADDRESS := "127.0.0.1"
## How long stop() waits for the engine's graceful exit before killing it.
const STOP_TIMEOUT_MSEC := 3000
const STOP_POLL_MSEC := 50
const ENGINE_BINARY_NAME := "engine"
const DEV_ENGINE_RELATIVE := "../Engine/target/release/engine"

var logger := Log.make("EngineProcess")

## Pid of the engine this UI started, 0 when it attached to someone else's (or none).
var _pid: int = 0


func is_owned() -> bool:
	return _pid > 0


func pid() -> int:
	return _pid


func _active() -> bool:
	if Utils.is_test_mode():
		return false
	return not Sonara.is_duplicate_instance


## Where the engine binary is: next to the UI executable in an install, in the build folder of
## the source checkout in a dev run. Empty when it isn't there.
func engine_binary_path() -> String:
	var candidate: String
	if OS.has_feature("editor"):
		candidate = ProjectSettings.globalize_path("res://").path_join(DEV_ENGINE_RELATIVE).simplify_path()
	else:
		candidate = OS.get_executable_path().get_base_dir().path_join(ENGINE_BINARY_NAME)
	return candidate if FileAccess.file_exists(candidate) else ""


## True when nothing owns the engine port, i.e. no engine is running. Binding is instant, which
## is why this beats waiting for a heartbeat. The engine's Rust socket sets no SO_REUSEADDR, so a
## running engine makes the bind fail (checked in T-001).
static func is_engine_port_free() -> bool:
	var probe := PacketPeerUDP.new()
	var err := probe.bind(ENGINE_PORT, ENGINE_ADDRESS)
	probe.close()
	return err == OK


## Make sure an engine is running. Attaches when one already answers on the port (leaving it
## alone on quit), otherwise starts the engine binary. Returns false when no engine is running
## and none could be started; the connect flow then fails as it always did.
func ensure_running() -> bool:
	if not _active():
		return false
	# Never hold up the first frame.
	if is_inside_tree():
		await get_tree().process_frame
	if _pid > 0 and OS.is_process_running(_pid):
		engine_ready.emit(false)
		return true
	_pid = 0
	if not is_engine_port_free():
		logger.info("An engine already answers on port %d; attaching to it" % ENGINE_PORT)
		engine_ready.emit(false)
		return true
	var binary := engine_binary_path()
	if binary.is_empty():
		logger.warn("No engine is running and no engine binary was found. Start the engine by hand.")
		return false
	# The kernel's parent-death signal (PR_SET_PDEATHSIG, set by the engine's --parent-pid) is
	# tied to the *thread* that forked the child. This runs on the main thread, which lives as
	# long as the process; never spawn the engine from a WorkerThreadPool task or Thread.
	var args := PackedStringArray([
		"--log-dir", AppPaths.engine_log_dir(),
		"--parent-pid", str(OS.get_process_id()),
	])
	var new_pid := OS.create_process(binary, args)
	if new_pid <= 0:
		logger.error("Could not start the engine: %s" % binary)
		return false
	_pid = new_pid
	logger.info("Started engine %s (pid %d), logs in %s" % [binary, _pid, AppPaths.engine_log_dir()])
	engine_ready.emit(true)
	return true


## Ask the engine to quit over OSC; after STOP_TIMEOUT_MSEC kill it. Does nothing for an engine
## this UI didn't start. Keeps the UI responsive while it waits.
func stop() -> void:
	if _pid <= 0:
		return
	var pid_to_stop := _pid
	_request_quit()
	var deadline := Time.get_ticks_msec() + STOP_TIMEOUT_MSEC
	while OS.is_process_running(pid_to_stop) and Time.get_ticks_msec() < deadline:
		if is_inside_tree():
			await get_tree().create_timer(STOP_POLL_MSEC / 1000.0).timeout
		else:
			OS.delay_msec(STOP_POLL_MSEC)
	_finish_stop(pid_to_stop)


## Blocking variant for the shutdown safety net, where no frames will run any more.
func _stop_blocking() -> void:
	if _pid <= 0:
		return
	var pid_to_stop := _pid
	_request_quit()
	var deadline := Time.get_ticks_msec() + STOP_TIMEOUT_MSEC
	while OS.is_process_running(pid_to_stop) and Time.get_ticks_msec() < deadline:
		OS.delay_msec(STOP_POLL_MSEC)
	_finish_stop(pid_to_stop)


func _finish_stop(pid_to_stop: int) -> void:
	if OS.is_process_running(pid_to_stop):
		# SIGKILL: skips the engine's PipeWire quantum restore, which is why it is the fallback.
		logger.warn("Engine pid %d did not exit in %d ms; killing it" % [pid_to_stop, STOP_TIMEOUT_MSEC])
		OS.kill(pid_to_stop)
	else:
		logger.info("Engine pid %d exited" % pid_to_stop)
	if _pid == pid_to_stop:
		_pid = 0


## Sent through a socket of our own so it works while AudioEngineOSC is being torn down.
func _request_quit() -> void:
	var peer := PacketPeerUDP.new()
	peer.set_dest_address(ENGINE_ADDRESS, ENGINE_PORT)
	peer.put_packet(osc_message("/engine/quit"))
	peer.close()


## An OSC message without arguments: the address and the empty type tag ",", each NUL-padded to a
## multiple of four bytes.
static func osc_message(address: String) -> PackedByteArray:
	var bytes := PackedByteArray()
	for text in [address, ","]:
		bytes.append_array(text.to_ascii_buffer())
		bytes.append(0)
		while bytes.size() % 4 != 0:
			bytes.append(0)
	return bytes


func _exit_tree() -> void:
	# Safety net for quit paths that skip Editor.quit().
	_stop_blocking()
