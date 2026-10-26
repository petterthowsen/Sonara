## The strip below the value lanes that holds the automation lanes open for the focus track
## (spec 055). Track mode only. Which lanes are open, and their heights, belong to the track
## (`Track.clip_editor_lanes`, saved with the project); whether the pane is shown at all is an
## editor preference (config `clip_editor/automation_pane`). Opening or closing a lane here never
## changes its visibility in the Arranger, and the reverse holds too.
##
## Shortcuts follow keyboard focus: a press in a lane row focuses it, so Delete / Copy / Cut /
## Paste / Duplicate (handled in `_gui_input`, as key events bubble up from the focused row) act
## on that lane's points until the note area or a value lane takes the focus back.
class_name AutomationPane extends PanelContainer

const CONFIG_KEY := "clip_editor/automation_pane"
const LANE_SCENE := preload("res://clip_editor/automation/AutomationPaneLane.tscn")
const _ClipEditorLaneView := preload("res://clip_editor/automation/ClipEditorLaneView.gd")
const _LaneActions := preload("res://history/AutomationLanePresetActions.gd")

@onready var add_lane_button: Button = %AddLaneButton
@onready var lanes_box: VBoxContainer = %Lanes

var midi_editor: MidiEditor = null
## The lanes on screen, in pane order (AutomationPaneLane scenes).
var lanes: Array = []
## One point selection for the whole pane: scoped to one lane at a time (REQ-014).
var selection := AutomationPointSelectionManager.new()

var _split: SplitContainer = null
var _value_pane = null  # the NoteValuePane above
var _track: Track = null
var _view = _ClipEditorLaneView.new()
var _menu: AutomationLaneMenu = null
var _picker: AutomationParameterPicker = null
## The user's toggle, and whether the editor is in track mode. Both must hold to show the pane.
var _shown := true
var _available := false


func _ready() -> void:
	add_lane_button.pressed.connect(_on_add_lane_pressed)
	lanes_box.sort_children.connect(_align_lanes)
	visibility_changed.connect(_align_lanes)
	visibility_changed.connect(func(): _sync_split.call_deferred())
	minimum_size_changed.connect(func(): _sync_split.call_deferred())
	selection.selection_changed.connect(_on_selection_changed)
	selection.range_changed.connect(_redraw_rows)
	# Lanes in the scene are only there for previewing it.
	for child in lanes_box.get_children():
		lanes_box.remove_child(child)
		child.queue_free()
	_apply_visibility()


## Follow `editor`'s focus track. `split` is the editor split the pane sits at the bottom of,
## and `value_pane` the pane above it (which sizes the split while it is shown).
func bind(editor: MidiEditor, split: SplitContainer = null, value_pane = null) -> void:
	midi_editor = editor
	_split = split
	_value_pane = value_pane
	selection.grid_helper = editor.grid_helper
	if _split:
		_split.drag_ended.connect(func(): _sync_split.call_deferred())
	editor.focus_track_changed.connect(_on_focus_track_changed)
	# The note area moves when the key column (piano / drum rows) changes width.
	editor.note_area.item_rect_changed.connect(func(): _align_lanes.call_deferred())
	_load()
	_on_focus_track_changed()


func is_lanes_visible() -> bool:
	return _shown


## The toolbar toggle: show or hide the pane and remember it.
func set_lanes_visible(on: bool) -> void:
	_shown = on
	_apply_visibility()
	_save()


## Track mode switched on or off. Outside track mode the pane is hidden and shows no lanes.
func set_available(on: bool) -> void:
	if _available == on:
		return
	_available = on
	_apply_visibility()
	_rebuild()


func _apply_visibility() -> void:
	visible = _shown and _available
	_sync_split.call_deferred()


func lane_ids() -> Array[String]:
	var out: Array[String] = []
	for l in lanes:
		out.append(l.lane.id)
	return out


# ============================================================================
# FOCUS TRACK
# ============================================================================

func _on_focus_track_changed() -> void:
	selection.clear_selection()
	selection.release()
	var focus: Track = midi_editor.focus_track if midi_editor else null
	if focus != _track:
		if _track:
			_track.clip_editor_lanes_changed.disconnect(_rebuild)
			_track.automation_lane_removed.disconnect(_on_lane_removed)
		_track = focus
		if _track:
			_track.clip_editor_lanes_changed.connect(_rebuild)
			_track.automation_lane_removed.connect(_on_lane_removed)
	_rebuild()


func _on_lane_removed(lane: AutomationLane) -> void:
	selection.forget_lane(lane)


## Make the lanes on screen match the focus track's open lanes. When only heights changed the
## lane scenes stay, so a grip drag is not interrupted.
func _rebuild() -> void:
	var entries: Array = []
	if _track and _available:
		for entry in _track.clip_editor_lanes:
			if _lane_by_id(entry["id"]) != null:
				entries.append(entry)
	var same := entries.size() == lanes.size()
	if same:
		for i in entries.size():
			if lanes[i].track != _track or lanes[i].lane.id != entries[i]["id"]:
				same = false
				break
	if same:
		for i in entries.size():
			lanes[i].set_lane_height(float(entries[i]["height"]))
		return
	for l in lanes:
		lanes_box.remove_child(l)  # now, or it holds the pane's height for a frame
		l.queue_free()
	lanes.clear()
	for entry in entries:
		_add_lane_scene(_lane_by_id(entry["id"]), float(entry["height"]))
	_align_lanes.call_deferred()
	_sync_split.call_deferred()


