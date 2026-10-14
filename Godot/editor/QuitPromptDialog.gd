# QuitPromptDialog.gd
# "Save changes before closing?" dialog with Save / Save As / Cancel. Built in code; ask() resolves
# with a QuitGuard.Choice. Closing the window or Escape counts as Cancel.
class_name QuitPromptDialog extends ConfirmationDialog

signal chosen(choice: int)

const ACTION_SAVE_AS := "save_as"

var _done := false


func _init() -> void:
	title = "Unsaved changes"
	dialog_text = "The project has unsaved changes. Save them before closing?"
	ok_button_text = "Save"
	cancel_button_text = "Cancel"
	add_button("Save As", false, ACTION_SAVE_AS)
	exclusive = true
	confirmed.connect(_finish.bind(QuitGuard.Choice.SAVE))
	canceled.connect(_finish.bind(QuitGuard.Choice.CANCEL))
	custom_action.connect(_on_custom_action)


func _on_custom_action(action: StringName) -> void:
	if action == ACTION_SAVE_AS:
		_finish(QuitGuard.Choice.SAVE_AS)


func _finish(choice: int) -> void:
	if _done:
		return
	_done = true
	hide()
	chosen.emit(choice)


## Shows the dialog and waits for the user's choice. Never shows in test mode (returns CANCEL).
func ask() -> int:
	if Utils.is_test_mode():
		return QuitGuard.Choice.CANCEL
	_done = false
	popup_centered()
	return await chosen
