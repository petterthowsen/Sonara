## Options of Transfer Notes (spec 048, REQ-040, REQ-043): the target track, and a warning when
## the notes would land in a clip that other instances share. The last target is remembered
## (REQ-004). Confirming emits `applied`; ClipEditor runs NoteEditor.transfer_selection.
class_name TransferNotesDialog extends ConfirmationDialog

## The user confirmed with this target track.
signal applied(target: Track)

var target_option: OptionButton
var warning_label: Label
var prompt_label: Label

var _editor: NoteEditor = null
## Option index -> Track.
var _targets: Array[Track] = []


func _init() -> void:
	title = "Transfer Notes"
	ok_button_text = "Transfer"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size.x = 340
	add_child(box)
	prompt_label = Label.new()
	prompt_label.text = "Move the selected notes to the same positions on:"
	box.add_child(prompt_label)
	target_option = OptionButton.new()
	target_option.tooltip_text = "Notes go into the clips there, which grow to whole bars if needed, or into new clips."
	target_option.item_selected.connect(func(_i: int): _update_warning())
	box.add_child(target_option)
	warning_label = Label.new()
	warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warning_label.add_theme_color_override("font_color", Color(0.95, 0.75, 0.35))
	warning_label.visible = false
	box.add_child(warning_label)
	confirmed.connect(_on_confirmed)


## Show the dialog for `editor`. The target defaults to the first selected track that can receive
## the notes (`selected_tracks`, empty = the app's track selection), otherwise the last target.
func open_for(editor: NoteEditor, selected_tracks: Array = []) -> void:
	_editor = editor
	_targets.clear()
	target_option.clear()
	var project := editor._project_of_editor()
	if project:
		for t in project.tracks:
			if editor.is_transfer_target(t):
				_targets.append(t)
				target_option.add_item(t.name)
	var pick := default_target_index(selected_tracks)
	if pick >= 0:
		target_option.select(pick)
	get_ok_button().disabled = _targets.is_empty()
	_update_warning()
	popup_centered()


## The option to preselect: the selected track if it is not the source, otherwise the last
## target (when it still exists), otherwise the first. -1 with no targets.
func default_target_index(selected_tracks: Array = []) -> int:
	if _targets.is_empty():
		return -1
	for t in _editor.split_target_tracks(selected_tracks):
		var at := _targets.find(t)
		if at >= 0:
			return at
	var last_id := int(NoteEditor._config_value(NoteEditor.TRANSFER_TARGET_KEY, -1))
	for i in _targets.size():
		if _targets[i].id == last_id:
			return i
	return 0


func selected_target() -> Track:
	var i := target_option.selected
	return _targets[i] if i >= 0 and i < _targets.size() else null


func _update_warning() -> void:
	var target := selected_target()
	var linked: Array = _editor.transfer_linked_clips(target) if _editor and target else []
	warning_label.visible = not linked.is_empty()
	if linked.is_empty():
		warning_label.text = ""
		return
	var names := PackedStringArray()
	for c: Clip in linked:
		names.append("\"%s\"" % c.name)
	warning_label.text = "%s linked to other instances. The notes will appear in every linked instance." \
			% ("Clip %s is" % names[0] if names.size() == 1 else "Clips %s are" % ", ".join(names))


func _on_confirmed() -> void:
	var target := selected_target()
	if target == null:
		return
	NoteEditor.store_config(NoteEditor.TRANSFER_TARGET_KEY, target.id)
	applied.emit(target)
