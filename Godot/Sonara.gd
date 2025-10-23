# Sonara.gd
# Main Autoload
# Handles Init, Settings and Project creation & loading
extends Node

var editor : Editor:
	get:
		if not editor:
			editor = get_parent().get_node("Editor")
		return editor


const CONFIG_PATH = "user://config.json"
var config : Dictionary:
	get:
		if not config:
			load_config()
		return config


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

## Save the current configuration to disk
func save_config():
	var file = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file:
		var json_string = JSON.stringify(config, "\t")
		file.store_string(json_string)
		file.close()
		print("Config saved to: ", CONFIG_PATH)
	else:
		push_error("Failed to save config to: " + CONFIG_PATH)

## Load configuration from disk (called automatically on init)
func load_config():
	if FileAccess.file_exists(CONFIG_PATH):
		var file = FileAccess.open(CONFIG_PATH, FileAccess.READ)
		if file:
			var json_string = file.get_as_text()
			file.close()

			var json = JSON.new()
			var error = json.parse(json_string)
			if error == OK:
				config = json.data
				print("Config loaded from: ", CONFIG_PATH)
			else:
				push_error("Failed to parse config JSON: " + json.get_error_message())
		else:
			push_error("Failed to open config file: " + CONFIG_PATH)
	else:
		print("No config file found, starting with empty config")
