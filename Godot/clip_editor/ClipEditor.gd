class_name ClipEditor extends VBoxContainer

var log := Log.make("ClipEditor")

## Emitted when the user picks a track in the Track-Mode track list (not on programmatic/silent
## selection). Editor uses this to optionally mirror the pick onto the arranger/mixer selection.
signal track_mode_track_selected(track: Track)

# left panel will show track list when showing multiple clips, with buttons to switch between clips
@onready var left_panel: PanelContainer = $HSplit/LeftPanel

# main panel shows ruler and midi editor
@onready var main_panel: PanelContainer = $HSplit/MainPanel

@onready var main_header: PanelContainer = $HSplit/MainPanel/VBox/PanelContainer/MainHeader
@onready var main_header_options: HBoxContainer = $HSplit/MainPanel/VBox/PanelContainer/MainHeader/MainOptions
@onready var track_mode_toggle: Button = $HSplit/MainPanel/VBox/PanelContainer/MainHeader/MainOptions/TrackModeToggle

@onready var ruler: Ruler = $HSplit/MainPanel/VBox/PanelContainer/VBox/Ruler

@onready var midi_editor = $HSplit/MainPanel/VBox/MidiEditor

@onready var audition_toggle: Button = $BottomPanel/Toolbar/AuditionToggle
const AUDITION_CONFIG_KEY := "clip_editor/audition"

# Note map / Drum View toolbar (docs/specs/002-note-maps)
@onready var mode_switch: Button = $BottomPanel/Toolbar/ModeSwitch
@onready var note_map_button: Button = $BottomPanel/Toolbar/NoteMapButton
@onready var note_map_popup: PopupMenu = $BottomPanel/Toolbar/NoteMapButton/NoteMapPopup
@onready var note_map_load_button: Button = $BottomPanel/Toolbar/NoteMapLoad
@onready var note_map_edit_button: Button = $BottomPanel/Toolbar/NoteMapEdit
@onready var note_map_save_button: Button = $BottomPanel/Toolbar/NoteMapSave

## Popup item ids. Library entries use LIBRARY_ID_BASE + index.
const NOTE_MAP_ID_NONE := 0
const NOTE_MAP_ID_AUTO := 1
const NOTE_MAP_LIBRARY_ID_BASE := 100

var _note_map_editor: NoteMapEditorDialog = null
var _note_map_browser: NoteMapBrowserDialog = null
var _note_map_save_dialog: NoteMapSaveDialog = null
## Library maps currently listed in the dropdown, indexed by popup id offset.
var _popup_library_maps: Array[NoteMap] = []
## True while the toolbar is being rebuilt, so syncing controls doesn't loop.
var _syncing_toolbar := false

# for multi-track clip editing
@onready var track_selector: ClipEditorTrackList = $HSplit/LeftPanel/VBox/ClipEditorTrackList

var grid_helper: GridHelper:
	set(gh):
		if grid_helper != gh:
			grid_helper = gh
			midi_editor.grid_helper = gh
			ruler.set_grid_helper(gh)

# Local cursor position (in ticks) - separate from main playhead
# Used for paste operations and other editing functions
var cursor_position_ticks: int = 0:
	set(value):
		cursor_position_ticks = value
		# Update NoteEditor's cursor
		if midi_editor:
			midi_editor.cursor_position_ticks = cursor_position_ticks

# Track-mode state
var track_mode: bool = false  # True when editing multiple clips across different tracks

# Persisted state to support manual toggle behavior
var last_track_mode_tracks: Array[Track] = []
var last_track_mode_selected_track: Track = null
var last_active_clip_by_track := {}  # Track -> ClipInstance

# Selected clips and tracks (for track-mode)
var selected_clips: Array[ClipInstance] = []
var selected_tracks: Array[Track] = []

# Store pending clip data until we become visible
var pending_clips: Array[ClipInstance] = []
var pending_multi_track: bool = false

# Track the currently bound clip instance for playhead conversion (single-clip mode)
var bound_clip_instance: ClipInstance = null

