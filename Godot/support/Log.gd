class_name Log extends RefCounted

static var loggers : Dictionary[String, Log] = {}

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
	if loggers.has(prefix):
		push_error("[color=red][Log] cannot make log for ", prefix, ". Already exists![/color]")
	
	var logger = Log.new(prefix, ptc)
	Log.loggers[prefix] = logger
	return logger

func debug(...message: Array[Variant]):
	debug_messages.append(" ".join(message))
	if print_to_console:
		print("[" + print_prefix + "] DEBUG: " + " ".join(message))

func info(...message: Array[Variant]):
	info_messages.append(" ".join(message))
	if print_to_console:
		print_rich("[color=green][" + print_prefix + "] INFO: " + " ".join(message) + "[/color]")

func warn(...msg : Array[Variant]):
	warning.callv(msg)

func warning(...message: Array[Variant]):
	warning_messages.append(" ".join(message))
	if print_to_console:
		print_rich("[color=yellow][" + print_prefix + "] WARNING: " + " ".join(message) + "[/color]")

func error(...message: Array[Variant]):
	error_messages.append(" ".join(message))
	push_error(print_prefix + "] ERROR: " + " ".join(message))
