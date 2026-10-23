# TrackListPanel.gd
# Spec 047: the Track List dock panel. A tree of every track (hidden and disabled ones too) with a
# visibility eye per row, a name filter, and the project's visibility presets on top. The rules for
# showing and hiding live in TrackVisibility; this panel only turns gestures into calls to it.
#
# Rows are rebuilt (coalesced, and skipped when the track structure is unchanged) when tracks are
# added, removed, moved or re-parented, and refreshed in place for visibility, name and color
# changes. Expand/collapse is local to the panel and never touches Track.is_folder_expanded.
# Selection is the editor's track selection: the panel highlights from `tracks_selected` and
# changes it through `select_tracks`.
#
# Setup: add the panel to the tree, then `bind(project, selection_source)`. In the running editor it
# binds itself on Editor.project_activated / project_closed.
class_name TrackListPanel extends VBoxContainer

const RowScene := preload("res://editor/track_list/TrackListRow.tscn")

## Items of the preset selector. Preset `i` has id `i + 1`.
const ITEM_ALL := 0
const ITEM_CUSTOM := 1000000

## Entries of the preset (...) menu.
const PRESET_ADD := 0
const PRESET_RENAME := 1
const PRESET_DELETE := 2
const PRESET_MOVE_UP := 3
const PRESET_MOVE_DOWN := 4

## Entries of the row context menu.
const MENU_RENAME := 0
const MENU_COLOR := 1
const MENU_HIDE := 2
const MENU_ENABLE := 3
const MENU_EXPAND_ALL := 4
const MENU_COLLAPSE_ALL := 5

@onready var preset_selector: OptionButton = %PresetSelector
@onready var preset_menu: MenuButton = %PresetMenu
@onready var save_button: Button = %SaveButton
@onready var reset_button: Button = %ResetButton
@onready var filter_edit: LineEdit = %FilterEdit
@onready var scroll: ScrollContainer = %Scroll
@onready var rows_box: VBoxContainer = %Rows

var project: Project = null
## Provides the shared track selection: `selected_tracks`, `tracks_selected`, `select_tracks(tracks,
## active)` and `reveal_track(track)`. The Editor in the app, a stub in tests.
var selection_source: Object = null

## Rows in display order, and track -> row.
var _rows: Array[TrackListRow] = []
var _row_by_track: Dictionary = {}
## Track ID -> true for rows folded in this panel.
var _collapsed: Dictionary = {}
var _filter := ""
var _signature := ""
var _rebuild_queued := false
var _connected_tracks: Array[Track] = []

var _selected: Array[Track] = []
var _active: Track = null
var _anchor: Track = null

# Drag painting: after a plain press on an eye, every row the pointer crosses gets `_paint_value`.
var _painting := false
var _paint_value := false
var _paint_last_y := 0.0
## Visibility target -> hidden flag it had before the drag touched it.
var _paint_old: Dictionary = {}

var _context_menu: PopupMenu = null
var _context_tracks: Array[Track] = []
var _context_pos := Vector2.ZERO
var _color_popup: PopupPanel = null
var _color_picker: ColorPicker = null
## Track -> color before the open color popup changed it.
var _color_gesture: Dictionary = {}
var _color_syncing := false
var _rename_popup: PopupPanel = null
var _rename_edit: LineEdit = null


func _ready() -> void:
	HotkeyActions.declare_context(self, "tracklist")
	preset_selector.item_selected.connect(_on_selector_item_selected)
	var popup := preset_menu.get_popup()
	popup.theme_type_variation = &"ContextMenuList"
	popup.add_item("Add Preset", PRESET_ADD)
	popup.add_item("Rename Preset...", PRESET_RENAME)
	popup.add_item("Delete Preset", PRESET_DELETE)
	popup.add_item("Move Preset Up", PRESET_MOVE_UP)
	popup.add_item("Move Preset Down", PRESET_MOVE_DOWN)
	popup.id_pressed.connect(_on_preset_menu_id)
	save_button.pressed.connect(save_active_preset)
	reset_button.pressed.connect(reset_active_preset)
	filter_edit.text_changed.connect(set_filter)
	_refresh_header()
	if not Utils.is_test_mode() and Sonara and Sonara.editor:
		var editor := Sonara.editor
		editor.project_activated.connect(_on_project_activated)
		editor.project_closed.connect(_on_project_closed)
		if editor.project:
			bind(editor.project, editor)
	if project != null and _rows.is_empty():
		_rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()


