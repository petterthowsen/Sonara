# QuitGuard.gd
# Decision logic for closing the app with unsaved changes (issue #120). No UI and no file I/O:
# the dialog and the save flows are injected as Callables so this can be unit tested.
class_name QuitGuard extends RefCounted

## What the user picked in the unsaved-changes dialog.
enum Choice { SAVE, SAVE_AS, CANCEL }
## Result of an interactive Save As.
enum SaveAsResult { OK, FAILED, CANCELLED }
## What the app does after a choice has been carried out.
enum Outcome { QUIT, STAY, REPROMPT }


## True when closing needs the Save / Save As / Cancel dialog.
static func needs_prompt(project_open: bool, is_modified: bool) -> bool:
	return project_open and is_modified


## Carries out `choice`.
## `save_cb: Callable() -> bool` saves to the current path (may be a coroutine).
## `save_as_cb: Callable() -> SaveAsResult` runs the Save As flow (may be a coroutine).
## `has_path`: false for a project with no file yet (or the protected startup project), where
## Save has to go through Save As, like File > Save does.
## QUIT only after a successful save; a failed save stays open (the error is shown by the save flow);
## a cancelled Save As goes back to the dialog.
static func resolve(choice: int, has_path: bool, save_cb: Callable, save_as_cb: Callable) -> int:
	match choice:
		Choice.SAVE:
			if has_path:
				var ok: bool = await save_cb.call()
				return Outcome.QUIT if ok else Outcome.STAY
			return await _run_save_as(save_as_cb)
		Choice.SAVE_AS:
			return await _run_save_as(save_as_cb)
	return Outcome.STAY


static func _run_save_as(save_as_cb: Callable) -> int:
	var result: int = await save_as_cb.call()
	match result:
		SaveAsResult.OK:
			return Outcome.QUIT
		SaveAsResult.CANCELLED:
			return Outcome.REPROMPT
	return Outcome.STAY
