## The one place that knows where Sonara keeps its files (spec 046).
##
## - user content: <Documents>/Sonara/{projects,presets,note_maps}
## - settings and internal state: $XDG_CONFIG_HOME/sonara (default ~/.config/sonara)
## - regenerable data: $XDG_CACHE_HOME/sonara (default ~/.cache/sonara)
## - logs: $XDG_STATE_HOME/sonara/logs/{ui,engine} (default ~/.local/state/sonara/logs)
##
## Everything is static and uses no autoload, because Log._static_init() runs before any autoload
## exists. The engine computes the same engine log directory itself (logging::default_log_dir in
## Engine/src/logging/mod.rs); keep the two in step.
class_name AppPaths extends RefCounted

## Folder name under Documents, config, cache and state.
const APP_DIR_NAME := "Sonara"
const XDG_DIR_NAME := "sonara"

## Tests set entries here to stand in for environment variables ("HOME", "XDG_CONFIG_HOME",
## "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR") and the one pseudo variable "DOCUMENTS"
## (the desktop's documents folder). An empty dictionary reads the real environment.
static var env_override: Dictionary = {}


static func _env(name: String) -> String:
	if env_override.has(name):
		return str(env_override[name])
	return OS.get_environment(name)


static func _home() -> String:
	var home := _env("HOME")
	if home.is_empty():
		home = OS.get_environment("HOME")
	return home.trim_suffix("/")


## An XDG base dir: the variable when it holds an absolute path (the spec says to ignore anything
## else), otherwise `$HOME/<default_rel>`.
static func _xdg_base(var_name: String, default_rel: String) -> String:
	var value := _env(var_name)
	if value.begins_with("/"):
		return value.trim_suffix("/")
	return _home().path_join(default_rel)


## The desktop's documents folder (the XDG user dir, e.g. ~/Dokumenter), or $HOME/Documents.
static func documents_root() -> String:
	if env_override.has("DOCUMENTS"):
		return str(env_override["DOCUMENTS"]).trim_suffix("/")
	var home := _home()
	# With a faked home the system query would answer for the real one.
	if not env_override.has("HOME"):
		var system := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).trim_suffix("/")
		# xdg-user-dir answers $HOME itself when no documents folder is configured.
		if not system.is_empty() and system != home:
			return system
	return home.path_join("Documents")


## <Documents>/Sonara
static func content_root() -> String:
	return documents_root().path_join(APP_DIR_NAME)


static func projects_dir() -> String:
	return content_root().path_join("projects")


static func presets_dir() -> String:
	return content_root().path_join("presets")


static func note_maps_dir() -> String:
	return content_root().path_join("note_maps")


## $XDG_CONFIG_HOME/sonara
static func config_dir() -> String:
	return _xdg_base("XDG_CONFIG_HOME", ".config").path_join(XDG_DIR_NAME)


## $XDG_CACHE_HOME/sonara
static func cache_dir() -> String:
	return _xdg_base("XDG_CACHE_HOME", ".cache").path_join(XDG_DIR_NAME)


## $XDG_STATE_HOME/sonara
static func state_dir() -> String:
	return _xdg_base("XDG_STATE_HOME", ".local/state").path_join(XDG_DIR_NAME)


## The folder that Help > Open Logs Folder opens.
static func log_dir() -> String:
	return state_dir().path_join("logs")


static func ui_log_dir() -> String:
	return log_dir().path_join("ui")


static func engine_log_dir() -> String:
	return log_dir().path_join("engine")


## Per-session runtime files (the single-instance PID file). Without $XDG_RUNTIME_DIR it falls
## back to a folder in the cache dir; the PID file checks for staleness anyway.
static func runtime_dir() -> String:
	var run := _env("XDG_RUNTIME_DIR")
	if run.begins_with("/"):
		return run.trim_suffix("/").path_join(XDG_DIR_NAME)
	return cache_dir().path_join("run")