func _on_project_activated(p: Project) -> void:
	bind(p, Sonara.editor)


func _on_project_closed() -> void:
	bind(null)


## Show `p`'s tracks and follow its changes. `source` supplies the track selection (see
## `selection_source`). Passing a null project empties the panel.
func bind(p: Project, source: Object = null) -> void:
	_unbind()
	if p != project:
		_collapsed.clear()
	project = p
	selection_source = source
	_selected.clear()
	_active = null
	_anchor = null
	if project:
		project.track_added.connect(_on_project_track_changed)
		project.track_removed.connect(_on_project_track_changed)
		project.tracks_layout_changed.connect(_queue_rebuild)
		project.item_visibility_changed.connect(_refresh_rows)
		project.visibility_presets.changed.connect(_refresh_header)
	if selection_source:
		selection_source.tracks_selected.connect(_on_tracks_selected)
		_set_selected(selection_source.selected_tracks, null)
	if is_node_ready():
		_rebuild()


func _unbind() -> void:
	_painting = false
	_paint_old.clear()
	if project:
		if project.track_added.is_connected(_on_project_track_changed):
			project.track_added.disconnect(_on_project_track_changed)
			project.track_removed.disconnect(_on_project_track_changed)
			project.tracks_layout_changed.disconnect(_queue_rebuild)
			project.item_visibility_changed.disconnect(_refresh_rows)
		if project.visibility_presets.changed.is_connected(_refresh_header):
			project.visibility_presets.changed.disconnect(_refresh_header)
	if selection_source and is_instance_valid(selection_source):
		if selection_source.tracks_selected.is_connected(_on_tracks_selected):
			selection_source.tracks_selected.disconnect(_on_tracks_selected)
	_disconnect_tracks()


# ============================================================================
# LISTING
# ============================================================================

## Tracks that have a row now, in display order.
func get_row_tracks() -> Array[Track]:
	var out: Array[Track] = []
	for row in _rows:
		out.append(row.track)
	return out


## The row listing `track`, or null when it has none (folded away or filtered out).
func get_row(track: Track) -> TrackListRow:
	return _row_by_track.get(track)


func get_selected_tracks() -> Array[Track]:
	return _selected.duplicate()


## Fold or unfold `track` in this panel only.
func toggle_collapsed(track: Track) -> void:
	if _collapsed.has(track.id):
		_collapsed.erase(track.id)
	else:
		_collapsed[track.id] = true
	_rebuild()


func is_collapsed(track: Track) -> bool:
	return _collapsed.has(track.id)


## Show only tracks whose name contains `text` (case-insensitive) and their ancestors, ancestors
## unfolded. An empty text lists everything again with the earlier fold state.
func set_filter(text: String) -> void:
	_filter = text.strip_edges()
	if filter_edit.text != text:
		filter_edit.text = text
	_rebuild()


## Rebuild the rows right now (instead of at the end of the frame).
func rebuild_now() -> void:
	_rebuild()


func _on_project_track_changed(_track: Track) -> void:
	_queue_rebuild()


func _on_track_structure_changed(_value: int) -> void:
	_queue_rebuild()


## Coalesces bursts of add/remove/reorder signals into one pass.
func _queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		_rebuild_if_changed.call_deferred()


## Rebuild only when the tree shape differs from what the rows show; tracks_layout_changed is also
## emitted by every visibility change, which only needs a refresh.
func _rebuild_if_changed() -> void:
	_rebuild_queued = false
	if project == null:
		return
	if _structure_signature() == _signature:
		_refresh_rows()
	else:
		_rebuild()


func _structure_signature() -> String:
	var parts := PackedStringArray()
	for t in project.get_visual_track_list():
		parts.append("%d:%d" % [t.id, t.parent_track_id])
	return ",".join(parts)


