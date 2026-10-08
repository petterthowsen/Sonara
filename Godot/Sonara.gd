# Sonara.gd
# Main Autoload
# Handles Init, Settings and Project creation & loading
extends Node

## Default projects directory path
const PROJECTS_DIR_NAME = "Sonara"

var logger := Log.make("Sonara")

var editor : Editor:
	get:
		if not editor:
			editor = get_parent().get_node("Editor")
		return editor


var _config_dir : String = ""
var _config_path : String = ""
var _projects_dir : String = ""

var config : Dictionary:
	get:
		if not config:
			load_config()
		return config


## Get the configuration directory path (~/.config/sonara)
func get_config_dir() -> String:
	if _config_dir.is_empty():
		_config_dir = OS.get_environment("HOME") + "/.config/sonara"
	return _config_dir


## Get the main config file path
func get_config_path() -> String:
	if _config_path.is_empty():
		_config_path = get_config_dir() + "/config.json"
	return _config_path


## Get the projects directory path (~/Documents/Sonara)
func get_projects_dir() -> String:
	if _projects_dir.is_empty():
		_projects_dir = OS.get_environment("HOME") + "/Documents/" + PROJECTS_DIR_NAME
	return _projects_dir


func _ready() -> void:
	if Utils.is_test_mode():
		return
	_ensure_config_dir()
	_ensure_projects_dir()
	load_config()


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
	var dir = DirAccess.open(OS.get_environment("HOME"))
	if not dir:
		logger.error("Failed to access HOME directory")
		return
	
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