func _ready():
	grid_helper = GridHelper.new()
	
	# Connect GridHelper signals
	grid_helper.changed.connect(_on_grid_helper_changed)
	
	# Connect to visibility changes
	visibility_changed.connect(_on_visibility_changed)
	
	# Connect to Ruler's click event to update cursor position
	ruler.start_position_requested.connect(_on_ruler_position_requested)
	
	# Wire up Track/Clip mode toggle
	if track_mode_toggle:
		track_mode_toggle.toggled.connect(_on_track_mode_toggle_toggled)
		_update_mode_ui()
	
	var audition_on: bool = Sonara.get_config(AUDITION_CONFIG_KEY, false)
	audition_toggle.set_pressed_no_signal(audition_on)
	midi_editor.audition_enabled = audition_on
	audition_toggle.toggled.connect(_on_audition_toggled)
	
	_setup_note_map_toolbar()

	if Sonara.editor:
		Sonara.editor.clips_selected.connect(_on_editor_clips_selected)
		Sonara.editor.time_signature_changed.connect(_on_editor_time_signature_changed)
		Sonara.editor.playhead_moved.connect(_on_editor_playhead_moved)


func _on_editor_clips_selected(clips: Array[ClipInstance], multi_track: bool):
	"""Handle clip selection from Editor - supports both single and multi-clip modes."""
	log.info("Clips selected: %d clips, multi_track=%s" % [clips.size(), multi_track])
	# Debug: log tracks in selection
	var sel_track_names: Array[String] = []
	for ci_dbg in clips:
		if ci_dbg and ci_dbg.track and ci_dbg.track.name:
			sel_track_names.append(ci_dbg.track.name)
	if not sel_track_names.is_empty():
		log.info("  - Selection tracks: [%s]" % [", ".join(sel_track_names)])
	
	# Store pending data - will bind when we become visible
	pending_clips = clips
	pending_multi_track = multi_track

	# Update persisted state for manual toggling
	var seen_tracks: Array[Track] = []
	for ci in clips:
		if ci and ci.track:
			last_active_clip_by_track[ci.track] = ci
			if not seen_tracks.has(ci.track):
				seen_tracks.append(ci.track)
	if multi_track and not seen_tracks.is_empty():
		last_track_mode_tracks = seen_tracks.duplicate()
		last_track_mode_selected_track = seen_tracks[0]
		var seen_names: Array[String] = []
		for t_dbg in seen_tracks:
			if t_dbg and t_dbg.name:
				seen_names.append(t_dbg.name)
		log.info("  - Remembering track-mode tracks: [%s] (active='%s')" % [", ".join(seen_names), last_track_mode_selected_track.name if last_track_mode_selected_track else "null"])
	
	# If we're already visible, bind immediately
	if is_visible_in_tree():
		_bind_pending_clips()


func _on_audition_toggled(on: bool) -> void:
	midi_editor.audition_enabled = on
	Sonara.set_config(AUDITION_CONFIG_KEY, on)
	Sonara.save_config()


func _on_editor_time_signature_changed(numerator : int, denominator : int):
	# NOTE: always applied regardless of visibility. ClipEditor owns its own
	# GridHelper instance (not shared with the Arranger's), and nothing
	# resyncs it when this editor becomes visible again, so skipping the
	# update while hidden would leave grid_helper stale until the next
	# time-signature change.
	grid_helper.time_numerator = numerator
	grid_helper.time_denominator = denominator

func _on_visibility_changed():
	"""Handle visibility changes - bind pending clips when becoming visible."""
	if is_visible_in_tree():
		# focus the note editor
		midi_editor.note_editor.call_deferred("grab_focus")

		# bind the pending clips
		if not pending_clips.is_empty():
			call_deferred("_bind_pending_clips")


func _bind_pending_clips():
	"""Bind the pending clips to the editor (single-clip or track-mode)."""
	log.info("_bind_pending_clips called")
	
	if pending_clips.is_empty():
		log.info("  - No pending clips!")
		return
	
	# Store selected clips and determine mode
	selected_clips = pending_clips.duplicate()
	track_mode = pending_multi_track
	_update_mode_ui()
	
	# Extract unique tracks from selected clips
	selected_tracks.clear()
	for clip_inst in selected_clips:
		if clip_inst and clip_inst.track and not selected_tracks.has(clip_inst.track):
			selected_tracks.append(clip_inst.track)
	var st_names: Array[String] = []
	for t_name in selected_tracks:
		if t_name and t_name.name:
			st_names.append(t_name.name)
	log.info("  - Selected tracks: [%s]" % [", ".join(st_names)])

	# Remember last track-mode tracks if applicable
	if track_mode and not selected_tracks.is_empty():
		last_track_mode_tracks = selected_tracks.duplicate()
		last_track_mode_selected_track = selected_tracks[0]
	
	log.info("  - Binding %d clips, track_mode=%s, tracks=%d" % [selected_clips.size(), track_mode, selected_tracks.size()])
	
	if track_mode:
		# TRACK-MODE: Multiple clips across different tracks
		_bind_track_mode()
	else:
		# CLIP-MODE: Single clip or multiple clips on same track
		_bind_clip_mode()
	
	# Clear pending data
	pending_clips.clear()
	pending_multi_track = false


