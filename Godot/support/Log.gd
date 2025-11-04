class_name Log extends RefCounted

static var loggers : Dictionary[String, Log] = {}

static var log_file_path := "res://logs/last.log"
static var log_file : FileAccess

static func _static_init() -> void:
	log_file = FileAccess.open(log_file_path, FileAccess.WRITE)
	log_file.resize(0)
	
	if not log_file:
		push_error("Failed to open log file at ", log_file_path)

var print_prefix : String = ""

var debug_messages : Array[String] = []
var info_messages : Array[String] = []
var warning_messages : Array[String] = []
var error_messages : Array[String] = []

var print_to_console : bool = true

func _init(prefix : String, ptc: bool = true):
	print_prefix = prefix
	print_to_console = ptc

static func make(prefix: String, ptc := true) -> Log:
	if not loggers.has(prefix):
		var logger = Log.new(prefix, ptc)
		loggers[prefix] = logger
	
	return loggers[prefix]

func debug(...message: Array[Variant]):
	debug_messages.append(" ".join(message))
	log_file.store_line("[" + print_prefix + "] DEBUG: " + " ".join(message))
	log_file.flush()
	
	if print_to_console:
		print("[" + print_prefix + "] DEBUG: " + " ".join(message))

func info(...message: Array[Variant]):
	info_messages.append(" ".join(message))
	var er = log_file.store_line("[" + print_prefix + "] INFO: " + " ".join(message))
	log_file.flush()
	if not er:
		push_error("failed to write to log file!")
	
	if print_to_console:
		print_rich("[color=green][" + print_prefix + "] INFO: " + " ".join(message) + "[/color]")

func warn(...msg : Array[Variant]):
	warning.callv(msg)

func warning(...message: Array[Variant]):
	warning_messages.append(" ".join(message))
	log_file.store_line("[" + print_prefix + "] WARN: " + " ".join(message))
	log_file.flush()
	
	if print_to_console:
		print_rich("[color=yellow][" + print_prefix + "] WARNING: " + " ".join(message) + "[/color]")

func error(...message: Array[Variant]):
	error_messages.append(" ".join(message))
	log_file.store_string("[" + print_prefix + "] ERROR: " + " ".join(message) + "\n")
	log_file.flush()
	push_error("[" + print_prefix + "] " + " ".join(message))
