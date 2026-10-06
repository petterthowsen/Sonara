## One button of the zone group bar (spec 023, REQ-041): the group's name as a filter toggle and,
## for real groups and Ungrouped, its mute and solo toggles. Renaming edits the name in place.
## The layout lives in `ZoneGroupChip.tscn`; `ZoneGroupBar` makes one per group.
class_name ZoneGroupChip extends HBoxContainer

## Left click on the name. `additive` is true for Ctrl-click.
signal clicked(additive: bool)
signal context_requested(screen_position: Vector2)
signal mute_toggled(on: bool)
signal solo_toggled(on: bool)
signal name_committed(new_name: String)

@onready var name_button: Button = %NameButton
@onready var name_edit: LineEdit = %NameEdit
@onready var mute_button: Button = %Mute
@onready var solo_button: Button = %Solo

## `MultisampleEditor.ALL_GROUPS` for "All", 0 for Ungrouped.
var group_id := 0


func _ready() -> void:
	name_button.gui_input.connect(_on_name_input)
	mute_button.toggled.connect(func(on: bool) -> void: mute_toggled.emit(on))
	solo_button.toggled.connect(func(on: bool) -> void: solo_toggled.emit(on))
	name_edit.text_submitted.connect(func(_t: String) -> void: _end_rename(true))
	name_edit.focus_exited.connect(func() -> void: _end_rename(true))
	name_edit.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_end_rename(false))


## Show group `p_group_id` named `text`; `active` when its zones are visible. `group` carries the
## mute and solo state (null for "All", which has neither).
func setup(p_group_id: int, text: String, active: bool, group: SamplerZoneGroup) -> void:
	group_id = p_group_id
	name_button.text = text
	name_button.set_pressed_no_signal(active)
	mute_button.visible = group != null
	solo_button.visible = group != null
	if group != null:
		mute_button.set_pressed_no_signal(group.mute)
		solo_button.set_pressed_no_signal(group.solo)
		var modes := ["All", "Round robin", "Random"]
		name_button.tooltip_text = "%s\nPlay mode: %s · Gain %s\nClick: show only this group. Ctrl-click: show it too. Right-click: options." % [
			text, modes[group.play_mode], ZoneStrip.knob_text(group.gain, "Gain")]
	else:
		name_button.tooltip_text = "Show every sample"


func _on_name_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var button := event as InputEventMouseButton
	if button.button_index == MOUSE_BUTTON_LEFT:
		name_button.accept_event()
		clicked.emit(button.is_command_or_control_pressed())
	elif button.button_index == MOUSE_BUTTON_RIGHT:
		name_button.accept_event()
		context_requested.emit(name_button.get_screen_position() + button.position)


func begin_rename() -> void:
	name_edit.text = name_button.text
	name_edit.custom_minimum_size.x = maxf(name_button.size.x, 60.0)
	name_button.visible = false
	name_edit.visible = true
	name_edit.grab_focus()
	name_edit.select_all()


func _end_rename(commit: bool) -> void:
	if not name_edit.visible:
		return
	name_edit.visible = false
	name_button.visible = true
	var text := name_edit.text.strip_edges()
	if commit and not text.is_empty() and text != name_button.text:
		name_committed.emit(text)