func _bind_track_mode():
	"""Bind to track-mode: multiple clips across different tracks with song-relative ruler."""
	log.info("  - Entering TRACK-MODE (song-relative positioning)")
	_update_mode_ui()
	log.info("  - Track-mode tracks: %d" % [selected_tracks.size()])
	
	# Populate track selector with selected tracks
	if track_selector:
		# Disconnect previous signal if connected
		if track_selector.track_selected.is_connected(_on_track_selector_track_selected):
			track_selector.track_selected.disconnect(_on_track_selector_track_selected)
		
		track_selector.set_tracks(selected_tracks)
		
		# Connect to track selection signal
		track_selector.track_selected.connect(_on_track_selector_track_selected)
		
		# Select the first track by default
		if not selected_tracks.is_empty():
			var initial_track = last_track_mode_selected_track if last_track_mode_selected_track and selected_tracks.has(last_track_mode_selected_track) else selected_tracks[0]
			track_selector.select_track_no_signal(initial_track)
			log.info("  - TrackList initial track: '%s'" % [initial_track.name if initial_track else "null"])
	
	# In track-mode, the ruler and grid show song-relative positions
	# The playhead conversion in _on_editor_playhead_moved will NOT subtract clip offset
	# This means tick 0 = song start, not clip start
	
	# Bind MidiEditor to track-mode
	# NOTE: MidiEditor now fetches ALL clips from each track internally
	midi_editor.bind_to_clips(selected_clips, selected_tracks)
	# Keep bound_clip_instance for reference, but track_mode flag determines playhead behavior
	if not selected_clips.is_empty():
		bound_clip_instance = selected_clips[0]

	# Restore or set active track
	if last_track_mode_selected_track and selected_tracks.has(last_track_mode_selected_track):
		midi_editor.current_track = last_track_mode_selected_track
	else:
		midi_editor.current_track = selected_tracks[0] if not selected_tracks.is_empty() else null
	log.info("  - Active track set to: '%s'" % [midi_editor.current_track.name if midi_editor and midi_editor.current_track else "null"])
	call_deferred("_apply_drum_view_preference")


func _bind_clip_mode():
	"""Bind to clip-mode: single clip with clip-local ruler (current behavior)."""
	log.info("  - Entering CLIP-MODE")
	_update_mode_ui()
	
	# Bind to the last selected clip (current behavior)
	if not selected_clips.is_empty():
		var clip_inst = selected_clips[-1]
		log.info("  - Binding to clip instance: ", clip_inst.id)
		if clip_inst and clip_inst.track:
			log.info("  - Clip's track: '%s'" % [clip_inst.track.name])
		midi_editor.bind_to_clip_instance(clip_inst)
		bound_clip_instance = clip_inst
	call_deferred("_apply_drum_view_preference")


# ============================================================================
# NOTE MAPS AND DRUM VIEW (docs/specs/002-note-maps)
# ============================================================================

func _setup_note_map_toolbar() -> void:
	mode_switch.toggled.connect(_on_mode_switch_toggled)
	note_map_button.pressed.connect(_on_note_map_button_pressed)
	note_map_popup.id_pressed.connect(_on_note_map_popup_id_pressed)
	note_map_load_button.pressed.connect(_on_note_map_load_pressed)
	note_map_edit_button.pressed.connect(_on_note_map_edit_pressed)
	note_map_save_button.pressed.connect(_on_note_map_save_pressed)
	midi_editor.view_state_changed.connect(_sync_note_map_toolbar)
	# The empty-Drum-View hint opens this same editor (REQ-023).
	midi_editor.note_map_editor_requested.connect(_on_note_map_edit_pressed)
	_sync_note_map_toolbar()


## The channel whose note map the toolbar acts on.
func _note_map_channel() -> Channel:
	return midi_editor.get_active_channel() if midi_editor else null