func _rebuild() -> void:
	_rebuild_queued = false
	for row in _rows:
		rows_box.remove_child(row)
		row.queue_free()
	_rows.clear()
	_row_by_track.clear()
	_disconnect_tracks()
	if project == null:
		_signature = ""
		_refresh_header()
		return
	_connect_tracks()
	_signature = _structure_signature()
	var kept: Array[Track] = []
	for t in _selected:
		if project.tracks.has(t):
			kept.append(t)
	_selected = kept
	if not project.tracks.has(_active):
		_active = null
	if not project.tracks.has(_anchor):
		_anchor = null
	for entry in _compute_entries():
		var track: Track = entry["track"]
		var row: TrackListRow = RowScene.instantiate()
		row.configure(project, track, entry["depth"], entry["has_children"], entry["collapsed"])
		row.eye_pressed.connect(_on_eye_pressed.bind(track))
		row.fold_pressed.connect(_on_fold_pressed.bind(track))
		row.row_pressed.connect(_on_row_pressed.bind(track))
		row.row_double_clicked.connect(_on_row_double_clicked.bind(track))
		row.context_requested.connect(_on_context_requested.bind(track))
		row.rename_committed.connect(_on_rename_committed.bind(track))
		rows_box.add_child(row)
		row.set_selected(_selected.has(track))
		_rows.append(row)
		_row_by_track[track] = row
	_refresh_header()


## What the rows show, top to bottom: [{track, depth, has_children, collapsed}].
func _compute_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var visual := project.get_visual_track_list()
	var by_id := {}
	var child_count := {}
	for t in visual:
		by_id[t.id] = t
		if t.parent_track_id >= 0:
			child_count[t.parent_track_id] = int(child_count.get(t.parent_track_id, 0)) + 1
	var filtering := not _filter.is_empty()
	var shown := {}
	if filtering:
		var needle := _filter.to_lower()
		for t in visual:
			if t.name.to_lower().contains(needle):
				var node: Track = t
				var guard := 0
				while node != null and guard < 64:
					shown[node] = true
					node = by_id.get(node.parent_track_id) if node.parent_track_id >= 0 else null
					guard += 1
	for t in visual:
		if filtering and not shown.has(t):
			continue
		var depth := 0
		var folded_away := false
		var parent: Track = by_id.get(t.parent_track_id) if t.parent_track_id >= 0 else null
		var guard := 0
		while parent != null and guard < 64:
			depth += 1
			if not filtering and _collapsed.has(parent.id):
				folded_away = true
			parent = by_id.get(parent.parent_track_id) if parent.parent_track_id >= 0 else null
			guard += 1
		if folded_away:
			continue
		entries.append({
			"track": t,
			"depth": depth,
			"has_children": child_count.has(t.id),
			"collapsed": not filtering and _collapsed.has(t.id),
		})
	return entries


func _connect_tracks() -> void:
	for t in project.tracks:
		if not t.order_changed.is_connected(_on_track_structure_changed):
			t.order_changed.connect(_on_track_structure_changed)
			t.parent_changed.connect(_on_track_structure_changed)
		_connected_tracks.append(t)


func _disconnect_tracks() -> void:
	for t in _connected_tracks:
		if is_instance_valid(t) and t.order_changed.is_connected(_on_track_structure_changed):
			t.order_changed.disconnect(_on_track_structure_changed)
			t.parent_changed.disconnect(_on_track_structure_changed)
	_connected_tracks.clear()


## Refresh every row in place (visibility, name, color) and the preset header.
func _refresh_rows() -> void:
	for row in _rows:
		row.refresh()
	_refresh_header()


# ============================================================================
# VISIBILITY TOGGLES
# ============================================================================

func _on_fold_pressed(track: Track) -> void:
	grab_focus()
	toggle_collapsed(track)


func _on_eye_pressed(shift: bool, track: Track) -> void:
	if project == null:
		return
	grab_focus()
	if shift:
		TrackVisibility.show_only(project, track)
	elif TrackVisibility.is_mixed(project, track):
		TrackVisibility.show_branch(project, track)
	else:
		_begin_paint(track)


func _begin_paint(track: Track) -> void:
	_painting = true
	_paint_old.clear()
	_paint_value = not track.hidden
	var row := get_row(track)
	_paint_last_y = row.get_global_rect().get_center().y if row else get_global_mouse_position().y
	_paint_tracks([track] as Array[Track])


