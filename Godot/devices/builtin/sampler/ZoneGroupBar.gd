## The multisample editor's group filter bar (spec 023, REQ-041, REQ-025, REQ-031, REQ-032): an
## "All" button, "Ungrouped" and one `ZoneGroupChip` per group, then "+" to add a group. A click
## shows only that group, Ctrl-click adds or removes it. M and S mute and solo a group. A
## right-click offers Rename, Delete, Play Mode and Gain. The layout lives in `ZoneGroupBar.tscn`.
##
## Every edit is one undo step through `SamplerActions`; the gain popup records one step when it
## closes.
class_name ZoneGroupBar extends HBoxContainer

const CHIP_SCENE := preload("res://devices/builtin/sampler/ZoneGroupChip.tscn")
enum MenuId { RENAME, DELETE, PLAY_MODE, GAIN }

@onready var chips: HBoxContainer = %Chips
@onready var add_button: Button = %AddButton
@onready var snap_button: Button = %SnapButton
@onready var group_menu: PopupMenu = %GroupMenu
@onready var play_mode_menu: PopupMenu = %PlayModeMenu
@onready var gain_popup: PopupPanel = %GainPopup
@onready var gain_knob: LabeledKnob = %GainKnob

var editor: MultisampleEditor = null

## The group the open menu or gain popup is for.
var _menu_group := 0
var _gain_state := {}
var _links: Array = []


func _ready() -> void:
	group_menu.add_submenu_node_item("Play Mode", play_mode_menu, MenuId.PLAY_MODE)
	group_menu.add_item("Gain…", MenuId.GAIN)
	group_menu.id_pressed.connect(_on_menu_id)
	play_mode_menu.id_pressed.connect(_on_play_mode_chosen)
	add_button.pressed.connect(func() -> void:
		if editor and editor.device:
			SamplerActions.add_group(editor.device))
	snap_button.toggled.connect(func(on: bool) -> void:
		if editor:
			editor.set_snap(on))
	var knob := gain_knob.knob
	knob.min_value = 0.0
	knob.max_value = 2.0
	knob.value_default = 1.0
	knob.value_text_callback = ZoneStrip.knob_text.bind("Gain")
	knob.value_changed.connect(_on_gain_changed)
	knob.reset_requested.connect(func() -> void: knob.value = 1.0)
	gain_popup.popup_hide.connect(_on_gain_popup_hidden)


func bind(p_editor: MultisampleEditor) -> void:
	unbind()
	editor = p_editor
	_link(editor.model.groups_changed, rebuild)
	_link(editor.visible_groups_changed, rebuild)
	_link(editor.snap_changed, _sync_snap)
	_sync_snap()
	rebuild()

## Connect `fn` to `sig` until `unbind()`.
func _link(sig: Signal, fn: Callable) -> void:
	sig.connect(fn)
	_links.append([sig, fn])


func unbind() -> void:
	for link in _links:
		if (link[0] as Signal).is_connected(link[1]):
			(link[0] as Signal).disconnect(link[1])
	_links.clear()
	editor = null


func _sync_snap() -> void:
	snap_button.set_pressed_no_signal(editor.snap_enabled)


func model() -> SamplerMultisample:
	return editor.model if editor else null


## Recreate the chips from the model and the editor's visible groups.
func rebuild() -> void:
	for child in chips.get_children():
		chips.remove_child(child)
		child.queue_free()
	var m := model()
	if m == null:
		return
	var shown := editor.visible_groups
	_add_chip(MultisampleEditor.ALL_GROUPS, "All", shown.is_empty(), null)
	_add_chip(SamplerZoneGroup.UNGROUPED_ID, SamplerZoneGroup.UNGROUPED_NAME, shown.has(0), m.ungrouped)
	for group in m.groups:
		_add_chip(group.id, group.name, shown.has(group.id), group)


func _add_chip(group_id: int, text: String, active: bool, group: SamplerZoneGroup) -> void:
	var chip: ZoneGroupChip = CHIP_SCENE.instantiate()
	chips.add_child(chip)
	chip.setup(group_id, text, active, group)
	chip.clicked.connect(func(additive: bool) -> void: click_group(group_id, additive))
	chip.context_requested.connect(func(at: Vector2) -> void: open_group_menu(group_id, at))
	chip.mute_toggled.connect(func(on: bool) -> void: _set_group(group_id, {"mute": on}))
	chip.solo_toggled.connect(func(on: bool) -> void: _set_group(group_id, {"solo": on}))
	chip.name_committed.connect(func(new_name: String) -> void:
		SamplerActions.rename_group(editor.device, group_id, new_name))


## The chip for `group_id` (`MultisampleEditor.ALL_GROUPS` for "All"), or null.
func chip_for(group_id: int) -> ZoneGroupChip:
	for chip in chips.get_children():
		if chip is ZoneGroupChip and chip.group_id == group_id and not chip.is_queued_for_deletion():
			return chip
	return null


## A filter click (also what the tests call).
func click_group(group_id: int, additive: bool = false) -> void:
	if editor:
		editor.filter_group(group_id, additive)


func _set_group(group_id: int, values: Dictionary) -> void:
	if editor and editor.device:
		SamplerActions.set_group_fields(editor.device, group_id, values)


# --- group menu ------------------------------------------------------------

func open_group_menu(group_id: int, screen_position: Vector2) -> void:
	if group_id == MultisampleEditor.ALL_GROUPS or model() == null:
		return
	fill_group_menu(group_id)
	group_menu.popup(Rect2i(Vector2i(screen_position), Vector2i.ZERO))


func fill_group_menu(group_id: int) -> void:
	_menu_group = group_id
	var ungrouped := group_id == SamplerZoneGroup.UNGROUPED_ID
	group_menu.set_item_disabled(group_menu.get_item_index(MenuId.RENAME), ungrouped)
	group_menu.set_item_disabled(group_menu.get_item_index(MenuId.DELETE), ungrouped)
	var play_mode := model().get_group(group_id).play_mode
	for i in play_mode_menu.item_count:
		play_mode_menu.set_item_checked(i, play_mode_menu.get_item_id(i) == play_mode)


func _on_menu_id(id: int) -> void:
	if editor == null or editor.device == null:
		return
	match id:
		MenuId.RENAME:
			var chip := chip_for(_menu_group)
			if chip:
				chip.begin_rename()
		MenuId.DELETE:
			SamplerActions.remove_group(editor.device, _menu_group)
		MenuId.GAIN:
			open_gain_popup(_menu_group)


func _on_play_mode_chosen(play_mode: int) -> void:
	_set_group(_menu_group, {"play_mode": play_mode})


# --- gain popup ------------------------------------------------------------

## Edit a group's gain with a knob; the whole popup session is one undo step.
func open_gain_popup(group_id: int) -> void:
	_menu_group = group_id
	_gain_state = SamplerActions.begin_edit(editor.device)
	gain_knob.text = model().get_group(group_id).display_name()
	gain_knob.knob.set_value_no_signal(model().get_group(group_id).gain)
	var chip := chip_for(group_id)
	var at := chip.get_screen_position() + Vector2(0, chip.size.y) if chip else get_screen_position()
	gain_popup.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


func _on_gain_changed(value: float) -> void:
	if editor and editor.model and not _gain_state.is_empty():
		editor.model.set_group_fields(_menu_group, {"gain": value})


func _on_gain_popup_hidden() -> void:
	if editor and editor.device and not _gain_state.is_empty():
		SamplerActions.end_edit(editor.device, "Group Gain", _gain_state)
	_gain_state = {}