## Reflect the bound channel's assignment and view mode in the toolbar.
func _sync_note_map_toolbar() -> void:
	if _syncing_toolbar or mode_switch == null:
		return
	_syncing_toolbar = true

	var channel := _note_map_channel()
	var has_channel := channel != null

	mode_switch.disabled = not has_channel
	mode_switch.set_pressed_no_signal(midi_editor.drum_view)
	mode_switch.text = "Drum View" if midi_editor.drum_view else "Piano Roll"

	note_map_button.disabled = not has_channel
	note_map_load_button.disabled = not has_channel
	note_map_edit_button.disabled = not has_channel
	note_map_save_button.disabled = not has_channel
	note_map_button.text = _assignment_label(channel)

	if _note_map_editor and _note_map_editor.visible:
		_note_map_editor.refresh()

	_syncing_toolbar = false


func _assignment_label(channel: Channel) -> String:
	if channel == null:
		return "Note Map"
	match channel.note_map_mode:
		Channel.NoteMapMode.NONE:
			return "None"
		Channel.NoteMapMode.NAMED:
			var named := channel.note_map.map_name if channel.note_map else ""
			return named if not named.is_empty() else "Named Map"
		_:
			return "Auto"


## Apply the channel's remembered view preference when a clip is bound (REQ-028).
func _apply_drum_view_preference() -> void:
	if midi_editor == null:
		return
	midi_editor.refresh_note_map()
	midi_editor.drum_view = midi_editor.wants_drum_view()
	_sync_note_map_toolbar()


func _on_mode_switch_toggled(pressed: bool) -> void:
	if _syncing_toolbar:
		return
	midi_editor.drum_view = pressed
	# The choice is remembered per channel, so reopening a clip lands the same way.
	var channel := _note_map_channel()
	if channel:
		channel.set_drum_view(1 if pressed else 0)
	_sync_note_map_toolbar()


## The dropdown opens upwards: the toolbar sits at the bottom of the window, so a
## popup dropped downwards would fall off screen.
func _on_note_map_button_pressed() -> void:
	_rebuild_note_map_popup()
	var rect := note_map_button.get_global_rect()
	var popup_size := note_map_popup.get_contents_minimum_size()
	var origin := note_map_button.get_screen_transform().origin
	note_map_popup.popup(Rect2i(
		Vector2i(origin),
		Vector2i(int(maxf(rect.size.x, popup_size.x)), int(popup_size.y))
	))
	# popup() positions by the top-left corner, so lift it by its own height.
	note_map_popup.position = Vector2i(int(origin.x), int(origin.y - note_map_popup.size.y))


func _rebuild_note_map_popup() -> void:
	var channel := _note_map_channel()
	note_map_popup.clear()
	_popup_library_maps = NoteMapLibrary.list()

	note_map_popup.add_radio_check_item("None", NOTE_MAP_ID_NONE)
	note_map_popup.add_radio_check_item("Auto", NOTE_MAP_ID_AUTO)
	note_map_popup.set_item_checked(0, channel and channel.note_map_mode == Channel.NoteMapMode.NONE)
	note_map_popup.set_item_checked(1, channel and channel.note_map_mode == Channel.NoteMapMode.AUTO)
	# Auto with no source has nothing to show; still selectable, just empty.
	note_map_popup.set_item_tooltip(1, "Derived from the channel's instrument")

	if _popup_library_maps.is_empty():
		return
	note_map_popup.add_separator("Library")
	var current_name := channel.note_map.map_name if (channel and channel.note_map) else ""
	for i in _popup_library_maps.size():
		var map := _popup_library_maps[i]
		var label := map.map_name
		if not map.category.strip_edges().is_empty():
			label = "%s / %s" % [map.category, map.map_name]
		note_map_popup.add_radio_check_item(label, NOTE_MAP_LIBRARY_ID_BASE + i)
		var index := note_map_popup.get_item_index(NOTE_MAP_LIBRARY_ID_BASE + i)
		note_map_popup.set_item_checked(index,
			channel and channel.note_map_mode == Channel.NoteMapMode.NAMED and map.map_name == current_name)


func _on_note_map_popup_id_pressed(id: int) -> void:
	var channel := _note_map_channel()
	if channel == null:
		return
	if id == NOTE_MAP_ID_NONE:
		_set_assignment(channel, Channel.NoteMapMode.NONE, null)
	elif id == NOTE_MAP_ID_AUTO:
		_set_assignment(channel, Channel.NoteMapMode.AUTO, null)
	elif id >= NOTE_MAP_LIBRARY_ID_BASE:
		var index := id - NOTE_MAP_LIBRARY_ID_BASE
		if index >= 0 and index < _popup_library_maps.size():
			# A copy, so editing it on the channel never touches the library (REQ-010).
			_assign_map(channel, _popup_library_maps[index].duplicate_map())
	_after_assignment_change()


