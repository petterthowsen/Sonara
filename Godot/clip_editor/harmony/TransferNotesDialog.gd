## Options of Transfer Notes (spec 048, REQ-040, REQ-043): the target track, and a warning when
## the notes would land in a clip that other instances share. The last target is remembered
## (REQ-004), as is the "Keep original notes" toggle (`keep_check`). Confirming emits `applied`;
## ClipEditor runs NoteEditor.transfer_selection.
class_name TransferNotesDialog extends ConfirmationDialog

## The user confirmed with this target track.
signal applied(target: Track)

## The target tracks as the arranger's hierarchy: groups fold, the edited track is highlighted.
var target_tree: Tree
var keep_check: CheckBox
var warning_label: Label
var prompt_label: Label

var _editor: NoteEditor = null
## Selectable targets in arranger order.
var _targets: Array[Track] = []
## Track -> TreeItem, for every listed row (targets, the edited track and non-selectable parents).
var _items: Dictionary = {}

const TREE_SIZE := Vector2(300, 200)
const DIALOG_SIZE := Vector2i(340, 420)
const EDITING_COLOR := Color(1, 1, 1, 0.14)


func _init() -> void:
	title = "Transfer Notes"
	# Fixed size (see DIALOG_SIZE) instead of growing to whatever the content asks for.
	wrap_controls = false
	min_size = Vector2i(DIALOG_SIZE.x, 300)
	ok_button_text = "Transfer"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size.x = TREE_SIZE.x
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(box)
	prompt_label = Label.new()
	prompt_label.text = "Move the selected notes to the same positions on:"
	box.add_child(prompt_label)
	target_tree = Tree.new()
	target_tree.hide_root = true
	target_tree.select_mode = Tree.SELECT_SINGLE
	target_tree.custom_minimum_size = TREE_SIZE
	target_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	target_tree.tooltip_text = "Notes go into the clips there, which grow to whole bars if needed, or into new clips."
	target_tree.item_selected.connect(_update_warning)
	target_tree.item_activated.connect(func(): get_ok_button().pressed.emit())
	box.add_child(target_tree)
	keep_check = CheckBox.new()
	keep_check.text = "Keep original notes"
	keep_check.tooltip_text = "Copy the notes instead of moving them: they also stay on the edited track."
	keep_check.button_pressed = bool(NoteEditor._config_value(NoteEditor.TRANSFER_KEEP_KEY, false))
	box.add_child(keep_check)
	warning_label = Label.new()
	warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# An autowrapping label with no width asks for an enormous height; give it one.
	warning_label.custom_minimum_size.x = TREE_SIZE.x
	warning_label.add_theme_color_override("font_color", Color(0.95, 0.75, 0.35))
	warning_label.visible = false
	box.add_child(warning_label)
	confirmed.connect(_on_confirmed)


## Show the dialog for `editor`. The target defaults to the first selected track that can receive
## the notes (`selected_tracks`, empty = the app's track selection), otherwise the last target.
func open_for(editor: NoteEditor, selected_tracks: Array = []) -> void:
	_editor = editor
	_targets.clear()
	_items.clear()
	target_tree.clear()
	var project := editor._project_of_editor()
	if project:
		_build_rows(project)
	var pick := default_target_index(selected_tracks)
	if pick >= 0:
		select_target(_targets[pick])
	_reveal_editing_track()
	get_ok_button().disabled = _targets.is_empty()
	_update_warning()
	popup_centered(DIALOG_SIZE)


## Rows for the tracks in arranger order. A track is listed when it can take the notes, is the
## edited track, or holds such a track (a folder or group stays as a non-selectable parent).
func _build_rows(project: Project) -> void:
	var source := _editor.source_track()
	var listed := {}
	for t in project.get_visual_track_list():
		if t == source or _editor.is_transfer_target(t):
			var at := t
			while at != null and not listed.has(at):
				listed[at] = true
				at = project.get_track_by_id(at.parent_track_id) if at.parent_track_id >= 0 else null
	var root := target_tree.create_item()
	for t in project.get_visual_track_list():
		if not listed.has(t):
			continue
		var parent: TreeItem = _items.get(project.get_track_by_id(t.parent_track_id), root) \
				if t.parent_track_id >= 0 else root
		var item := target_tree.create_item(parent)
		item.set_text(0, t.name)
		item.set_metadata(0, t)
		_items[t] = item
		var is_target := _editor.is_transfer_target(t)
		item.set_selectable(0, is_target)
		if is_target:
			_targets.append(t)
		else:
			item.set_custom_color(0, Color(1, 1, 1, 0.5))
		if t == source:
			item.set_text(0, "%s (editing)" % t.name)
			item.set_custom_bg_color(0, EDITING_COLOR)
		item.collapsed = not t.is_folder_expanded and t.can_contain_tracks()


## Unfold the parents of the edited track and of the selected target, and scroll to the edited track.
func _reveal_editing_track() -> void:
	var source := _editor.source_track()
	for t in [source, selected_target()]:
		var item: TreeItem = _items.get(t)
		var up: TreeItem = item.get_parent() if item else null
		while up != null:
			up.collapsed = false
			up = up.get_parent()
	var focus: TreeItem = _items.get(source)
	if focus:
		target_tree.scroll_to_item.call_deferred(focus)


## Select `track`'s row (a target); the warning follows.
func select_target(track: Track) -> void:
	var item: TreeItem = _items.get(track)
	if item and item.is_selectable(0):
		item.select(0)
		target_tree.scroll_to_item(item)


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
	var item := target_tree.get_selected()
	var t: Variant = item.get_metadata(0) if item else null
	return t if t is Track and _targets.has(t) else null


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
	NoteEditor.store_config(NoteEditor.TRANSFER_KEEP_KEY, keep_check.button_pressed)
	applied.emit(target)