func _input(event: InputEvent) -> void:
	if not _painting:
		return
	if event is InputEventMouseMotion:
		var y: float = event.global_position.y
		_paint_rows_between(_paint_last_y, y)
		_paint_last_y = y
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_end_paint()


## Paint every row the pointer crossed between two heights, so a fast drag skips none.
func _paint_rows_between(y0: float, y1: float) -> void:
	var view := scroll.get_global_rect()
	var low := maxf(minf(y0, y1), view.position.y)
	var high := minf(maxf(y0, y1), view.end.y - 0.01)
	if low > high:
		return
	var hit: Array[Track] = []
	for row in _rows:
		var r := row.get_global_rect()
		if r.end.y > low and r.position.y <= high:
			hit.append(row.track)
	_paint_tracks(hit)


## Give the targets of `tracks` the paint value now, remembering what they had. One view update.
func _paint_tracks(tracks: Array[Track]) -> void:
	var todo: Array[Object] = []
	for t in tracks:
		var target := TrackVisibility.target_of(project, t)
		if _paint_old.has(target):
			continue
		_paint_old[target] = target.hidden
		if target.hidden != _paint_value:
			todo.append(target)
	if todo.is_empty():
		return
	var value := _paint_value
	project.batch_visibility(func() -> void:
		for target in todo:
			target.set_hidden(value))


## The drag is over: record everything it changed as one undo step.
func _end_paint() -> void:
	_painting = false
	var old_values := {}
	var new_values := {}
	for target in _paint_old:
		if _paint_old[target] != _paint_value and is_instance_valid(target):
			old_values[target] = _paint_old[target]
			new_values[target] = _paint_value
	_paint_old.clear()
	if new_values.is_empty() or project == null:
		return
	HistoryUtil.record(VisibilityStateCommand.new("Change Track Visibility", project, old_values, new_values))


## Hide `tracks` when any of them is visible, else show them, as one undo step.
func toggle_visibility_of(tracks: Array[Track]) -> void:
	if project == null or tracks.is_empty():
		return
	var any_visible := false
	for t in tracks:
		if not TrackVisibility.target_of(project, t).hidden:
			any_visible = true
	_set_hidden_for(tracks, any_visible, "Hide Tracks" if any_visible else "Show Tracks")


func _set_hidden_for(tracks: Array[Track], hidden: bool, label: String) -> void:
	var old_values := {}
	var new_values := {}
	for t in tracks:
		var target := TrackVisibility.target_of(project, t)
		if old_values.has(target) or target.hidden == hidden:
			continue
		old_values[target] = target.hidden
		new_values[target] = hidden
	if new_values.is_empty():
		return
	HistoryUtil.execute(VisibilityStateCommand.new(label, project, old_values, new_values))


func _set_enabled_for(tracks: Array[Track], enabled: bool) -> void:
	var label := "Enable Tracks" if enabled else "Disable Tracks"
	var cmds: Array[Command] = []
	var seen := {}
	for t in tracks:
		var target := TrackVisibility.target_of(project, t)
		if seen.has(target) or target.enabled == enabled:
			continue
		seen[target] = true
		cmds.append(PropertyCommand.new(label, target, "set_enabled", target.enabled, enabled))
	HistoryUtil.execute_many(label, cmds)


# ============================================================================
# SELECTION
# ============================================================================

func _on_row_pressed(ctrl: bool, shift: bool, track: Track) -> void:
	grab_focus()
	var tracks: Array[Track] = []
	var active := track
	if shift:
		var from: Track = _anchor if _anchor != null and _row_by_track.has(_anchor) else _active
		tracks = _range_between(from if from != null else track, track)
	elif ctrl:
		tracks = _selected.duplicate()
		if tracks.has(track):
			tracks.erase(track)
			active = tracks.back() if not tracks.is_empty() else null
		else:
			tracks.append(track)
		_anchor = track
	else:
		tracks = [track] as Array[Track]
		_anchor = track
	_apply_selection(tracks, active)
	if not ctrl and not shift:
		_reveal(track)


## The rows from `a` to `b` inclusive, in display order.
func _range_between(a: Track, b: Track) -> Array[Track]:
	var out: Array[Track] = []
	var inside := false
	for row in _rows:
		var hit: bool = row.track == a or row.track == b
		if hit and not inside:
			inside = true
			out.append(row.track)
			if a == b:
				break
		elif inside:
			out.append(row.track)
			if hit:
				break
	return out