## Assign a named map as one undoable step.
func _assign_map(channel: Channel, map: NoteMap) -> void:
	var old_map: NoteMap = channel.note_map.duplicate_map() if channel.note_map else null
	HistoryUtil.execute_property("Assign Note Map", channel, "set_note_map", old_map, map)


func _set_assignment(channel: Channel, mode: Channel.NoteMapMode, map: NoteMap) -> void:
	if map:
		_assign_map(channel, map)
		return
	HistoryUtil.execute_property("Set Note Map Mode", channel, "set_note_map_mode", channel.note_map_mode, mode)


## After any assignment change the effective map, the rows and the default view
## may all differ, so re-resolve everything.
func _after_assignment_change() -> void:
	midi_editor.refresh_note_map()
	_sync_note_map_toolbar()


func _on_note_map_load_pressed() -> void:
	if _note_map_browser == null:
		_note_map_browser = NoteMapBrowserDialog.new()
		add_child(_note_map_browser)
		_note_map_browser.map_chosen.connect(_on_note_map_chosen)
	_note_map_browser.open()


func _on_note_map_chosen(map: NoteMap) -> void:
	var channel := _note_map_channel()
	if channel == null:
		return
	_assign_map(channel, map)
	_after_assignment_change()


func _on_note_map_edit_pressed() -> void:
	var channel := _note_map_channel()
	if channel == null:
		return
	open_note_map_editor(channel)


## Open the note map editor for a channel. Also the target of Drum View's
## empty-view hint (REQ-023).
func open_note_map_editor(channel: Channel) -> void:
	if _note_map_editor == null:
		_note_map_editor = NoteMapEditorDialog.new()
		add_child(_note_map_editor)
		# Auditioning reuses MidiEditor's existing preview-note path (REQ-008).
		_note_map_editor.audition_started.connect(midi_editor._start_preview_note)
		_note_map_editor.audition_stopped.connect(func(_n): midi_editor._stop_preview_note())
		_note_map_editor.map_edited.connect(_after_assignment_change)
		_note_map_editor.save_requested.connect(_open_save_dialog)
	_note_map_editor.open_for(channel)


func _on_note_map_save_pressed() -> void:
	var channel := _note_map_channel()
	if channel == null:
		return
	_open_save_dialog(NoteMapResolver.effective_map(channel))


func _open_save_dialog(map: NoteMap) -> void:
	if _note_map_save_dialog == null:
		_note_map_save_dialog = NoteMapSaveDialog.new()
		add_child(_note_map_save_dialog)
		_note_map_save_dialog.map_saved.connect(_on_note_map_saved)
	_note_map_save_dialog.open_for(map)


## Saving is also how a map gets adopted: the channel switches to the map that was
## just written, so "Save as…" on an Auto map leaves you editing the new named map
## rather than still on the read-only Auto one.
func _on_note_map_saved(saved_name: String) -> void:
	log.info("Saved note map '%s' to the library" % saved_name)
	var channel := _note_map_channel()
	var saved := NoteMapLibrary.load_map(saved_name)
	if channel and saved:
		_assign_map(channel, saved)
		_after_assignment_change()
	_sync_note_map_toolbar()


func _on_grid_helper_changed():
	"""GridHelper changes are handled automatically via signals."""
	pass


func _on_ruler_position_requested(ticks: int):
	"""Handle ruler clicks - set cursor position."""
	# In track-mode, ticks are already song-relative
	# In clip-mode, ticks are clip-local
	cursor_position_ticks = ticks
	log.info("Cursor position set to tick %d (%s)" % [ticks, "song-relative" if track_mode else "clip-local"])


func _on_editor_playhead_moved(global_playhead_ticks: int):
	"""Handle global playhead updates from Editor."""
	var playhead_ticks = 0
	
	if track_mode:
		# TRACK-MODE: Use song-relative ticks (global position)
		playhead_ticks = global_playhead_ticks
	else:
		# CLIP-MODE: Convert to clip-local ticks (relative to clip instance start)
		if bound_clip_instance:
			playhead_ticks = global_playhead_ticks - bound_clip_instance.start_ticks
	
	# Pass to MidiEditor
	if midi_editor:
		midi_editor.playhead_ticks = playhead_ticks


