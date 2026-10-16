# TrackListRow.gd
# One row of the Track List panel (spec 047): indent, visibility eye, fold arrow (only on tracks
# with children), a strip in the track color and the name, which swaps for a LineEdit while
# renaming. A row owns presentation and input only: it reports gestures through signals, and the
# panel decides what they do.
class_name TrackListRow extends PanelContainer

const EYE_ON := preload("res://assets/icons/eye.svg")
const EYE_OFF := preload("res://assets/icons/eye-off.svg")
const CHEVRON_RIGHT := preload("res://assets/icons/chevron-right.svg")
const CHEVRON_DOWN := preload("res://assets/icons/chevron-down.svg")
## Pixels of indent per nesting level.
const INDENT_PX := 12
## Eye alpha while the track is visible but some descendant is hidden.
const MIXED_ALPHA := 0.5

@onready var indent: Control = %Indent
@onready var eye_button: Button = %EyeButton
@onready var fold_button: Button = %FoldButton
@onready var color_strip: ColorRect = %ColorStrip
@onready var name_label: Label = %NameLabel
@onready var name_edit: LineEdit = %NameEdit

var track: Track = null
var project: Project = null
var depth: int = 0
var has_children: bool = false
## Collapsed in the Track List (not the arranger's own folder state).
var collapsed: bool = false

var _selected := false
var _mixed := false
var _renaming := false
var _styling := false
## Underline drawn under the eye while the state is mixed.
var _mixed_mark: ColorRect = null

## Press on the eye. The panel decides between toggling, painting and show-only.
signal eye_pressed(shift: bool)
signal fold_pressed
## Plain press on the row body (outside the eye and the arrow).
signal row_pressed(ctrl: bool, shift: bool)
signal row_double_clicked
signal context_requested(global_pos: Vector2)
## The name edit was confirmed (Enter or focus loss). Escape cancels without emitting.
signal rename_committed(text: String)


func _ready() -> void:
	eye_button.gui_input.connect(_on_eye_gui_input)
	fold_button.pressed.connect(func() -> void: fold_pressed.emit())
	name_edit.text_submitted.connect(_on_name_submitted)
	name_edit.focus_exited.connect(_on_name_focus_exited)
	name_edit.gui_input.connect(_on_name_edit_gui_input)
	_mixed_mark = ColorRect.new()
	_mixed_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mixed_mark.color = UiColors.role(&"accent_primary")
	_mixed_mark.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_mixed_mark.offset_top = -3
	_mixed_mark.offset_left = 4
	_mixed_mark.offset_right = -4
	_mixed_mark.visible = false
	eye_button.add_child(_mixed_mark)
	if track:
		_connect_track()
	refresh()


## Bind the row to `p_track`. Call before adding the row to the tree, or any time after.
func configure(p_project: Project, p_track: Track, p_depth: int, p_has_children: bool, p_collapsed: bool) -> void:
	project = p_project
	track = p_track
	depth = p_depth
	has_children = p_has_children
	collapsed = p_collapsed
	if is_node_ready():
		_connect_track()
		refresh()


func _connect_track() -> void:
	if track and not track.name_changed.is_connected(_on_track_changed):
		track.name_changed.connect(_on_track_changed)
		track.color_changed.connect(_on_track_changed)


func _on_track_changed(_value: Variant) -> void:
	refresh()


## Re-read everything from the track: name, color, own hidden flag, mixed state, dimming.
func refresh() -> void:
	if not is_node_ready() or track == null or project == null:
		return
	indent.custom_minimum_size.x = depth * INDENT_PX
	name_label.text = track.name
	color_strip.color = Utils.display_color(track.color)
	eye_button.icon = EYE_OFF if track.hidden else EYE_ON
	_mixed = has_children and TrackVisibility.is_mixed(project, track)
	eye_button.modulate.a = MIXED_ALPHA if _mixed else 1.0
	_mixed_mark.visible = _mixed
	if has_children:
		fold_button.icon = CHEVRON_RIGHT if collapsed else CHEVRON_DOWN
	else:
		fold_button.icon = null
	fold_button.disabled = not has_children
	fold_button.mouse_filter = Control.MOUSE_FILTER_STOP if has_children else Control.MOUSE_FILTER_IGNORE
	modulate.a = ItemVisibility.dim_alpha(
		ItemVisibility.track_hidden(project, track), ItemVisibility.track_disabled(project, track))
	_update_style()


func set_selected(selected: bool) -> void:
	if _selected == selected:
		return
	_selected = selected
	_update_style()


func is_selected() -> bool:
	return _selected


## True while the eye shows the track's own state as visible (not the cascaded one).
func is_eye_on() -> bool:
	return track != null and not track.hidden


## True while the track is visible but at least one of its descendants is hidden.
func is_mixed() -> bool:
	return _mixed


## True when the row shows a fold arrow (tracks without children keep the space but draw nothing).
func shows_arrow() -> bool:
	return fold_button.icon != null


func is_renaming() -> bool:
	return _renaming


func begin_rename() -> void:
	if track == null or _renaming:
		return
	_renaming = true
	name_edit.text = track.name
	name_label.visible = false
	name_edit.visible = true
	name_edit.grab_focus()
	name_edit.select_all()


## Leave the edit without applying the text.
func cancel_rename() -> void:
	_end_rename()


func _end_rename() -> void:
	_renaming = false
	name_edit.visible = false
	name_label.visible = true


func _commit_rename(text: String) -> void:
	if not _renaming:
		return
	_end_rename()
	rename_committed.emit(text)


func _on_name_submitted(text: String) -> void:
	_commit_rename(text)


func _on_name_focus_exited() -> void:
	_commit_rename(name_edit.text)


func _on_name_edit_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancel_rename()
		name_edit.accept_event()


## Selected rows get the neutral selection border and a hover fill; the rest draw no panel.
func _update_style() -> void:
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(3)
	if _selected:
		style.bg_color = UiColors.role(&"control_hover")
		style.set_border_width_all(1)
		style.border_color = UiColors.role(&"border_selected")
	else:
		style.bg_color = Color(0, 0, 0, 0)
	style.content_margin_left = 2
	style.content_margin_right = 4
	# Setting the override notifies THEME_CHANGED, which would restyle again.
	_styling = true
	add_theme_stylebox_override("panel", style)
	_styling = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready() and not _styling:
		_update_style()
		_mixed_mark.color = UiColors.role(&"accent_primary")


func _on_eye_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		eye_pressed.emit(event.shift_pressed)
		accept_event()


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.double_click:
			row_double_clicked.emit()
		else:
			row_pressed.emit(event.ctrl_pressed or event.meta_pressed, event.shift_pressed)
		accept_event()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		context_requested.emit(event.global_position)
		accept_event()