func _lane_by_id(id: String) -> AutomationLane:
	for lane in _track.automation_lanes:
		if lane.id == id:
			return lane
	return null


func _add_lane_scene(lane: AutomationLane, height: float) -> void:
	var scene = LANE_SCENE.instantiate()
	lanes_box.add_child(scene)
	scene.setup(lane, _track, midi_editor, selection, height)
	scene.close_requested.connect(_on_close_requested)
	scene.height_changed.connect(_on_lane_height_changed)
	lanes.append(scene)


# ============================================================================
# LANES: CLOSE, RESIZE, ADD
# ============================================================================

## Close only hides the lane here: the lane, its points and the Arranger are untouched (REQ-007).
func _on_close_requested(lane: AutomationLane) -> void:
	if _track:
		_view.set_shown(_track, lane, false)


func _on_lane_height_changed(lane: AutomationLane, height: float) -> void:
	if _track == null:
		return
	var entries: Array[Dictionary] = []
	entries.assign(_track.clip_editor_lanes.duplicate(true))
	for entry in entries:
		if entry["id"] == lane.id:
			entry["height"] = height
	_track.set_clip_editor_lanes(entries)


func _on_add_lane_pressed() -> void:
	if _track == null:
		return
	if _menu == null:
		_menu = AutomationLaneMenu.new()
		add_child(_menu)
		_menu.add_lane_requested.connect(_on_add_lane_requested)
	_menu.open_for(_track, add_lane_button.get_screen_position() + Vector2(0.0, add_lane_button.size.y), _view)


## `+ Add new` in the lane menu: pick a parameter, then create the lane and open it here.
func _on_add_lane_requested(track: Track) -> void:
	if track == null:
		return
	if _picker == null:
		_picker = AutomationParameterPicker.new()
		add_child(_picker)
		_picker.parameter_chosen.connect(_on_parameter_chosen)
	_picker.open_for(track, get_global_mouse_position())


func _on_parameter_chosen(track: Track, target: AutomationTarget) -> void:
	if track == null or target == null:
		return
	_LaneActions.create_lane_for(track, target, _view)


# ============================================================================
# SELECTION AND SHORTCUTS
# ============================================================================

func _on_selection_changed(_lane: AutomationLane, _ids: Array) -> void:
	_redraw_rows()


func _redraw_rows() -> void:
	for l in lanes:
		l.row.queue_redraw()


func _row_focused() -> bool:
	for l in lanes:
		if l.row.has_focus():
			return true
	return false


## Delete, Copy, Cut, Paste and Duplicate act on the points while a lane row holds the focus.
func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed) or not _row_focused():
		return
	if Hotkeys.pressed(event, "edit_copy"):
		selection.copy()
	elif Hotkeys.pressed(event, "edit_cut"):
		selection.cut_selection()
	elif Hotkeys.pressed(event, "edit_paste"):
		var playhead: int = Sonara.editor.playhead_ticks if Sonara and Sonara.editor else 0
		selection.paste_at(playhead)
	elif Hotkeys.pressed(event, "edit_duplicate"):
		selection.duplicate_selection()
	elif Hotkeys.pressed(event, "edit_delete"):
		selection.delete_selection()
	else:
		return
	accept_event()


# ============================================================================
# LAYOUT
# ============================================================================

## Size each lane's header so its row starts exactly where the note area does: the pane's own
## margin and "+" column come out of the key column's width.
func _align_lanes() -> void:
	if midi_editor == null or not is_visible_in_tree():
		return
	var target := midi_editor.note_area.global_position.x
	for l in lanes:
		if l.is_node_ready() and not l.is_queued_for_deletion():
			l.set_header_width(target - l.header.global_position.x)


## While the value pane is shown it sizes the split (it knows this pane's height). Alone, this
## pane gives itself exactly its own minimum height.
func _sync_split() -> void:
	if _split == null or not is_visible_in_tree():
		return
	if _value_pane and _value_pane.visible and not _value_pane.lanes.is_empty():
		return
	var want := roundi(get_combined_minimum_size().y)
	if _split.split_offset != -want:
		_split.split_offset = -want


# ============================================================================
# PERSISTENCE
# ============================================================================

## Looked up through the tree: this class_name script can compile before autoloads resolve by name.
func _sonara() -> Node:
	return get_node("/root/Sonara")


func _load() -> void:
	var cfg = _sonara().get_config(CONFIG_KEY, null)
	_shown = bool(cfg.get("visible", true)) if cfg is Dictionary else true
	_apply_visibility()


func _save() -> void:
	_sonara().set_config(CONFIG_KEY, {"visible": _shown})
