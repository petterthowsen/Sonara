# test_app_paths.gd
# AppPaths resolves the folder layout from the environment (spec 046 REQ-001..004).
# Run: godot --headless --path Godot -s tests/test_app_paths.gd -- --test
extends TestBase


func suite_name() -> String:
	return "AppPaths tests"


func run_tests() -> void:
	_test_defaults_under_home()
	_test_xdg_overrides()
	_test_documents_folder()
	_test_content_subfolders()
	_test_runtime_dir()
	_test_log_is_usable_from_static_init()
	AppPaths.env_override = {}


func _fake_env(extra: Dictionary = {}) -> void:
	var env := {
		"HOME": "/tmp/fakehome",
		"XDG_CONFIG_HOME": "",
		"XDG_CACHE_HOME": "",
		"XDG_STATE_HOME": "",
		"XDG_RUNTIME_DIR": "",
	}
	env.merge(extra, true)
	AppPaths.env_override = env


func _test_defaults_under_home() -> void:
	_fake_env()
	_assert(AppPaths.config_dir() == "/tmp/fakehome/.config/sonara", "config defaults to ~/.config/sonara")
	_assert(AppPaths.cache_dir() == "/tmp/fakehome/.cache/sonara", "cache defaults to ~/.cache/sonara")
	_assert(AppPaths.state_dir() == "/tmp/fakehome/.local/state/sonara", "state defaults to ~/.local/state/sonara")
	_assert(AppPaths.log_dir() == "/tmp/fakehome/.local/state/sonara/logs", "log dir is <state>/logs")
	_assert(AppPaths.ui_log_dir() == AppPaths.log_dir() + "/ui", "ui logs are in a ui subfolder")
	_assert(AppPaths.engine_log_dir() == AppPaths.log_dir() + "/engine", "engine logs are in an engine subfolder")


func _test_xdg_overrides() -> void:
	_fake_env({
		"XDG_CONFIG_HOME": "/scratch/cfg",
		"XDG_CACHE_HOME": "/scratch/cache/",
		"XDG_STATE_HOME": "/scratch/state",
	})
	_assert(AppPaths.config_dir() == "/scratch/cfg/sonara", "config follows XDG_CONFIG_HOME")
	_assert(AppPaths.cache_dir() == "/scratch/cache/sonara", "cache follows XDG_CACHE_HOME (trailing slash dropped)")
	_assert(AppPaths.log_dir() == "/scratch/state/sonara/logs", "logs follow XDG_STATE_HOME")
	_assert(AppPaths.engine_log_dir() == "/scratch/state/sonara/logs/engine", "engine log dir follows XDG_STATE_HOME")
	# A relative value is invalid per the XDG spec and ignored.
	_fake_env({"XDG_CONFIG_HOME": "relative/dir"})
	_assert(AppPaths.config_dir() == "/tmp/fakehome/.config/sonara", "relative XDG_CONFIG_HOME is ignored")


func _test_documents_folder() -> void:
	_fake_env()
	_assert(AppPaths.documents_root() == "/tmp/fakehome/Documents", "documents falls back to $HOME/Documents")
	_fake_env({"DOCUMENTS": "/tmp/fakehome/Dokumenter"})
	_assert(AppPaths.documents_root() == "/tmp/fakehome/Dokumenter", "documents follows the desktop's folder")
	_assert(AppPaths.content_root() == "/tmp/fakehome/Dokumenter/Sonara", "content root is <Documents>/Sonara")


func _test_content_subfolders() -> void:
	_fake_env({"DOCUMENTS": "/docs"})
	_assert(AppPaths.projects_dir() == "/docs/Sonara/projects", "projects subfolder")
	_assert(AppPaths.presets_dir() == "/docs/Sonara/presets", "presets subfolder")
	_assert(AppPaths.note_maps_dir() == "/docs/Sonara/note_maps", "note_maps subfolder")
	_fake_env()
	for dir in [AppPaths.projects_dir(), AppPaths.presets_dir(), AppPaths.note_maps_dir()]:
		_assert(dir.begins_with(AppPaths.documents_root() + "/Sonara/"), "%s is under the documents folder" % dir)


func _test_runtime_dir() -> void:
	_fake_env({"XDG_RUNTIME_DIR": "/run/user/1000"})
	_assert(AppPaths.runtime_dir() == "/run/user/1000/sonara", "runtime dir follows XDG_RUNTIME_DIR")
	_fake_env()
	_assert(AppPaths.runtime_dir() == "/tmp/fakehome/.cache/sonara/run", "runtime dir falls back to the cache")


## Log._static_init() runs before any autoload exists; it must not need one, and in test mode it
## must keep the project-local log.
func _test_log_is_usable_from_static_init() -> void:
	_assert(Utils.is_test_mode(), "test mode is detected from a static context")
	_assert(Log.log_file_path == Log.TEST_LOG_PATH, "test mode keeps res://logs/last.log")
