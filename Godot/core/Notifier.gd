## Desktop notification for long jobs that finish while the app is in the background.
##
## Uses `notify-send` (Linux only), started without waiting for it so the UI never blocks, and
## asks the window manager for attention. Does nothing while one of the app's windows is focused, in test
## mode, off Linux, or when `notify-send` is not installed.
class_name Notifier extends RefCounted


## True when a notification should be shown now.
static func should_notify() -> bool:
	if not OS.has_feature("linuxbsd") or Utils.is_test_mode():
		return false
	# Any of our windows (main, export dialog, device frames) having focus counts as in the app.
	for id in DisplayServer.get_window_list():
		if DisplayServer.window_is_focused(id):
			return false
	return true


## Arguments for `notify-send`.
static func notify_args(app_name: String, title: String, body: String) -> PackedStringArray:
	return PackedStringArray(["--app-name=" + app_name, "--", title, body])


## Show `title` / `body` and flag the main window, but only when it is not focused.
static func notify(title: String, body: String = "") -> void:
	if not should_notify():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.root.request_attention()
	var app_name := str(ProjectSettings.get_setting("application/config/name", "Sonara"))
	# create_process returns -1 when the executable cannot be started (no notify-send): ignore.
	OS.create_process("notify-send", notify_args(app_name, title, body))
