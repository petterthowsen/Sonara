# test_quit_guard.gd
# Issue #120: closing the app with unsaved changes asks Save / Save As / Cancel. Covers the
# decision logic only (QuitGuard); the dialog and file I/O are never touched.
extends TestBase

var _saves := 0
var _save_ases := 0


func suite_name() -> String:
	return "Quit guard"


func run_tests() -> void:
	_test_needs_prompt()
	await _test_save()
	await _test_save_as()
	await _test_cancel_and_dialog_guard()


func _save_ok() -> bool:
	_saves += 1
	return true


func _save_fail() -> bool:
	_saves += 1
	return false


func _save_as(result: int) -> int:
	_save_ases += 1
	return result


func _resolve(choice: int, has_path: bool, save_ok: bool, save_as_result: int) -> int:
	_saves = 0
	_save_ases = 0
	return await QuitGuard.resolve(choice, has_path,
			_save_ok if save_ok else _save_fail, _save_as.bind(save_as_result))


func _test_needs_prompt() -> void:
	_assert(QuitGuard.needs_prompt(true, true), "dirty project prompts")
	_assert(not QuitGuard.needs_prompt(true, false), "clean project closes without asking")
	_assert(not QuitGuard.needs_prompt(false, true), "no project closes without asking")
	_assert(not QuitGuard.needs_prompt(false, false), "nothing open closes without asking")


func _test_save() -> void:
	var o: int = await _resolve(QuitGuard.Choice.SAVE, true, true, QuitGuard.SaveAsResult.OK)
	_assert(o == QuitGuard.Outcome.QUIT and _saves == 1 and _save_ases == 0, "Save with a path saves then quits")
	o = await _resolve(QuitGuard.Choice.SAVE, true, false, QuitGuard.SaveAsResult.OK)
	_assert(o == QuitGuard.Outcome.STAY, "failed Save keeps the app open")
	o = await _resolve(QuitGuard.Choice.SAVE, false, true, QuitGuard.SaveAsResult.OK)
	_assert(o == QuitGuard.Outcome.QUIT and _saves == 0 and _save_ases == 1, "Save without a path goes through Save As")
	o = await _resolve(QuitGuard.Choice.SAVE, false, true, QuitGuard.SaveAsResult.CANCELLED)
	_assert(o == QuitGuard.Outcome.REPROMPT, "Save without a path, dialog cancelled: back to the prompt")


func _test_save_as() -> void:
	var o: int = await _resolve(QuitGuard.Choice.SAVE_AS, true, true, QuitGuard.SaveAsResult.OK)
	_assert(o == QuitGuard.Outcome.QUIT and _saves == 0 and _save_ases == 1, "Save As success quits")
	o = await _resolve(QuitGuard.Choice.SAVE_AS, true, true, QuitGuard.SaveAsResult.CANCELLED)
	_assert(o == QuitGuard.Outcome.REPROMPT, "cancelled Save As returns to the prompt")
	o = await _resolve(QuitGuard.Choice.SAVE_AS, true, true, QuitGuard.SaveAsResult.FAILED)
	_assert(o == QuitGuard.Outcome.STAY, "failed Save As keeps the app open")


func _test_cancel_and_dialog_guard() -> void:
	var o: int = await _resolve(QuitGuard.Choice.CANCEL, true, true, QuitGuard.SaveAsResult.OK)
	_assert(o == QuitGuard.Outcome.STAY and _saves == 0 and _save_ases == 0, "Cancel keeps the app open and saves nothing")
	var dialog := QuitPromptDialog.new()
	var c: int = await dialog.ask()
	_assert(c == QuitGuard.Choice.CANCEL, "dialog never shows in test mode")
	dialog.free()
