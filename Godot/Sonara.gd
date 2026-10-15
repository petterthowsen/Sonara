# Sonara.gd
# Main Autoload
# Handles Init, Settings and Project creation & loading
extends Node

var logger := Log.make("Sonara")

var editor : Editor:
	get:
		if not editor:
			editor = get_parent().get_node("Editor")
		return editor


var _config_path : String = ""

var config : Dictionary:
	get:
		if not config:
			load_config()
		return config


## Get the configuration directory path ($XDG_CONFIG_HOME/sonara, normally ~/.config/sonara).
## Thin wrapper: AppPaths owns the folder layout (spec 046).
func get_config_dir() -> String:
	return AppPaths.config_dir()


## Get the main config file path
func get_config_path() -> String:
	if _config_path.is_empty():
		_config_path = get_config_dir() + "/config.json"
	return _config_path


## Get the default projects directory (<Documents>/Sonara/projects).
func get_projects_dir() -> String:
	return AppPaths.projects_dir()


## True when another Sonara UI already runs. The new instance then touches nothing: no engine,
## no OSC sockets, no project connect. It shows a message and quits (spec 046 REQ-018).
var is_duplicate_instance := false


func _ready() -> void:
	if Utils.is_test_mode():
		return
	if not SingleInstance.claim(SingleInstance.pid_file_path(), OS.get_process_id(), OS.get_executable_path()):
		is_duplicate_instance = true
		logger.warn("Another Sonara is already running; exiting")
		OS.alert("Sonara is already running.", "Sonara")
		get_tree().quit()
		return
	_ensure_config_dir()
	_ensure_projects_dir()
	load_config()


func _exit_tree() -> void:
	if not is_duplicate_instance and not Utils.is_test_mode():
		SingleInstance.release(SingleInstance.pid_file_path(), OS.get_process_id())


## First `.sonara` path among the command-line arguments, or "". Godot may treat a bare
## positional argument as its own (`sonara demo.sonara`), so both the engine's list and the user
## arguments after `--` (`sonara -- demo.sonara`, what the desktop entry uses) are searched.
## A relative path is resolved against $PWD. The file must exist.
func cli_project_path() -> String:
	return project_path_from_args(OS.get_cmdline_args() + OS.get_cmdline_user_args())


static func project_path_from_args(args: PackedStringArray) -> String:
	for arg in args:
		if not arg.to_lower().ends_with(".sonara"):
			continue
		var path := arg
		if path.begins_with("file://"):
			path = path.uri_file_decode().trim_prefix("file://")
		if path.begins_with("~/"):
			path = OS.get_environment("HOME").path_join(path.substr(2))
		elif path.is_relative_path():
			var pwd := OS.get_environment("PWD")
			if not pwd.is_empty():
				path = pwd.path_join(path)
		path = path.simplify_path()
		if FileAccess.file_exists(path):
			return path
	return ""


## Get a configuration value by key, optionally returning a default if not found
## Supports slash-notation for nested access: "audio/buffer_size"
func get_config(key: String, default = null):
	if "/" in key:
		var keys = key.split("/")
		var current = config
		for k in keys:
			if current is Dictionary and current.has(k):
				current = current[k]
			else:
				return default
		return current
	else:
		return config.get(key, default)

## Set a configuration value by key
## Supports slash-notation for nested access: "audio/buffer_size"
## Auto-creates nested dictionaries as needed
func set_config(key: String, value):
	if "/" in key:
		var keys = key.split("/")
		var current = config
		for i in range(keys.size() - 1):
			var k = keys[i]
			if not current.has(k) or not (current[k] is Dictionary):
				current[k] = {}
			current = current[k]
		current[keys[-1]] = value
	else:
		config[key] = value

const MAX_RECENT_PROJECTS := 5

## Most recently opened or saved project paths, newest first.
func get_recent_projects() -> Array[String]:
	var result: Array[String] = []
	var stored = get_config("recent_projects", [])
	if stored is Array:
		for p in stored:
			if p is String and not p.is_empty():
				result.append(p)
	return result

## Move `path` to the front of the recent projects list (capped at MAX_RECENT_PROJECTS) and save.
func add_recent_project(path: String) -> void:
	if path.is_empty():
		return
	var recent := get_recent_projects()
	recent.erase(path)
	recent.push_front(path)
	set_config("recent_projects", recent.slice(0, MAX_RECENT_PROJECTS))
	save_config()

func remove_recent_project(path: String) -> void:
	var recent := get_recent_projects()
	recent.erase(path)
	set_config("recent_projects", recent)
	save_config()

func clear_recent_projects() -> void:
	set_config("recent_projects", [])
	save_config()

## Fixed location of the startup project; it opens on launch instead of a blank project.
func get_startup_project_path() -> String:
	return get_config_dir() + "/startup.sonara"

func has_startup_project() -> bool:
	return FileAccess.file_exists(get_startup_project_path())

func is_startup_project_path(path: String) -> bool:
	return not path.is_empty() and path == get_startup_project_path()

func clear_startup_project() -> void:
	if has_startup_project():
		DirAccess.remove_absolute(get_startup_project_path())

## Ensure the configuration directory exists
func _ensure_config_dir() -> void:
	var config_dir = get_config_dir()
	if not DirAccess.dir_exists_absolute(config_dir):
		var err = DirAccess.make_dir_recursive_absolute(config_dir)
		if err == OK:
			logger.info("Created config directory: ", config_dir)
		else:
			logger.error("Failed to create config directory: ", config_dir)
	else:
		logger.debug("Config directory verified: ", config_dir)


## Ensure the projects directory exists
func _ensure_projects_dir() -> void:
	var projects_dir = get_projects_dir()
	if not DirAccess.dir_exists_absolute(projects_dir):
		var err = DirAccess.make_dir_recursive_absolute(projects_dir)
		if err == OK:
			logger.info("Created projects directory: ", projects_dir)
		else:
			logger.error("Failed to create projects directory: ", projects_dir)
	else:
		logger.debug("Projects directory verified: ", projects_dir)


## Save the current configuration to disk (mode 0600, set before writing)
func save_config():
	# Test mode never loads the real config, so saving would clobber it with test state.
	if Utils.is_test_mode():
		return
	var config_path = get_config_path()
	var file = FileAccess.open(config_path, FileAccess.WRITE)
	if file:
		_restrict_config_permissions(config_path)
		var json_string = JSON.stringify(config, "\t")
		file.store_string(json_string)
		file.close()
		logger.info("Config saved to: ", config_path)
	else:
		logger.error("Failed to save config to: ", config_path)


## chmod 0600: config.json holds the OpenRouter API key.
func _restrict_config_permissions(config_path: String) -> void:
	var mode := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER
	if FileAccess.get_unix_permissions(config_path) == mode:
		return
	if FileAccess.set_unix_permissions(config_path, mode) != OK:
		logger.warn("Failed to restrict config permissions to 0600: ", config_path)


## Load configuration from disk (called automatically on init)
func load_config():
	if Utils.is_test_mode():
		config = {}
		return
	var config_path = get_config_path()
	if FileAccess.file_exists(config_path):
		_restrict_config_permissions(config_path)
		var file = FileAccess.open(config_path, FileAccess.READ)
		if file:
			var json_string = file.get_as_text()
			file.close()

			var json = JSON.new()
			var error = json.parse(json_string)
			if error == OK:
				config = json.data
				logger.info("Config loaded from: ", config_path)
			else:
				logger.error("Failed to parse config JSON: ", json.get_error_message())
		else:
			logger.error("Failed to open config file: ", config_path)
	else:
		logger.debug("No config file found, starting with empty config")
