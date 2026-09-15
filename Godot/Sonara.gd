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


## Try to locate waveform cache file in standard locations
func find_waveform_cache_file(cache_key: String) -> String:
	if cache_key.is_empty():
		return ""

	var cache_paths = []

	# Linux: XDG_CACHE_HOME or ~/.cache
	var xdg_cache = OS.get_environment("XDG_CACHE_HOME")
	if not xdg_cache.is_empty():
		cache_paths.append(xdg_cache + "/sonara/waveforms/" + cache_key)

	var home = OS.get_environment("HOME")
	if not home.is_empty():
		cache_paths.append(home + "/.cache/sonara/waveforms/" + cache_key)
		# macOS
		cache_paths.append(home + "/Library/Caches/sonara/waveforms/" + cache_key)

	# Godot config dir cache
	cache_paths.append(OS.get_config_dir() + "/.cache/sonara/waveforms/" + cache_key)

	# Windows
	var appdata = OS.get_environment("APPDATA")
	if not appdata.is_empty():
		cache_paths.append(appdata + "/sonara/waveforms/" + cache_key)

	for path in cache_paths:
		if FileAccess.file_exists(path):
			return path

	return ""
