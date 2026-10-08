# SelectionStateCommand.gd
# Restores a note editor's selection (the time range and the selected notes) around an edit.
# The selection is not part of the document, so this never makes a history entry by itself:
# it joins the ClipNotesStateCommands of an edit that also changed the selection.
#
# Undo runs a macro's children in reverse, and the selected notes must exist again before they
# can be selected, so one edit records two of these: `restore_on_undo` ones go first in the
# macro (their undo runs last) and the others go last (their do runs last).
class_name SelectionStateCommand extends Command

var editor: NoteEditor = null
## Selection before and after the edit, as captured by NoteEditor.capture_selection_state().
var before_state: Dictionary = {}
var after_state: Dictionary = {}
var restore_on_undo := false


func _init(p_name: String = "Selection", p_editor: NoteEditor = null,
		p_before: Dictionary = {}, p_after: Dictionary = {}, p_restore_on_undo := false) -> void:
	name = p_name
	editor = p_editor
	before_state = p_before
	after_state = p_after
	restore_on_undo = p_restore_on_undo


func do() -> void:
	if not restore_on_undo and is_instance_valid(editor):
		editor.restore_selection_state(after_state)


func undo() -> void:
	if restore_on_undo and is_instance_valid(editor):
		editor.restore_selection_state(before_state)