## Select exactly `track` and scroll to it (a plain click, or a keyboard move).
func _select_single(track: Track) -> void:
	_anchor = track
	_apply_selection([track] as Array[Track], track)
	_reveal(track)
	var row := get_row(track)
	if row:
		scroll.ensure_control_visible(row)


func _apply_selection(tracks: Array[Track], active: Track) -> void:
	_set_selected(tracks, active)
	if selection_source:
		selection_source.select_tracks(tracks, active)


func _reveal(track: Track) -> void:
	if selection_source and selection_source.has_method("reveal_track"):
		selection_source.reveal_track(track)


## The editor's selection changed (here, in the arranger or in the mixer).
func _on_tracks_selected(tracks: Array) -> void:
	_set_selected(tracks, null)


func _set_selected(tracks: Array, active: Track) -> void:
	_selected.clear()
	for t in tracks:
		if t is Track and not _selected.has(t):
			_selected.append(t)
	if active != null and _selected.has(active):
		_active = active
	elif not _selected.has(_active):
		_active = _selected.back() if not _selected.is_empty() else null
	if _anchor == null or not _selected.has(_anchor):
		_anchor = _active
	for row in _rows:
		row.set_selected(_selected.has(row.track))


# ============================================================================
# RENAME, CONTEXT MENU, COLOR
# ============================================================================

func _on_row_double_clicked(track: Track) -> void:
	var row := get_row(track)
	if row:
		row.begin_rename()


func _on_rename_committed(text: String, track: Track) -> void:
	text = text.strip_edges()
	if text.is_empty() or not is_instance_valid(track):
		return
	# Record the name the track will really get, so redo reproduces it.
	var new_name := track.unique_name_for(text)
	HistoryUtil.execute_property("Rename Track", track, "set_name", track.name, new_name)


func _on_context_requested(global_pos: Vector2, track: Track) -> void:
	open_context_menu(track, global_pos)


func open_context_menu(track: Track, global_pos: Vector2) -> void:
	prepare_context_menu(track)
	_context_pos = global_pos
	ContextMenuPopup.popup_at_point(_context_menu, global_pos)


## Decide which tracks the menu acts on (the selection, or the clicked track which then becomes the
## selection) and label its entries. Does not open it.
func prepare_context_menu(track: Track) -> void:
	if not _selected.has(track):
		_anchor = track
		_apply_selection([track] as Array[Track], track)
	_context_tracks = _selected.duplicate()
	if _context_menu == null:
		_build_context_menu()
	var any_visible := false
	var any_enabled := false
	for t in _context_tracks:
		var target := TrackVisibility.target_of(project, t)
		any_visible = any_visible or not target.hidden
		any_enabled = any_enabled or target.enabled
	_context_menu.set_item_disabled(_context_menu.get_item_index(MENU_RENAME), _context_tracks.size() != 1)
	_context_menu.set_item_text(_context_menu.get_item_index(MENU_HIDE), "Hide" if any_visible else "Show")
	_context_menu.set_item_text(_context_menu.get_item_index(MENU_ENABLE), "Disable" if any_enabled else "Enable")


func _build_context_menu() -> void:
	_context_menu = PopupMenu.new()
	_context_menu.theme_type_variation = &"ContextMenuList"
	_context_menu.add_item("Rename", MENU_RENAME)
	_context_menu.add_item("Color...", MENU_COLOR)
	_context_menu.add_separator()
	_context_menu.add_item("Hide", MENU_HIDE)
	_context_menu.add_item("Disable", MENU_ENABLE)
	_context_menu.add_separator()
	_context_menu.add_item("Expand All", MENU_EXPAND_ALL)
	_context_menu.add_item("Collapse All", MENU_COLLAPSE_ALL)
	_context_menu.id_pressed.connect(run_context_action)
	add_child(_context_menu)


