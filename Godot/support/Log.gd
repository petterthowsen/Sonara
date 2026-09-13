## Named loggers plus a process-wide capture of Godot errors into last.log.
class_name Log extends RefCounted

static var loggers: Dictionary[String, Log] = {}

static var log_file_path := "res://logs/last.log"
static var log_file: FileAccess

static var _file_mutex := Mutex.new()
static var _engine_logger: Logger
static var _skip_capture := false
static var _skip_capture_thread_id := 0


## Open last.log and register the engine interceptor as soon as this class loads.
static func _static_init() -> void:
	_ensure_log_dir()
	log_file = FileAccess.open(log_file_path, FileAccess.WRITE)
	if not log_file:
		printerr("Failed to open log file at ", log_file_path)
		return
	log_file.resize(0)
	_engine_logger = EngineLogCapture.new()
	OS.add_logger(_engine_logger)


## Create the logs directory if missing so FileAccess.open can succeed.
static func _ensure_log_dir() -> void:
	var abs_dir := ProjectSettings.globalize_path(log_file_path.get_base_dir())
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)


## Append one line to last.log. Safe to call from any thread.
static func _write_line(line: String) -> void:
	if log_file == null:
		return
	_file_mutex.lock()
	log_file.store_line(line)
	log_file.flush()
	_file_mutex.unlock()


## Record a Godot engine error/warning (push_error, push_warning, script, shader).
static func capture_engine_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		error_type: int,
		script_backtraces: Array
) -> void:
	if _should_skip_engine_capture():
		return
	var message := rationale if not rationale.is_empty() else code
	if message.is_empty():
		return
	var loc := _resolve_location(file, line, function, script_backtraces)
	var label := _error_type_label(error_type)
	var loc_text := ""
	if not loc.path.is_empty():
		if loc.function.is_empty():
			loc_text = " (%s:%d)" % [loc.path, loc.line]
		else:
			loc_text = " (%s:%d @ %s)" % [loc.path, loc.line, loc.function]
	_write_line("[Godot] %s: %s%s" % [label, message, loc_text])


## True when this thread is already writing via Log.error/warning → push_*.
static func _should_skip_engine_capture() -> bool:
	_file_mutex.lock()
	var skip := _skip_capture and OS.get_thread_caller_id() == _skip_capture_thread_id
	_file_mutex.unlock()
	return skip


## Ignore the matching engine callback so named logger lines are not duplicated.
static func _set_skip_engine_capture(skip: bool) -> void:
	_file_mutex.lock()
	_skip_capture = skip
	_skip_capture_thread_id = OS.get_thread_caller_id() if skip else 0
	_file_mutex.unlock()


## Map Logger.ErrorType to the last.log level label.
static func _error_type_label(error_type: int) -> String:
	match error_type:
		Logger.ERROR_TYPE_WARNING:
			return "WARN"
		Logger.ERROR_TYPE_SCRIPT:
			return "SCRIPT"
		Logger.ERROR_TYPE_SHADER:
			return "SHADER"
		_:
			return "ERROR"


## Prefer the first user script frame; push_error reports a C++ file by default.
static func _resolve_location(
		file: String,
		line: int,
		function: String,
		script_backtraces: Array
) -> Dictionary:
	for bt in script_backtraces:
		if bt == null or bt.get_frame_count() == 0:
			continue
		for i in bt.get_frame_count():
			var path: String = bt.get_frame_file(i)
			if _is_internal_log_frame(path):
				continue
			return {
				"path": path,
				"line": bt.get_frame_line(i),
				"function": bt.get_frame_function(i),
			}
	return {"path": file, "line": line, "function": function}


## Frames inside this file are the interceptor / Log.error wrapper, not the caller.
static func _is_internal_log_frame(path: String) -> bool:
	return path.ends_with("/support/Log.gd") or path.get_file() == "Log.gd"


var print_prefix: String = ""

var debug_messages: Array[String] = []
var info_messages: Array[String] = []
var warning_messages: Array[String] = []
var error_messages: Array[String] = []

var print_to_console: bool = true


## Create a named logger that writes with `[prefix]` to last.log and the console.
func _init(prefix: String, ptc: bool = true):
	print_prefix = prefix
	print_to_console = ptc


## Return the shared logger for `prefix`, creating it on first use.
static func make(prefix: String, ptc := true) -> Log:
	if not loggers.has(prefix):
		var logger = Log.new(prefix, ptc)
		loggers[prefix] = logger
	return loggers[prefix]


## Write a debug line to last.log (and stdout when enabled).
func debug(...message: Array[Variant]):
	debug_messages.append(" ".join(message))
	_write_line("[" + print_prefix + "] DEBUG: " + " ".join(message))
	if print_to_console:
		print("[" + print_prefix + "] DEBUG: " + " ".join(message))


## Write an info line to last.log (and stdout when enabled).
func info(...message: Array[Variant]):
	info_messages.append(" ".join(message))
	_write_line("[" + print_prefix + "] INFO: " + " ".join(message))
	if print_to_console:
		print_rich("[color=green][" + print_prefix + "] INFO: " + " ".join(message) + "[/color]")


## Alias for warning().
func warn(...msg: Array[Variant]):
	warning.callv(msg)


## Write a warning to last.log (and stdout when enabled).
func warning(...message: Array[Variant]):
	warning_messages.append(" ".join(message))
	_write_line("[" + print_prefix + "] WARN: " + " ".join(message))
	if print_to_console:
		print_rich("[color=yellow][" + print_prefix + "] WARNING: " + " ".join(message) + "[/color]")


## Write an error to last.log and surface it in the Godot debugger.
func error(...message: Array[Variant]):
	error_messages.append(" ".join(message))
	_write_line("[" + print_prefix + "] ERROR: " + " ".join(message))
	_set_skip_engine_capture(true)
	push_error("[" + print_prefix + "] " + " ".join(message))
	_set_skip_engine_capture(false)


## Forwards engine `_log_error` into last.log. Kept alive via `_engine_logger`.
class EngineLogCapture extends Logger:
	## Called for push_error, push_warning, script errors, and shader errors.
	func _log_error(
			function: String,
			file: String,
			line: int,
			code: String,
			rationale: String,
			_editor_notify: bool,
			error_type: int,
			script_backtraces: Array
	) -> void:
		Log.capture_engine_error(function, file, line, code, rationale, error_type, script_backtraces)
