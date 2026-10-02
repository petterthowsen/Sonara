## Offline render jobs (docs/analyze-plan.md Phase 2): starts `/render/start`, tracks the job by id
## and reports progress, completion or failure through signals. UI code (the export dialog) talks to
## this and never sends OSC itself.
##
## The engine runs one render at a time and silences live output while it runs, so `is_running`
## also tells the transport to stand down.
##
## `transport` is anything with `send(address, args)` and `listen(address, callback)`; it defaults to
## the AudioEngineOSC autoload and tests swap in a mock.
class_name RenderService extends Node

## The engine replied that the job started (first progress or immediate rejection come after).
signal job_started(job_id: String)
signal progress_changed(job_id: String, fraction: float)
## `paths` are the files written: the master first (when requested), then the stems in request order.
signal job_finished(job_id: String, paths: PackedStringArray)
## `error` is "cancelled" when the user cancelled.
signal job_failed(job_id: String, error: String)
signal running_changed(running: bool)

const CANCELLED := "cancelled"
const MAX_TAIL_SECONDS := 600.0

var logger := Log.make("RenderService")

var transport: Object = null
var is_running := false
var current_job_id := ""
var progress := 0.0

var _counter := 0
var _listening := false


func _ready() -> void:
	_ensure_transport()


## Start a render. Returns the job id, or "" when the request was rejected (the reason is also
## emitted through `job_failed` with an empty id).
##
## `options` keys:
##   start_tick, end_tick (int, required, end exclusive)
##   tail_seconds (float, default 0), until_silent (bool, default false)
##   master_path (String, "" for none), bit_depth (16, 24 or 32; default 24)
##   stems: Array of {"channel_id": int, "path": String}
func start(options: Dictionary) -> String:
	var error := validate(options)
	if error != "":
		logger.warn("Render rejected: ", error)
		job_failed.emit("", error)
		return ""
	if is_running:
		job_failed.emit("", "A render is already running")
		return ""
	_ensure_transport()
	_counter += 1
	var job_id := "render_%d_%d" % [Time.get_ticks_msec(), _counter]
	var args: Array = [
		job_id,
		int(options.start_tick),
		int(options.end_tick),
		clampf(float(options.get("tail_seconds", 0.0)), 0.0, MAX_TAIL_SECONDS),
		1 if options.get("until_silent", false) else 0,
		String(options.get("master_path", "")),
		int(options.get("bit_depth", 24)),
		0, # engine sample rate
		0, # default block size
	]
	for stem in options.get("stems", []):
		args.append(int(stem.channel_id))
		args.append(String(stem.path))
	current_job_id = job_id
	progress = 0.0
	_set_running(true)
	transport.send("/render/start", args)
	logger.info("Render started: ", job_id)
	job_started.emit(job_id)
	return job_id


## Returns "" when `options` describe a valid job, else a message for the user.
static func validate(options: Dictionary) -> String:
	if not options.has("start_tick") or not options.has("end_tick"):
		return "No range to render"
	if int(options.end_tick) <= int(options.start_tick):
		return "The range is empty"
	var master_path := String(options.get("master_path", ""))
	var stems: Array = options.get("stems", [])
	if master_path == "" and stems.is_empty():
		return "Nothing to export: pick the master or at least one channel"
	if not int(options.get("bit_depth", 24)) in [16, 24, 32]:
		return "Bit depth must be 16, 24 or 32"
	for stem in stems:
		if String(stem.path) == "":
			return "A stem has no file path"
	return ""


## Ask the engine to stop the running render; it answers with `job_failed("cancelled")`.
func cancel() -> void:
	if not is_running:
		return
	transport.send("/render/cancel", [current_job_id])
	logger.info("Render cancel requested: ", current_job_id)


func _ensure_transport() -> void:
	if transport == null:
		transport = AudioEngineOSC
	if _listening or transport == null:
		return
	transport.listen("/render/progress", _on_progress)
	transport.listen("/render/done", _on_done)
	transport.listen("/render/failed", _on_failed)
	_listening = true


func _on_progress(args: Array) -> void:
	if args.size() < 2 or str(args[0]) != current_job_id or not is_running:
		return
	progress = clampf(float(args[1]), 0.0, 1.0)
	progress_changed.emit(current_job_id, progress)


func _on_done(args: Array) -> void:
	if args.is_empty() or str(args[0]) != current_job_id or not is_running:
		return
	var job_id := current_job_id
	var paths := PackedStringArray()
	for i in range(1, args.size()):
		paths.append(str(args[i]))
	progress = 1.0
	_set_running(false)
	logger.info("Render finished: ", job_id, " files=", paths.size())
	job_finished.emit(job_id, paths)


func _on_failed(args: Array) -> void:
	if args.is_empty():
		return
	var job_id := str(args[0])
	# A rejected request is answered with the id we sent, so it matches the current job too.
	if job_id != current_job_id or not is_running:
		return
	var error := str(args[1]) if args.size() > 1 else "Render failed"
	_set_running(false)
	logger.warn("Render failed: ", job_id, " ", error)
	job_failed.emit(job_id, error)


func _set_running(value: bool) -> void:
	if is_running == value:
		return
	is_running = value
	if not value:
		current_job_id = ""
	running_changed.emit(value)