## Do context menu entry `id` on the tracks `prepare_context_menu` chose.
func run_context_action(id: int) -> void:
	if project == null or _context_tracks.is_empty():
		return
	match id:
		MENU_RENAME:
			if _context_tracks.size() == 1:
				_on_row_double_clicked(_context_tracks[0])
		MENU_COLOR:
			_open_color_popup()
		MENU_HIDE:
			var any_visible := false
			for t in _context_tracks:
				any_visible = any_visible or not TrackVisibility.target_of(project, t).hidden
			_set_hidden_for(_context_tracks, any_visible, "Hide Tracks" if any_visible else "Show Tracks")
		MENU_ENABLE:
			var any_enabled := false
			for t in _context_tracks:
				any_enabled = any_enabled or TrackVisibility.target_of(project, t).enabled
			_set_enabled_for(_context_tracks, not any_enabled)
		MENU_EXPAND_ALL:
			_collapsed.clear()
			_rebuild()
		MENU_COLLAPSE_ALL:
			for t in project.tracks:
				if not project.get_track_children(t).is_empty():
					_collapsed[t.id] = true
			_rebuild()


func _open_color_popup() -> void:
	if _color_popup == null:
		_color_popup = PopupPanel.new()
		_color_popup.theme_type_variation = &"ContextMenu"
		_color_picker = ColorPicker.new()
		_color_picker.edit_alpha = false
		_color_picker.color_changed.connect(_on_picker_color_changed)
		_color_popup.add_child(_color_picker)
		_color_popup.popup_hide.connect(_on_color_popup_hidden)
		add_child(_color_popup)
	_color_syncing = true
	_color_picker.color = _context_tracks[0].color
	_color_syncing = false
	_color_gesture.clear()
	ContextMenuPopup.popup_at_point(_color_popup, _context_pos)


## The picker changes the colors live; closing the popup records them as one undo step.
func _on_picker_color_changed(color: Color) -> void:
	if _color_syncing:
		return
	if _color_gesture.is_empty():
		for t in _context_tracks:
			_color_gesture[t] = t.color
	for t in _color_gesture:
		t.set_color(color)


func _on_color_popup_hidden() -> void:
	var cmds: Array[Command] = []
	for t: Track in _color_gesture:
		var old_color: Color = _color_gesture[t]
		if is_instance_valid(t) and t.color != old_color:
			cmds.append(PropertyCommand.new("Set Track Color", t, "set_color", old_color, t.color))
	_color_gesture.clear()
	HistoryUtil.record_many("Set Track Color", cmds)


# ============================================================================
# KEYBOARD
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	match event.keycode:
		KEY_UP:
			_step_selection(-1)
		KEY_DOWN:
			_step_selection(1)
		KEY_LEFT:
			_key_left()
		KEY_RIGHT:
			_key_right()
		_:
			return
	accept_event()


## Move the selection `direction` rows up (-1) or down (+1) from the active row.
func _step_selection(direction: int) -> void:
	if _rows.is_empty():
		return
	var index := -1
	for i in _rows.size():
		if _rows[i].track == _active:
			index = i
	var next := 0 if index < 0 else clampi(index + direction, 0, _rows.size() - 1)
	_select_single(_rows[next].track)


## Collapse the active row, or go to its parent when it is already collapsed (or a leaf).
func _key_left() -> void:
	var row: TrackListRow = get_row(_active) if _active else null
	if row == null:
		return
	if row.has_children and not row.collapsed and _filter.is_empty():
		toggle_collapsed(_active)
		return
	var parent: Track = project.get_track_by_id(_active.parent_track_id) if _active.parent_track_id >= 0 else null
	if parent != null and _row_by_track.has(parent):
		_select_single(parent)


func _key_right() -> void:
	var row: TrackListRow = get_row(_active) if _active else null
	if row != null and row.has_children and row.collapsed:
		toggle_collapsed(_active)


# ============================================================================
# PRESET HEADER
# ============================================================================

