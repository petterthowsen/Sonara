# test_popup_message.gd
# Headless tests for the reusable PopupMessage window: show_message stores and renders
# the title/body, generates caller action buttons ahead of Copy/Close, Copy builds the
# clipboard text, and a later show_message frees the buttons it generated before.
# Run: godot --headless --path Godot -s tests/test_popup_message.gd -- --test
extends TestBase

var _popup: PopupMessage = null


func suite_name() -> String:
	return "PopupMessage tests"


func run_tests() -> void:
	await _test_show_message()
	if _popup:
		_popup.queue_free()
		await process_frame


func _test_show_message() -> void:
	var scene: PackedScene = load("res://components/PopupMessage.tscn")
	_popup = scene.instantiate()
	root.add_child(_popup)
	await process_frame

	var reload_calls := [0]
	_popup.show_message("Plugin crashed: X", "line one\nline two", [
		{"text": "Reload", "callback": func(): reload_calls[0] += 1},
	])
	await process_frame

	_assert(_popup.last_title == "Plugin crashed: X", "last_title stored")
	_assert(_popup.last_body == "line one\nline two", "last_body stored")

	var copy_text: String = _popup.get_copy_text()
	_assert(copy_text.contains("Plugin crashed: X"), "copy text contains the title")
	_assert(copy_text.contains("line one") and copy_text.contains("line two"), "copy text contains the body")

	var actions: HBoxContainer = _popup.get_node("MarginContainer/VBoxContainer/Actions")
	var reload_button: Button = null
	for child in actions.get_children():
		if child is Button and (child as Button).text == "Reload":
			reload_button = child
			break
	_assert(reload_button != null, "generated Reload button lives in Actions")
	_assert(reload_button != null and reload_button.get_index() == 0, "generated button precedes Copy/Close")

	if reload_button:
		reload_button.pressed.emit()
	_assert(reload_calls[0] == 1, "generated button's callback runs on pressed")

	var copy_button: Button = _popup.get_node("MarginContainer/VBoxContainer/Actions/CopyButton")
	_assert(copy_button.text == "Copy", "Copy button text is reset to Copy")
	var last_button := actions.get_child(actions.get_child_count() - 1) as Button
	_assert(last_button != null and last_button.text == "Close", "Close is the last button")

	copy_button.pressed.emit()
	_assert(copy_button.text == "Copied", "Copy button reflects that it copied")

	# A second call must free the buttons the first one generated.
	_popup.show_message("Second", "body", [])
	await process_frame
	_assert(_popup.last_title == "Second", "second show_message updates the title")
	_assert(actions.get_child_count() == 2, "previously generated buttons are freed")
