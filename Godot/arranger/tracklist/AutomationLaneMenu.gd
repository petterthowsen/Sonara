# AutomationLaneMenu.gd
# Dropdown opened from a track header's automation button (REQ-014): one checkbox per existing
# lane driving the view's shown state (`lane.visible` in the Arranger, the open-lane list in the
# MIDI editor, spec 055), plus a `+ Add new` entry that opens the parameter picker.
#
# Below the lanes a `Presets` section (spec 055) lists the user's lane presets, offers
# `Save shown lanes as preset…` and a `Delete preset` submenu. The store is re-read on every
# rebuild. Loading, saving and deleting go through `AutomationLanePresetActions` with the view.
#
# Unchecking a lane only hides its row - the lane, its points and its effect on the engine are
# untouched. That is deliberately different from the header's delete button.
class_name AutomationLaneMenu extends PopupMenu

signal add_lane_requested(track: Track)

const ADD_NEW_ID := 1 << 20  # PopupMenu auto-assigns ids for negative values, so keep this positive.

const SAVE_PRESET_ID := ADD_NEW_ID + 1
const PRESET_BASE_ID := 1 << 21

const _ArrangerLaneView := preload("res://arranger/tracklist/ArrangerLaneView.gd")
const _Actions := preload("res://history/AutomationLanePresetActions.gd")
const _Presets := preload("res://data/AutomationLanePresets.gd")
const _SaveDialogScene := preload("res://arranger/tracklist/AutomationLanePresetSaveDialog.tscn")

var track: Track = null
## Decides what "shown" means for the check items (an AutomationLaneView).
var view: Object = null
var _lanes: Array[AutomationLane] = []
var _preset_names: Array[String] = []
var _delete_menu: PopupMenu = null
var _save_dialog: Window = null
var _delete_confirm: ConfirmationDialog = null
var _pending_delete := ""


func _ready() -> void:
	theme_type_variation = &"ContextMenuList"
	hide_on_checkable_item_selection = false
	if not id_pressed.is_connected(_on_id_pressed):
		id_pressed.connect(_on_id_pressed)


## Rebuild the menu for `p_track` and pop it up at `global_position`.
func open_for(p_track: Track, global_position: Vector2, p_view: Object = null) -> void:
	track = p_track
	view = p_view if p_view != null else _ArrangerLaneView.new()
	_rebuild()
	ContextMenuPopup.popup_at_point(self, global_position)


func _rebuild() -> void:
	if view == null:
		view = _ArrangerLaneView.new()
	clear()
	_lanes.clear()
	if track == null:
		return

	for lane in track.automation_lanes:
		if lane == null:
			continue
		var index := _lanes.size()
		_lanes.append(lane)
		var channel: Channel = track.get_linked_channel()
		var label := lane.target.display_name(channel) if lane.target else "Unknown"
		if not lane.resolved:
			label = "%s (missing)" % label
		add_check_item(label, index)
		set_item_checked(get_item_index(index), view.is_shown(track, lane))

	if not _lanes.is_empty():
		add_separator()
	add_item("+ Add new", ADD_NEW_ID)
	_add_presets_section()


## `Presets` section: one item per stored preset, save, and a delete submenu.
func _add_presets_section() -> void:
	_preset_names = _Presets.names()
	add_separator("Presets")
	for i in range(_preset_names.size()):
		add_item(_preset_names[i], PRESET_BASE_ID + i)
	add_item("Save shown lanes as preset…", SAVE_PRESET_ID)
	set_item_disabled(get_item_index(SAVE_PRESET_ID), view.shown_lanes(track).is_empty())

	if _delete_menu == null:
		_delete_menu = PopupMenu.new()
		_delete_menu.name = "DeletePresetMenu"
		_delete_menu.theme_type_variation = &"ContextMenuList"
		_delete_menu.id_pressed.connect(_on_delete_preset_pressed)
		add_child(_delete_menu)
	_delete_menu.clear()
	for i in range(_preset_names.size()):
		_delete_menu.add_item(_preset_names[i], PRESET_BASE_ID + i)
	add_submenu_node_item("Delete preset", _delete_menu)
	set_item_disabled(item_count - 1, _preset_names.is_empty())


func _on_id_pressed(id: int) -> void:
	if id == ADD_NEW_ID:
		ContextMenuPopup.close(self)
		add_lane_requested.emit(track)
		return
	if id == SAVE_PRESET_ID:
		_open_save_dialog()
		return
	if id >= PRESET_BASE_ID:
		_load_preset(id - PRESET_BASE_ID)
		return
	if id < 0 or id >= _lanes.size():
		return
	var lane := _lanes[id]
	var on: bool = not view.is_shown(track, lane)
	view.set_shown(track, lane, on)
	set_item_checked(get_item_index(id), view.is_shown(track, lane))


## Show only the preset's lanes (one undo step) and tell the user which entries were skipped.
func _load_preset(index: int) -> void:
	if track == null or index < 0 or index >= _preset_names.size():
		return
	var preset: Dictionary = _Presets.get_preset(_preset_names[index])
	if preset.is_empty():
		return
	var skipped: Array = _Actions.load(view, track, preset)
	if skipped.is_empty():
		return
	var labels: Array[String] = []
	for entry in skipped:
		labels.append(str(entry.get("label", entry.get("target", "?"))))
	var body := "Skipped, not available on this track:\n" + "\n".join(labels)
	if Sonara and Sonara.editor:
		Sonara.editor.show_error("Lane preset '%s'" % preset["name"], body)


## Dialogs live beside the menu, not under it: a popup menu closes when its item is chosen.
func _dialog_host() -> Node:
	return get_parent() if get_parent() != null else self


func _open_save_dialog() -> void:
	if _save_dialog == null:
		_save_dialog = _SaveDialogScene.instantiate()
		_dialog_host().add_child(_save_dialog)
	_save_dialog.open_for(view, track)


func _on_delete_preset_pressed(id: int) -> void:
	var index := id - PRESET_BASE_ID
	if index < 0 or index >= _preset_names.size():
		return
	_pending_delete = _preset_names[index]
	if _delete_confirm == null:
		_delete_confirm = ConfirmationDialog.new()
		_delete_confirm.title = "Delete Lane Preset"
		_delete_confirm.ok_button_text = "Delete"
		_delete_confirm.confirmed.connect(_on_delete_confirmed)
		_dialog_host().add_child(_delete_confirm)
	_delete_confirm.dialog_text = "Delete lane preset '%s'? Lanes on tracks are not affected." % _pending_delete
	_delete_confirm.popup_centered()


func _on_delete_confirmed() -> void:
	if not _pending_delete.is_empty():
		_Actions.delete(_pending_delete)
	_pending_delete = ""


func _exit_tree() -> void:
	# Dialogs hosted by the parent would otherwise outlive the menu.
	for dialog in [_save_dialog, _delete_confirm]:
		if dialog != null and is_instance_valid(dialog) and dialog.get_parent() != self:
			dialog.queue_free()