## Refill the selector from the presets and set the enabled state of Save, Reset and the menu.
func _refresh_header() -> void:
	if not is_node_ready():
		return
	preset_selector.clear()
	var can_edit := project != null
	preset_selector.disabled = not can_edit
	preset_menu.disabled = not can_edit
	if project == null:
		save_button.disabled = true
		reset_button.disabled = true
		return
	var presets := project.visibility_presets
	var label := TrackVisibility.selector_label(project)
	var has_active := presets.active_index >= 0 and presets.active_index < presets.count()
	if label == "Custom":
		preset_selector.add_item(label, ITEM_CUSTOM)
	preset_selector.add_item("All", ITEM_ALL)
	for i in presets.count():
		preset_selector.add_item(presets.display_name(i), i + 1)
	var shown_id := presets.active_index + 1 if has_active else (ITEM_CUSTOM if label == "Custom" else ITEM_ALL)
	var shown_index := preset_selector.get_item_index(shown_id)
	preset_selector.select(shown_index)
	# The active preset reads "1: Orchestra *" while it has unsaved changes.
	preset_selector.set_item_text(shown_index, label)
	var dirty := TrackVisibility.is_dirty(project)
	# Save on "Custom" (no active preset) creates a new preset from the current state.
	save_button.disabled = not dirty and label != "Custom"
	reset_button.disabled = not dirty
	var menu := preset_menu.get_popup()
	menu.set_item_disabled(menu.get_item_index(PRESET_RENAME), not has_active)
	menu.set_item_disabled(menu.get_item_index(PRESET_DELETE), not has_active)
	menu.set_item_disabled(menu.get_item_index(PRESET_MOVE_UP), not has_active or presets.active_index == 0)
	menu.set_item_disabled(menu.get_item_index(PRESET_MOVE_DOWN),
		not has_active or presets.active_index == presets.count() - 1)


func _on_selector_item_selected(index: int) -> void:
	pick_preset_item(preset_selector.get_item_id(index))


## Do what picking selector item `item_id` does: "All", or preset `item_id - 1`.
func pick_preset_item(item_id: int) -> void:
	if project == null or item_id == ITEM_CUSTOM:
		return
	if item_id == ITEM_ALL:
		TrackVisibility.show_all(project)
	else:
		TrackVisibility.apply_preset(project, item_id - 1)
	_refresh_header()


func _on_preset_menu_id(id: int) -> void:
	match id:
		PRESET_ADD:
			add_preset()
		PRESET_RENAME:
			_open_rename_popup()
		PRESET_DELETE:
			delete_active_preset()
		PRESET_MOVE_UP:
			move_active_preset(-1)
		PRESET_MOVE_DOWN:
			move_active_preset(1)


## Append a preset holding the current hidden state and make it active.
func add_preset() -> void:
	if project:
		TrackVisibility.add_preset(project)


func rename_active_preset(new_name: String) -> void:
	if project:
		TrackVisibility.rename_preset(project, project.visibility_presets.active_index, new_name)


func delete_active_preset() -> void:
	if project:
		TrackVisibility.delete_preset(project, project.visibility_presets.active_index)


## Move the active preset `delta` positions (-1 up, +1 down).
func move_active_preset(delta: int) -> void:
	if project:
		var index := project.visibility_presets.active_index
		TrackVisibility.move_preset(project, index, index + delta)


## Store the current state in the active preset, or add a new preset when there is none (Custom).
func save_active_preset() -> void:
	if project == null:
		return
	if project.visibility_presets.active_index < 0:
		if not TrackVisibility.capture(project).is_empty():
			TrackVisibility.add_preset(project)
	else:
		TrackVisibility.save_preset(project)


func reset_active_preset() -> void:
	if project:
		TrackVisibility.reset_preset(project)


func _open_rename_popup() -> void:
	if project == null or project.visibility_presets.active_index < 0:
		return
	if _rename_popup == null:
		_rename_popup = PopupPanel.new()
		_rename_popup.theme_type_variation = &"ContextMenu"
		_rename_edit = LineEdit.new()
		_rename_edit.custom_minimum_size = Vector2(160, 0)
		_rename_edit.text_submitted.connect(_on_preset_rename_submitted)
		_rename_popup.add_child(_rename_edit)
		add_child(_rename_popup)
	var presets := project.visibility_presets
	_rename_edit.text = presets.get_preset(presets.active_index)["name"]
	ContextMenuPopup.popup_below_control(_rename_popup, preset_selector)
	_rename_edit.grab_focus()
	_rename_edit.select_all()


func _on_preset_rename_submitted(text: String) -> void:
	rename_active_preset(text)
	ContextMenuPopup.close(_rename_popup)
