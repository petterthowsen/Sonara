# Saves a device (and its subtree) as a preset: Name, Tags (comma-separated) and Author. The author
# is remembered in config (`presets/author`). Saving over an existing preset asks first; a CLAP
# plugin that doesn't answer the state request in time offers to save with its last known state.
# Scene: DevicePresetSaveDialog.tscn.
class_name DevicePresetSaveDialog extends Window

const AUTHOR_KEY := "presets/author"

## A preset was written; `inst`'s preset name and path now point at it.
signal preset_saved(preset_name: String, path: String)

@onready var _name_edit: LineEdit = %NameEdit
@onready var _tags_edit: LineEdit = %TagsEdit
@onready var _author_edit: LineEdit = %AuthorEdit
@onready var _status: Label = %Status
@onready var _save_button: Button = %SaveButton
@onready var _cancel_button: Button = %CancelButton
@onready var _overwrite_confirm: ConfirmationDialog = %OverwriteConfirm
@onready var _state_confirm: ConfirmationDialog = %StateConfirm

var _device: DeviceInstance = null
var _pending: DevicePreset = null
var _busy := false
var _logger := Log.make("DevicePresetSaveDialog")


func _ready() -> void:
	close_requested.connect(hide)
	_name_edit.text_changed.connect(func(_t): _update_save_enabled())
	_save_button.pressed.connect(_on_save_pressed)
	_cancel_button.pressed.connect(hide)
	_overwrite_confirm.confirmed.connect(func(): _capture_and_write(true))
	_state_confirm.confirmed.connect(_write_pending)
	_state_confirm.canceled.connect(_finish_busy)
	hide()


## Show the dialog for `inst`. With `keep_preset`, name and tags start from the preset it came from
## so saving updates that file; otherwise the name starts from the device's name.
func open_for(inst: DeviceInstance, keep_preset: bool = true) -> void:
	_device = inst
	_pending = null
	_busy = false
	var preset_name := inst.get_display_name()
	var tags := ""
	if keep_preset and not inst.preset_name.is_empty():
		preset_name = inst.preset_name
		var header := DevicePreset.read_header(inst.preset_path) if not inst.preset_path.is_empty() else null
		if header != null:
			tags = ", ".join(header.tags)
	_name_edit.text = preset_name
	_tags_edit.text = tags
	_author_edit.text = str(Sonara.get_config(AUTHOR_KEY, ""))
	_status.text = ""
	_update_save_enabled()
	popup_centered()
	_name_edit.grab_focus()
	_name_edit.select_all()


func _update_save_enabled() -> void:
	var name_value := _name_edit.text.strip_edges()
	_save_button.disabled = _busy or name_value.is_empty()
	if _busy:
		return
	if name_value.is_empty():
		_status.text = "A name is required."
	elif _device and PresetLibrary.exists(_device.device.name, name_value):
		_status.text = "'%s' already exists and will be overwritten." % name_value
	else:
		_status.text = ""


func _on_save_pressed() -> void:
	var name_value := _name_edit.text.strip_edges()
	if name_value.is_empty() or _device == null or _busy:
		return
	if PresetLibrary.exists(_device.device.name, name_value):
		_overwrite_confirm.dialog_text = "A preset named '%s' already exists for %s. Overwrite it?" % [name_value, _device.device.name]
		_overwrite_confirm.popup_centered()
		return
	_capture_and_write(false)


func _capture_and_write(overwrite: bool) -> void:
	_busy = true
	_status.text = "Saving…"
	_update_save_enabled()
	var author := _author_edit.text.strip_edges()
	_pending = await DevicePreset.capture(_device, _name_edit.text.strip_edges(), author, _tags_edit.text)
	if not _pending.state_complete:
		_state_confirm.popup_centered()
		return
	_write_pending(overwrite)


func _write_pending(overwrite: bool = true) -> void:
	if _pending == null or _device == null:
		_finish_busy()
		return
	var path := PresetLibrary.save(_pending, overwrite)
	if path.is_empty():
		_status.text = "Could not save '%s'." % _pending.name
		_logger.warn("save refused for '%s'" % _pending.name)
		_finish_busy()
		return
	Sonara.set_config(AUTHOR_KEY, _pending.author)
	Sonara.save_config()
	_device.set_preset(_pending.name, path)
	var saved_name := _pending.name
	_finish_busy()
	preset_saved.emit(saved_name, path)
	hide()


func _finish_busy() -> void:
	_busy = false
	_pending = null
	_update_save_enabled()
