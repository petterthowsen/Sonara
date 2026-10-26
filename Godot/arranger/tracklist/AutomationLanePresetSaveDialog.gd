# AutomationLanePresetSaveDialog.gd
# Names and saves the shown lanes of a track as an automation lane preset (spec 055 REQ-021).
# An empty name is refused; an existing name asks through %OverwriteConfirm first.
# Scene: AutomationLanePresetSaveDialog.tscn.
class_name AutomationLanePresetSaveDialog extends Window

## A preset was written under `preset_name`.
signal preset_saved(preset_name: String)

# Preloaded, not named bare: a class_name script missing from the cache fails to parse headless.
const _Actions := preload("res://history/AutomationLanePresetActions.gd")
const _Presets := preload("res://data/AutomationLanePresets.gd")

@onready var _name_edit: LineEdit = %NameEdit
@onready var _status: Label = %StatusLabel
@onready var _save_button: Button = %SaveButton
@onready var _cancel_button: Button = %CancelButton
@onready var _overwrite_confirm: ConfirmationDialog = %OverwriteConfirm

var _view: Object = null
var _track: Object = null
var _logger := Log.make("AutomationLanePresetSaveDialog")


func _ready() -> void:
	close_requested.connect(hide)
	_name_edit.text_changed.connect(func(_t): _update_state())
	_name_edit.text_submitted.connect(func(_t): _on_save_pressed())
	_save_button.pressed.connect(_on_save_pressed)
	_cancel_button.pressed.connect(hide)
	_overwrite_confirm.confirmed.connect(func(): save_named(_name_edit.text, true))
	hide()


## Show the dialog for the lanes `view` shows on `track`.
func open_for(view: Object, track: Object) -> void:
	_view = view
	_track = track
	_name_edit.text = ""
	_update_state()
	popup_centered()
	_name_edit.grab_focus()


## Save the shown lanes as `preset_name`. Returns false when the name is empty, nothing is shown,
## the name exists and `overwrite` is false, or the file can't be written.
func save_named(preset_name: String, overwrite: bool) -> bool:
	var clean := preset_name.strip_edges()
	if clean.is_empty():
		_status.text = "A name is required."
		return false
	if not _Actions.save(_view, _track, clean, overwrite):
		if _Presets.exists(clean) and not overwrite:
			_status.text = "'%s' already exists." % clean
		else:
			_status.text = "Could not save '%s'." % clean
			_logger.warn("save refused for '%s'" % clean)
		return false
	preset_saved.emit(clean)
	hide()
	return true


func _update_state() -> void:
	var clean := _name_edit.text.strip_edges()
	_save_button.disabled = clean.is_empty()
	if clean.is_empty():
		_status.text = "A name is required."
	elif _Presets.exists(clean):
		_status.text = "'%s' already exists." % clean
	else:
		_status.text = ""


func _on_save_pressed() -> void:
	var clean := _name_edit.text.strip_edges()
	if clean.is_empty():
		return
	if _Presets.exists(clean):
		_overwrite_confirm.dialog_text = "A lane preset named '%s' exists. Overwrite it?" % clean
		_overwrite_confirm.popup_centered()
		return
	save_named(clean, false)