func _update_mode_ui():
	"""Sync UI with current mode state (toggle text/state, panels visibility)."""
	if left_panel:
		left_panel.visible = track_mode
	if track_mode_toggle:
		# Avoid feedback loop when syncing pressed state
		track_mode_toggle.set_pressed_no_signal(track_mode)
		track_mode_toggle.text = "Track Mode" if track_mode else "Clip Mode"
		# Disable only when neither a selection nor remembered tracks exist
		track_mode_toggle.disabled = selected_clips.is_empty() and pending_clips.is_empty() and last_track_mode_tracks.is_empty()
	log.info("  - UI mode: %s, left_panel=%s, toggle_disabled=%s" % ["TRACK" if track_mode else "CLIP", str(left_panel.visible if left_panel else false), str(track_mode_toggle.disabled if track_mode_toggle else false)])


func _on_track_mode_toggle_toggled(pressed: bool):
	"""Handle manual toggle between track-mode and clip-mode."""
	log.info("Toggle pressed: %s (sel_clips=%d, remembered_tracks=%d)" % [str(pressed), selected_clips.size(), last_track_mode_tracks.size()])
	# If turning ON without selection, try to restore last track-mode tracks
	if pressed and selected_clips.is_empty() and pending_clips.is_empty() and not last_track_mode_tracks.is_empty():
		selected_tracks = last_track_mode_tracks.duplicate()
		selected_clips.clear()
		track_mode = true
		_update_mode_ui()
		_bind_track_mode()
		log.info("  - Restored track-mode from memory (%d tracks)" % [selected_tracks.size()])
		return

	# If we truly have nothing to bind, just sync UI and bail
	if selected_clips.is_empty() and pending_clips.is_empty() and last_track_mode_tracks.is_empty():
		track_mode = pressed
		_update_mode_ui()
		log.info("  - No selection or memory available, mode now: %s" % ["TRACK" if track_mode else "CLIP"])
		return

	track_mode = pressed
	_update_mode_ui()

	if track_mode:
		# Ensure tracks list is populated: prefer last seen track list
		if not last_track_mode_tracks.is_empty():
			selected_tracks = last_track_mode_tracks.duplicate()
		elif selected_tracks.is_empty() and not selected_clips.is_empty():
			for clip_inst in selected_clips:
				if clip_inst and clip_inst.track and not selected_tracks.has(clip_inst.track):
					selected_tracks.append(clip_inst.track)
		_bind_track_mode()
		log.info("  - Switched to TRACK mode (%d tracks)" % [selected_tracks.size()])
	else:
		# Switching to clip-mode: focus last active clip of current selected track
		var current_t = midi_editor.current_track if midi_editor else last_track_mode_selected_track
		if not current_t and not selected_tracks.is_empty():
			current_t = selected_tracks[0]
		var target_clip = _select_last_active_clip_for_track(current_t)
		if target_clip:
			selected_clips = [target_clip]
			selected_tracks = [current_t] as Array[Track] if current_t else [] as Array[Track]
		_bind_clip_mode()
		log.info("  - Switched to CLIP mode (clip_id=%s, track='%s')" % [str(selected_clips[0].id) if not selected_clips.is_empty() else "null", current_t.name if current_t else "null"])


func _on_track_selector_track_selected(track: Track):
	"""Handle track selection from track selector - update active track in MidiEditor."""
	log.info("Track selected from selector: %s" % track.name)
	if midi_editor and track_mode:
		midi_editor.current_track = track
		last_track_mode_selected_track = track
		log.info("  - Active track changed to: '%s'" % [track.name])
	track_mode_track_selected.emit(track)


func _select_last_active_clip_for_track(track: Track) -> ClipInstance:
	"""Find the last active clip instance for the given track using history, current selection, or track clips."""
	if not track:
		return null
	# 1) Prefer remembered clip for this track
	if track in last_active_clip_by_track:
		var ci_mem: ClipInstance = last_active_clip_by_track[track]
		log.info("  - last_active_clip_by_track hit for '%s': clip_id=%s" % [track.name, str(ci_mem.id) if ci_mem else "null"])
		return last_active_clip_by_track[track]
	# 2) Prefer a selected clip for this track (most recent at end of list)
	for i in range(selected_clips.size() - 1, -1, -1):
		var ci = selected_clips[i]
		if ci and ci.track == track:
			log.info("  - using selected clip for '%s': clip_id=%s" % [track.name, str(ci.id)])
			return ci
	# 3) Fallback to last clip on the track, if available
	if track.clip_instances and not track.clip_instances.is_empty():
		var last_ci: ClipInstance = track.clip_instances[-1]
		log.info("  - fallback last clip on track '%s': clip_id=%s" % [track.name, str(last_ci.id) if last_ci else "null"])
		return last_ci
	return null
