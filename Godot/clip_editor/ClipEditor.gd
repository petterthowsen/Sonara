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
@onready var all_visible_toggle: Button = $HSplit/LeftPanel/VBox/Header/HeaderMargin/HeaderRow/AllVisibleToggle
@onready var all_editable_toggle: Button = $HSplit/LeftPanel/VBox/Header/HeaderMargin/HeaderRow/AllEditableToggle
@onready var clip_name_label: Label = $HSplit/MainPanel/VBox/PanelContainer/MainHeader/MainOptions/ClipNameLabel

## Same ruler rows and gestures as the arranger. Its ticks are the note editor's:
## clip-content ticks in clip mode, song ticks in track mode (see _ruler_to_song_ticks).
@onready var ruler: RulerStack = $HSplit/MainPanel/VBox/PanelContainer/VBox/Ruler

@onready var midi_editor: MidiEditor = $HSplit/MainPanel/VBox/EditorSplit/MidiEditor

## Velocity / release lanes under the note area (docs/specs/019-note-values).
@onready var value_pane: NoteValuePane = $HSplit/MainPanel/VBox/EditorSplit/NoteValuePane
@onready var value_lanes_toggle: Button = $BottomPanel/Toolbar/LanesGroup/ValueLanesToggle
## Velocity the next drawn note gets (the last touched note's, or what the user typed).
@onready var next_value_spin: SpinBox = $BottomPanel/Toolbar/LanesGroup/NextValue

## Selection tools (quantize, mirror, strum): one button each, see _register_selection_tool.
@onready var tools_group: HBoxContainer = $BottomPanel/Toolbar/ToolsGroup

@onready var audition_toggle: Button = $BottomPanel/Toolbar/ToggleGroup/AuditionToggle
@onready var fold_to_scale_toggle: Button = $BottomPanel/Toolbar/ToggleGroup/FoldToScaleToggle
@onready var scale_snap_toggle: Button = $BottomPanel/Toolbar/ToggleGroup/ScaleSnapToggle
const AUDITION_CONFIG_KEY := "clip_editor/audition"

# Note map / Drum View toolbar (docs/specs/002-note-maps)
@onready var mode_switch: Button = $BottomPanel/Toolbar/ModeGroup/ModeSwitch
@onready var note_map_button: Button = $BottomPanel/Toolbar/ModeGroup/NoteMapButton
@onready var note_map_popup: PopupMenu = $BottomPanel/Toolbar/ModeGroup/NoteMapButton/NoteMapPopup

## Popup item ids. Library entries use LIBRARY_ID_BASE + index.
const NOTE_MAP_ID_NONE := 0
const NOTE_MAP_ID_AUTO := 1
const NOTE_MAP_ID_LOAD := 2
const NOTE_MAP_ID_EDIT := 3
const NOTE_MAP_ID_SAVE := 4
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

## Visibility, editability and solo of every listed track. Lives for the whole session so the
## states survive rebinds and clip/track mode switches; never persisted.
var track_toggles := TrackToggleState.new()
## Set while the toggle state is being changed in bulk, so _apply_track_toggles runs once.
var _suppress_toggle_apply := false

# Selected clips and tracks (for track-mode)
var selected_clips: Array[ClipInstance] = []
var selected_tracks: Array[Track] = []

# Store pending clip data until we become visible
var pending_clips: Array[ClipInstance] = []
var pending_multi_track: bool = false

# Track the currently bound clip instance for playhead conversion (single-clip mode)
var bound_clip_instance: ClipInstance = null
## Clip whose clip_modified the header name follows.
var _named_clip: Clip = null

func _ready():
	Hotkeys.set_context(self, "clip_editor")
	grid_helper = GridHelper.new()
	# The MIDI editor grid follows its own spacing setting, independent of the
	# arranger's (a piano roll wants a finer grid than the timeline).
	grid_helper.spacing_setting = GridHelper.MIDI_EDITOR_SPACING_SETTING
	
	# Connect GridHelper signals
	grid_helper.changed.connect(_on_grid_helper_changed)
	
	# Connect to visibility changes
	visibility_changed.connect(_on_visibility_changed)
	
	# Ruler: click-drag moves start position + playhead, Ctrl/Cmd sets a time range
	ruler.start_position_requested.connect(_on_ruler_position_requested)
	ruler.selection_start_requested.connect(_on_ruler_selection_start_requested)
	ruler.box_select_started.connect(_on_ruler_box_select_started)
	midi_editor.current_track_changed.connect(_mark_ruler_context_dirty)
	midi_editor.note_track_picked.connect(_on_note_track_picked)
	track_toggles.changed.connect(_on_track_toggles_changed)
	track_selector.track_selected.connect(_on_track_selector_track_selected)
	track_selector.track_selected_additive.connect(_on_track_selector_track_selected.bind(true))
	track_selector.tracks_changed.connect(_on_track_list_changed)
	all_visible_toggle.pressed.connect(_on_all_toggle_pressed.bind(TrackToggleState.Kind.VISIBLE))
	all_editable_toggle.pressed.connect(_on_all_toggle_pressed.bind(TrackToggleState.Kind.EDITABLE))
	track_toggles.changed.connect(_refresh_all_toggles)
	track_selector.tracks_changed.connect(_refresh_all_toggles)
	
	# Wire up Track/Clip mode toggle
	if track_mode_toggle:
		track_mode_toggle.toggled.connect(_on_track_mode_toggle_toggled)
		_update_mode_ui()
	
	var audition_on: bool = Sonara.get_config(AUDITION_CONFIG_KEY, false)
	audition_toggle.set_pressed_no_signal(audition_on)
	midi_editor.audition_enabled = audition_on
	audition_toggle.toggled.connect(_on_audition_toggled)
	
	_setup_note_map_toolbar()
	_setup_selection_tools()
	_setup_value_lanes()

	fold_to_scale_toggle.toggled.connect(_on_scale_view_toggled.bind("fold_to_scale"))
	scale_snap_toggle.toggled.connect(_on_scale_view_toggled.bind("scale_snap"))
	midi_editor.view_state_changed.connect(_sync_scale_toggles)

	_editor = Sonara.editor
	if _editor:
		_editor.project_opened.connect(func(p: Project): _bind_project_scale(p))
		_editor.playback_started.connect(func(): midi_editor.transport_playing = true)
		_editor.playback_stopped.connect(func(): midi_editor.transport_playing = false)
	if Sonara.editor:
		Sonara.editor.clips_selected.connect(_on_editor_clips_selected)
		Sonara.editor.time_signature_changed.connect(_on_editor_time_signature_changed)
		Sonara.editor.playhead_moved.connect(_on_editor_playhead_moved)
	_bind_project_scale()


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


## Bind the value pane (the grid helper is set by now) and its toolbar toggle.
func _setup_value_lanes() -> void:
	value_pane.bind(midi_editor)
	value_lanes_toggle.set_pressed_no_signal(value_pane.visible)
	value_lanes_toggle.toggled.connect(value_pane.set_lanes_visible)
	value_pane.note_touched.connect(midi_editor.next_note_values.take_from)
	_setup_next_value()


## The toolbar readout of the next note's velocity: shows it and edits it without touching
## any note. Follows the display-format setting (0–127 or percent).
func _setup_next_value() -> void:
	next_value_spin.value_changed.connect(_on_next_value_edited)
	midi_editor.next_note_values.changed.connect(_refresh_next_value)
	Settings.setting_changed.connect(func(key, _v): if key == "clip_editor/note_value_display": _refresh_next_value())
	_refresh_next_value()


func _next_value_scale() -> float:
	return 100.0 if NoteValueDescriptors.display_mode() == NoteValueDescriptor.DISPLAY_PERCENT else 127.0


func _refresh_next_value() -> void:
	var scale_to := _next_value_scale()
	next_value_spin.min_value = roundf(MidiNoteData.MIN_VELOCITY * scale_to) if scale_to == 127.0 else 1.0
	next_value_spin.max_value = scale_to
	next_value_spin.suffix = "%" if scale_to == 100.0 else ""
	next_value_spin.set_value_no_signal(roundf(midi_editor.next_note_values.velocity * scale_to))


func _on_next_value_edited(v: float) -> void:
	midi_editor.next_note_values.velocity = v / _next_value_scale()


func _unhandled_key_input(event: InputEvent) -> void:
	if is_visible_in_tree():
		for entry in [["toggle_scale_snap", scale_snap_toggle], ["toggle_fold_to_scale", fold_to_scale_toggle]]:
			if Hotkeys.pressed(event, entry[0]):
				var toggle: Button = entry[1]
				if not toggle.disabled:
					toggle.button_pressed = not toggle.button_pressed
				get_viewport().set_input_as_handled()
				return
	if is_visible_in_tree() and Hotkeys.pressed(event, "toggle_note_value_lanes"):
		value_lanes_toggle.button_pressed = not value_lanes_toggle.button_pressed
		get_viewport().set_input_as_handled()


## The project whose scale and clip_editor_view the toolbar is bound to.
var _scale_project: Project = null


## Follow `p`'s scale and view flags (default: the current project). Called on _ready and when
## the Editor opens a project; disconnects from the previous one.
func _bind_project_scale(p: Project = null) -> void:
	if p == null:
		p = _project()
	if _scale_project != null and is_instance_valid(_scale_project):
		if _scale_project.scale_changed.is_connected(_on_project_scale_changed):
			_scale_project.scale_changed.disconnect(_on_project_scale_changed)
		if _scale_project.clip_editor_view_changed.is_connected(_on_project_view_changed):
			_scale_project.clip_editor_view_changed.disconnect(_on_project_view_changed)
	_scale_project = p
	if _scale_project != null:
		_scale_project.scale_changed.connect(_on_project_scale_changed)
		_scale_project.clip_editor_view_changed.connect(_on_project_view_changed)
	_refresh_scale_context()


func _on_project_scale_changed(_root: int, _type_id: String) -> void:
	_refresh_scale_context()


func _on_project_view_changed(_key: String, _value: bool) -> void:
	_refresh_scale_context()


## Push the project scale and flags into the MIDI editor and sync the toolbar widgets.
func _refresh_scale_context() -> void:
	var ctx := midi_editor.scale_context
	var p := _scale_project
	ctx.scale = p.get_scale() if p != null else MusicalScale.new()
	ctx.snap_enabled = p != null and p.get_clip_editor_view("scale_snap")
	ctx.fold_enabled = p != null and p.get_clip_editor_view("fold_to_scale")
	fold_to_scale_toggle.set_pressed_no_signal(ctx.fold_enabled)
	scale_snap_toggle.set_pressed_no_signal(ctx.snap_enabled)
	_sync_scale_toggles()
	_sync_selection_tools()


## The scale toggles need a scale and the piano roll (not Drum View).
func _sync_scale_toggles() -> void:
	var usable: bool = not midi_editor.scale_context.scale.is_none() and not midi_editor.drum_view
	fold_to_scale_toggle.disabled = not usable
	scale_snap_toggle.disabled = not usable


func _on_scale_view_toggled(on: bool, key: String) -> void:
	if _scale_project != null:
		_scale_project.set_clip_editor_view(key, on)


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
	_apply_signature_context()


## Point the grid at the project's time signature changes. Track mode shows song ticks, so it
## follows the map. Clip mode shows clip-local ticks (bar 1 is the clip start), so it uses the
## signature in effect where the clip starts.
func _apply_signature_context() -> void:
	var project := _project()
	if project == null:
		return
	var map := project.time_signature_map
	if not map.changed.is_connected(_apply_signature_context):
		map.changed.connect(_apply_signature_context)
	var num := project.time_numerator
	var den := project.time_denominator
	if track_mode or bound_clip_instance == null:
		grid_helper.time_signature_map = map
	else:
		grid_helper.time_signature_map = null
		var sig := map.signature_at_tick(bound_clip_instance.start_ticks, num, den, project.ppq)
		num = sig.x
		den = sig.y
	grid_helper.time_numerator = num
	grid_helper.time_denominator = den

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
		# TRACK-MODE: Multiple clips across different tracks. A new selection resets the
		# visibility/editability of every track (REQ-021).
		_bind_track_mode(true)
	else:
		# CLIP-MODE: Single clip or multiple clips on same track
		_bind_clip_mode()
	
	# Clear pending data
	pending_clips.clear()
	pending_multi_track = false


## `from_selection`: entered from a new arranger selection, so the toggles are reset from it.
## Otherwise (re-entry) the toggle states of the previous track-mode session are kept (REQ-021).
func _bind_track_mode(from_selection: bool = false):
	"""Bind to track-mode: every instrument track listed, the visible ones drawn."""
	log.info("  - Entering TRACK-MODE (song-relative positioning)")
	_update_mode_ui()
	_apply_signature_context()
	log.info("  - Track-mode tracks: %d" % [selected_tracks.size()])

	_suppress_toggle_apply = true
	track_selector.set_toggle_state(track_toggles)
	track_selector.set_project(_project())
	track_selector.rebuild_now()
	var listed := _listed_tracks()
	if from_selection:
		track_toggles.init_from_selection(listed, selected_tracks)
	else:
		track_toggles.set_tracks(listed)
	_suppress_toggle_apply = false

	# In track-mode, the ruler and grid show song-relative positions
	# The playhead conversion in _on_editor_playhead_moved will NOT subtract clip offset
	# This means tick 0 = song start, not clip start

	# Bind MidiEditor to track-mode
	# NOTE: MidiEditor now fetches ALL clips from each track internally
	midi_editor.bind_to_clips(selected_clips, _visible_tracks())
	# Keep bound_clip_instance for reference, but track_mode flag determines playhead behavior
	if not selected_clips.is_empty():
		bound_clip_instance = selected_clips[0]

	# Restore the remembered active track when it is still editable, else the first editable one
	var preferred: Track = last_track_mode_selected_track if listed.has(last_track_mode_selected_track) else null
	_apply_track_toggles(preferred)
	_refresh_all_toggles()
	log.info("  - Active track set to: '%s'" % [midi_editor.current_track.name if midi_editor and midi_editor.current_track else "null"])
	call_deferred("_apply_drum_view_preference")
	_mark_ruler_context_dirty()


## The project the listed tracks come from.
func _project() -> Project:
	if _editor and _editor.project:
		return _editor.project
	for t in selected_tracks + last_track_mode_tracks:
		if t and t.get_project_ref():
			return t.get_project_ref()
	return null


func _listed_tracks() -> Array[Track]:
	return track_selector.listed_tracks()


func _visible_tracks() -> Array[Track]:
	var out: Array[Track] = []
	for t in _listed_tracks():
		if track_toggles.is_on(t, TrackToggleState.Kind.VISIBLE):
			out.append(t)
	return out


## Header toggles: turn every listed track on, or off when they all already are.
func _on_all_toggle_pressed(kind: int) -> void:
	var listed := _listed_tracks()
	track_toggles.set_all(listed, kind, not track_toggles.all_on(listed, kind))


func _refresh_all_toggles() -> void:
	var listed := _listed_tracks()
	var vis := track_toggles.all_on(listed, TrackToggleState.Kind.VISIBLE)
	var edit := track_toggles.all_on(listed, TrackToggleState.Kind.EDITABLE)
	all_visible_toggle.icon = ClipEditorTrackListItem.EYE_ON if vis else ClipEditorTrackListItem.EYE_OFF
	all_editable_toggle.icon = ClipEditorTrackListItem.PENCIL_ON if edit else ClipEditorTrackListItem.PENCIL_OFF
	# Mixed states (some tracks on) read as dimmed rather than as "off".
	all_visible_toggle.modulate.a = 1.0 if vis or not _any_on(listed, TrackToggleState.Kind.VISIBLE) else 0.6
	all_editable_toggle.modulate.a = 1.0 if edit or not _any_on(listed, TrackToggleState.Kind.EDITABLE) else 0.6


func _any_on(tracks: Array[Track], kind: int) -> bool:
	for t in tracks:
		if track_toggles.is_on(t, kind):
			return true
	return false


func _on_track_toggles_changed() -> void:
	if not _suppress_toggle_apply and track_mode:
		_apply_track_toggles()


func _on_track_list_changed() -> void:
	# Tracks were added, removed or reordered in the project.
	if track_mode and not _suppress_toggle_apply:
		track_toggles.set_tracks(_listed_tracks())
		_apply_track_toggles()


## Pushes the toggle state to the note editor and repairs the selection (REQ-022, 031, 032).
## `preferred` is selected when it is editable.
func _apply_track_toggles(preferred: Track = null) -> void:
	if not track_mode:
		return
	var listed := _listed_tracks()
	var editable: Array[Track] = []
	for t in listed:
		if track_toggles.is_editable(t):
			editable.append(t)
	midi_editor.set_track_views(_visible_tracks(), selected_clips)
	midi_editor.editable_tracks = editable
	_ensure_valid_selection(preferred)
	_mark_ruler_context_dirty()


## Keeps the selected track effectively editable: the current one if it is, else `preferred`,
## else the first editable track in list order, else none (REQ-031).
func _ensure_valid_selection(preferred: Track = null) -> void:
	var listed := _listed_tracks()
	var current: Track = midi_editor.current_track
	var target: Track = null
	if preferred and track_toggles.is_editable(preferred):
		target = preferred
	elif current and listed.has(current) and track_toggles.is_editable(current):
		target = current
	else:
		target = track_toggles.first_editable(listed)
	var changed: bool = target != current
	if changed:
		midi_editor.current_track = target
	track_selector.select_track_no_signal(target)
	if target:
		last_track_mode_selected_track = target
		if changed:
			track_mode_track_selected.emit(target)


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
		_apply_signature_context()
		_update_clip_name()
	call_deferred("_apply_drum_view_preference")
	_mark_ruler_context_dirty()


# ============================================================================
# NOTE MAPS AND DRUM VIEW (docs/specs/002-note-maps)
# ============================================================================

func _setup_note_map_toolbar() -> void:
	mode_switch.toggled.connect(_on_mode_switch_toggled)
	note_map_button.pressed.connect(_on_note_map_button_pressed)
	note_map_popup.id_pressed.connect(_on_note_map_popup_id_pressed)
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

	if not _popup_library_maps.is_empty():
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

	note_map_popup.add_separator()
	note_map_popup.add_item("Load...", NOTE_MAP_ID_LOAD)
	note_map_popup.set_item_tooltip(note_map_popup.get_item_index(NOTE_MAP_ID_LOAD), "Load a note map from the library")
	note_map_popup.add_item("Edit...", NOTE_MAP_ID_EDIT)
	note_map_popup.set_item_tooltip(note_map_popup.get_item_index(NOTE_MAP_ID_EDIT), "Edit this channel's note map")
	note_map_popup.add_item("Save...", NOTE_MAP_ID_SAVE)
	note_map_popup.set_item_tooltip(note_map_popup.get_item_index(NOTE_MAP_ID_SAVE), "Save this note map to the library")


func _on_note_map_popup_id_pressed(id: int) -> void:
	var channel := _note_map_channel()
	if channel == null:
		return
	if id == NOTE_MAP_ID_LOAD:
		_on_note_map_load_pressed()
		return
	if id == NOTE_MAP_ID_EDIT:
		_on_note_map_edit_pressed()
		return
	if id == NOTE_MAP_ID_SAVE:
		_on_note_map_save_pressed()
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


# ============================================================================
# SELECTION TOOLS (docs/midi-editor-qol-plan.md, phase 2)
# ============================================================================

## Tool button -> {"run": Callable, "drum": bool}. A button is enabled only when it has an entry
## here, notes are selected and, in Drum View, the tool says it applies there. Each tool adds its
## entry with _register_selection_tool; the tool's work goes through
## NoteEditor._apply_selection_edit, so it is one undo/redo step.
var _selection_tools := {}


func _setup_selection_tools() -> void:
	midi_editor.selection_changed.connect(_sync_selection_tools)
	midi_editor.view_state_changed.connect(_sync_selection_tools)
	midi_editor.current_track_changed.connect(_sync_selection_tools)
	_register_selection_tool(tools_group.find_child("Quantize", true, false) as Button,
			func(editor: NoteEditor): editor.quantize_selection(), true)
	_register_selection_tool(tools_group.find_child("FlipVertical", true, false) as Button,
			func(editor: NoteEditor): editor.flip_selection_vertical(), false)
	_register_selection_tool(tools_group.find_child("FlipHorizontal", true, false) as Button,
			func(editor: NoteEditor): editor.flip_selection_horizontal(), true)
	_register_selection_tool(tools_group.find_child("Strum", true, false) as Button,
			func(editor: NoteEditor): editor.strum_selection(), false)
	_register_selection_tool(tools_group.find_child("ConformToScale", true, false) as Button,
			func(editor: NoteEditor): editor.conform_selection_to_scale(), false, true)
	tools_group.find_child("QuantizeOptions", true, false).pressed.connect(_on_quantize_options_pressed)
	tools_group.find_child("StrumOptions", true, false).pressed.connect(_on_strum_options_pressed)
	_sync_selection_tools()


func _register_selection_tool(button: Button, run: Callable, works_in_drum_view: bool, needs_scale := false) -> void:
	_selection_tools[button] = {"run": run, "drum": works_in_drum_view, "scale": needs_scale}
	button.pressed.connect(func():
		var editor := midi_editor.get_active_note_editor()
		if editor == null:
			return
		# Clip mode: no selection means "all notes". Track mode requires a selection.
		if editor.selection_manager.selected_notes.is_empty() and not midi_editor.track_mode:
			editor.selection_manager.select_all(editor.get_all_visual_notes())
		run.call(editor))
	_sync_selection_tools()


var _quantize_popup: PopupPanel = null
var _quantize_strength_slider: HSlider = null
var _quantize_strength_label: Label = null
var _quantize_mode_check: CheckBox = null


## Strength and mode of Quantize. The values persist and the Ctrl+Q hotkey uses them too.
func _on_quantize_options_pressed() -> void:
	if _quantize_popup == null:
		_build_quantize_popup()
	_quantize_strength_slider.set_value_no_signal(NoteEditor.quantize_strength() * 100.0)
	_quantize_strength_label.text = "Strength %d%%" % roundi(_quantize_strength_slider.value)
	_quantize_mode_check.set_pressed_no_signal(
			NoteEditor.quantize_mode() == NoteTransforms.QuantizeMode.START_AND_END)
	var button: Button = tools_group.find_child("QuantizeOptions", true, false)
	var origin := button.get_screen_transform().origin
	_quantize_popup.reset_size()
	_quantize_popup.popup(Rect2i(Vector2i(origin), _quantize_popup.get_contents_minimum_size()))
	# The toolbar is at the bottom of the window: lift the popup above the button.
	_quantize_popup.position = Vector2i(int(origin.x), int(origin.y - _quantize_popup.size.y))


func _build_quantize_popup() -> void:
	_quantize_popup = PopupPanel.new()
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(220, 0)
	_quantize_popup.add_child(box)
	_quantize_strength_label = Label.new()
	box.add_child(_quantize_strength_label)
	_quantize_strength_slider = HSlider.new()
	_quantize_strength_slider.min_value = 0
	_quantize_strength_slider.max_value = 100
	_quantize_strength_slider.step = 1
	_quantize_strength_slider.tooltip_text = "100% snaps notes to the grid; less moves them part of the way."
	_quantize_strength_slider.value_changed.connect(func(v: float):
		_quantize_strength_label.text = "Strength %d%%" % roundi(v)
		Sonara.set_config(NoteEditor.QUANTIZE_STRENGTH_KEY, v / 100.0))
	_quantize_strength_slider.drag_ended.connect(func(_changed: bool): Sonara.save_config())
	box.add_child(_quantize_strength_slider)
	_quantize_mode_check = CheckBox.new()
	_quantize_mode_check.text = "Quantize note ends too"
	_quantize_mode_check.tooltip_text = "Also snap each note's end, so its length follows the grid."
	_quantize_mode_check.toggled.connect(func(on: bool):
		Sonara.set_config(NoteEditor.QUANTIZE_MODE_KEY,
				NoteTransforms.QuantizeMode.START_AND_END if on else NoteTransforms.QuantizeMode.START)
		Sonara.save_config())
	box.add_child(_quantize_mode_check)
	add_child(_quantize_popup)


var _strum_popup: PopupPanel = null
var _strum_spread_slider: HSlider = null
var _strum_spread_label: Label = null
var _strum_direction_option: OptionButton = null
var _strum_ramp_slider: HSlider = null
var _strum_ramp_label: Label = null


## Spread, direction and velocity ramp of Strum. The values persist and Ctrl+Shift+S uses them too.
func _on_strum_options_pressed() -> void:
	if _strum_popup == null:
		_build_strum_popup()
	_strum_spread_slider.set_value_no_signal(NoteEditor.strum_spread())
	_strum_spread_label.text = "Spread %d ticks" % roundi(_strum_spread_slider.value)
	_strum_direction_option.select(NoteEditor.strum_direction())
	_strum_ramp_slider.set_value_no_signal(NoteEditor.strum_velocity_ramp() * 100.0)
	_strum_ramp_label.text = "Velocity ramp %+d%%" % roundi(_strum_ramp_slider.value)
	var button: Button = tools_group.find_child("StrumOptions", true, false)
	var origin := button.get_screen_transform().origin
	_strum_popup.reset_size()
	_strum_popup.popup(Rect2i(Vector2i(origin), _strum_popup.get_contents_minimum_size()))
	_strum_popup.position = Vector2i(int(origin.x), int(origin.y - _strum_popup.size.y))


func _build_strum_popup() -> void:
	_strum_popup = PopupPanel.new()
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(240, 0)
	_strum_popup.add_child(box)
	_strum_spread_label = Label.new()
	box.add_child(_strum_spread_label)
	_strum_spread_slider = HSlider.new()
	_strum_spread_slider.min_value = 0
	_strum_spread_slider.max_value = 240
	_strum_spread_slider.step = 1
	_strum_spread_slider.tooltip_text = "Delay between neighbouring chord notes, in ticks (960 per quarter note)."
	_strum_spread_slider.value_changed.connect(func(v: float):
		_strum_spread_label.text = "Spread %d ticks" % roundi(v)
		Sonara.set_config(NoteEditor.STRUM_SPREAD_KEY, roundi(v)))
	_strum_spread_slider.drag_ended.connect(func(_changed: bool): Sonara.save_config())
	box.add_child(_strum_spread_slider)
	_strum_direction_option = OptionButton.new()
	_strum_direction_option.add_item("Up (low to high)", NoteTransforms.StrumDirection.UP)
	_strum_direction_option.add_item("Down (high to low)", NoteTransforms.StrumDirection.DOWN)
	_strum_direction_option.add_item("Alternate", NoteTransforms.StrumDirection.ALTERNATE)
	_strum_direction_option.tooltip_text = "Order the chord notes are played in. Alternate flips direction every chord."
	_strum_direction_option.item_selected.connect(func(index: int):
		Sonara.set_config(NoteEditor.STRUM_DIRECTION_KEY, _strum_direction_option.get_item_id(index))
		Sonara.save_config())
	box.add_child(_strum_direction_option)
	_strum_ramp_label = Label.new()
	box.add_child(_strum_ramp_label)
	_strum_ramp_slider = HSlider.new()
	_strum_ramp_slider.min_value = -100
	_strum_ramp_slider.max_value = 100
	_strum_ramp_slider.step = 1
	_strum_ramp_slider.tooltip_text = "Velocity added across the strum: the first note is unchanged, the last gets the full amount."
	_strum_ramp_slider.value_changed.connect(func(v: float):
		_strum_ramp_label.text = "Velocity ramp %+d%%" % roundi(v)
		Sonara.set_config(NoteEditor.STRUM_RAMP_KEY, v / 100.0))
	_strum_ramp_slider.drag_ended.connect(func(_changed: bool): Sonara.save_config())
	box.add_child(_strum_ramp_slider)
	add_child(_strum_popup)


func _sync_selection_tools() -> void:
	var editor := midi_editor.get_active_note_editor() if midi_editor else null
	var has_selection: bool = editor != null and editor.selection_manager != null \
			and not editor.selection_manager.selected_notes.is_empty()
	var can_run: bool = has_selection or (editor != null and not midi_editor.track_mode)
	for button: Button in tools_group.find_children("*", "Button", true, false):
		if button.name == &"QuantizeOptions" or button.name == &"StrumOptions":
			continue  # always usable: it only sets the remembered options
		var entry: Dictionary = _selection_tools.get(button, {})
		button.disabled = entry.is_empty() or not can_run \
				or (midi_editor.drum_view and not entry["drum"]) \
				or (entry["scale"] and midi_editor.scale_context.scale.is_none())


func _on_grid_helper_changed():
	"""GridHelper changes are handled automatically via signals."""
	pass


# ============================================================================
# RULER: coordinates, start position, time range and context regions
# ============================================================================

## Ruler/editor ticks -> song ticks. Track mode is already song-relative; clip mode is
## clip-content ticks, placed where the bound instance plays them.
func _ruler_to_song_ticks(ticks: int) -> int:
	if track_mode or not bound_clip_instance:
		return ticks
	return bound_clip_instance.clip_to_song_ticks(ticks)


func _song_to_ruler_ticks(ticks: int) -> int:
	if track_mode or not bound_clip_instance:
		return ticks
	return bound_clip_instance.song_to_clip_ticks(ticks)


## Ruler click/drag: same as the arranger's ruler (start position + playhead), plus the
## editor's own paste cursor.
func _on_ruler_position_requested(ticks: int):
	cursor_position_ticks = ticks
	_ruler_range_start = -1
	# A bare time range (no notes) would win over the cursor as the paste target, so a
	# plain click drops it, like it drops a pending range start.
	var active = midi_editor.get_active_note_editor()
	if active and active.selection_manager and active.selection_manager.selected_notes.is_empty() \
			and active.selection_manager.has_range():
		active.selection_manager.set_range(-1, -1)
		midi_editor._update_selection_overlays()
	var song_ticks := maxi(0, _ruler_to_song_ticks(ticks))
	var project: Project = _editor.project if _editor else null
	if project:
		project.set_start_position(song_ticks)
	if _editor:
		_editor.set_playhead(song_ticks)


## Ctrl/Cmd click: drop the note selection and mark a range start, which is also where
## the next paste lands (like the arranger's range start).
func _on_ruler_selection_start_requested(ticks: int) -> void:
	var active = midi_editor.get_active_note_editor()
	if active and active.selection_manager:
		active.selection_manager.clear_selection()
		active.selection_manager.selection_changed.emit(active.selection_manager.selected_notes)
	cursor_position_ticks = ticks
	_ruler_range_start = ticks
	midi_editor._update_selection_overlays()


## Ctrl/Cmd drag: a time-range box select spanning every pitch.
func _on_ruler_box_select_started(content_x: float) -> void:
	_ruler_range_start = -1
	midi_editor.begin_time_range_selection(content_x)


## Cached at _ready: Sonara.editor is looked up per frame here, and the getter errors
## when there is no Editor (headless tests).
var _editor: Editor = null

## Range start set by a Ctrl/Cmd click, shown until a real range or a plain click replaces it.
var _ruler_range_start := -1

## Set when the clips or tracks the ruler regions come from changed.
var _ruler_context_dirty := true
## [signal, callable] pairs connected for region refreshes, so they can be undone.
var _ruler_watch: Array = []


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	# Line the ruler up with the note grid whatever sits to its left: the offset is the
	# distance from the ruler's left edge to the note area's.
	ruler.offset_x = midi_editor.note_area.global_position.x - ruler.global_position.x

	var project: Project = _editor.project if _editor else null
	var has_binding := track_mode or bound_clip_instance != null
	ruler.set_start_position_visible(project != null and has_binding)
	if project and has_binding:
		ruler.set_start_position(_song_to_ruler_ticks(project.start_position_ticks))

	_sync_ruler_selection()

	if _ruler_context_dirty:
		_ruler_context_dirty = false
		_rebuild_ruler_regions()


## Mirror the active note selection's range (or a pending range start) onto the ruler.
func _sync_ruler_selection() -> void:
	var active = midi_editor.get_active_note_editor()
	var sm: NoteSelectionManager = active.selection_manager if active else null
	if sm and sm.box_selection_end_tick > sm.box_selection_start_tick:
		_ruler_range_start = -1
		ruler.set_selection_range(sm.box_selection_start_tick, sm.box_selection_end_tick)
	elif _ruler_range_start >= 0:
		ruler.set_selection_range(_ruler_range_start, _ruler_range_start)
	else:
		ruler.set_selection_range(-1, -1)


func _mark_ruler_context_dirty() -> void:
	_ruler_context_dirty = true


## Track-coloured spans behind the ruler: in clip mode the bound instance's played window
## (with edges); in track mode every clip of the active track, over fainter clips of the
## other tracks on screen. Gaps between clips stay plain.
func _rebuild_ruler_regions() -> void:
	_unwatch_ruler_context()
	var regions: Array = []
	if track_mode:
		var active_track: Track = midi_editor.current_track
		var others: Array = []
		var mine: Array = []
		for t in _visible_tracks():
			if not is_instance_valid(t):
				continue
			_watch_ruler(t.color_changed, _mark_ruler_context_dirty.unbind(1))
			_watch_ruler(t.clip_instance_added, _mark_ruler_context_dirty.unbind(1))
			_watch_ruler(t.clip_instance_removed, _mark_ruler_context_dirty.unbind(1))
			var is_active := t == active_track
			for ci in t.clip_instances:
				if not ci:
					continue
				_watch_ruler(ci.instance_modified, _mark_ruler_context_dirty)
				var c := Utils.display_color(t.color)
				c.a = 0.38 if is_active else 0.12
				var region := {"start": ci.start_ticks, "end": ci.get_end_ticks(), "color": c, "edges": is_active}
				(mine if is_active else others).append(region)
		regions = others + mine
	elif bound_clip_instance and is_instance_valid(bound_clip_instance):
		var ci := bound_clip_instance
		_watch_ruler(ci.instance_modified, _mark_ruler_context_dirty)
		var c := Utils.display_color(ci.track.color) if ci.track else Color(0.4, 0.6, 0.9)
		if ci.track:
			_watch_ruler(ci.track.color_changed, _mark_ruler_context_dirty.unbind(1))
		c.a = 0.38
		if ci.loop_enabled:
			# The content that repeats; whatever the first run plays before it is fainter.
			var run := ci.first_run_range()
			if run.x < ci.loop_start_ticks:
				var lead := c
				lead.a = 0.15
				regions.append({"start": run.x, "end": ci.loop_start_ticks, "color": lead, "edges": false})
			regions.append({"start": ci.loop_start_ticks, "end": ci.loop_start_ticks + ci.loop_length_ticks, "color": c, "edges": true})
		else:
			regions.append({"start": ci.clip_offset, "end": ci.clip_offset + ci.duration_ticks, "color": c, "edges": true})
	ruler.set_regions(regions)


func _watch_ruler(sig: Signal, cb: Callable) -> void:
	sig.connect(cb)
	_ruler_watch.append([sig, cb])


func _unwatch_ruler_context() -> void:
	for pair in _ruler_watch:
		var sig: Signal = pair[0]
		if is_instance_valid(sig.get_object()) and sig.is_connected(pair[1]):
			sig.disconnect(pair[1])
	_ruler_watch.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unwatch_ruler_context()


func _on_editor_playhead_moved(global_playhead_ticks: int):
	"""Handle global playhead updates from Editor."""
	var playhead_ticks = 0
	
	if track_mode:
		# TRACK-MODE: Use song-relative ticks (global position)
		playhead_ticks = global_playhead_ticks
	elif bound_clip_instance:
		# CLIP-MODE: clip-content ticks, where the bound instance plays that moment
		playhead_ticks = bound_clip_instance.song_to_played_content_ticks(global_playhead_ticks)
	
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
		track_mode_toggle.tooltip_text = "Switch to Clip Mode" if track_mode else "Switch to Track Mode"
		# Disable only when neither a selection nor remembered tracks exist
		track_mode_toggle.disabled = selected_clips.is_empty() and pending_clips.is_empty() and last_track_mode_tracks.is_empty()
	if clip_name_label:
		clip_name_label.visible = not track_mode
		_update_clip_name()
	log.info("  - UI mode: %s, left_panel=%s, toggle_disabled=%s" % ["TRACK" if track_mode else "CLIP", str(left_panel.visible if left_panel else false), str(track_mode_toggle.disabled if track_mode_toggle else false)])


## Header label: the bound clip's name in clip mode, kept current when it is renamed.
func _update_clip_name() -> void:
	var clip: Clip = bound_clip_instance.clip if bound_clip_instance and not track_mode else null
	if clip != _named_clip:
		if _named_clip and is_instance_valid(_named_clip) and _named_clip.clip_modified.is_connected(_update_clip_name):
			_named_clip.clip_modified.disconnect(_update_clip_name)
		_named_clip = clip
		if _named_clip:
			_named_clip.clip_modified.connect(_update_clip_name)
	clip_name_label.text = clip.name if clip else ""


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
		# Clip mode's clip (if any) decides which track to show and where to scroll.
		var from_clip: ClipInstance = bound_clip_instance
		# Ensure tracks list is populated: prefer last seen track list
		if not last_track_mode_tracks.is_empty():
			selected_tracks = last_track_mode_tracks.duplicate()
		elif selected_tracks.is_empty() and not selected_clips.is_empty():
			for clip_inst in selected_clips:
				if clip_inst and clip_inst.track and not selected_tracks.has(clip_inst.track):
					selected_tracks.append(clip_inst.track)
		if from_clip and from_clip.track:
			last_track_mode_selected_track = from_clip.track
		_bind_track_mode()
		_focus_track_mode_on(from_clip)
		log.info("  - Switched to TRACK mode (%d tracks)" % [selected_tracks.size()])
	else:
		# Switching to clip-mode: the clip nearest the last interacted note, else the first one
		var current_t = midi_editor.current_track if midi_editor else last_track_mode_selected_track
		if not current_t and not selected_tracks.is_empty():
			current_t = selected_tracks[0]
		var target_clip := _nearest_clip_for_clip_mode(current_t)
		if target_clip:
			current_t = target_clip.track
			selected_clips = [target_clip]
			selected_tracks = [current_t] as Array[Track] if current_t else [] as Array[Track]
			last_active_clip_by_track[current_t] = target_clip
		_bind_clip_mode()
		log.info("  - Switched to CLIP mode (clip_id=%s, track='%s')" % [str(selected_clips[0].id) if not selected_clips.is_empty() else "null", current_t.name if current_t else "null"])


## Track mode was entered from clip mode: make the clip's track visible, editable and current,
## then scroll to the clip, or to the track's first clip when there was none.
func _focus_track_mode_on(clip: ClipInstance) -> void:
	var track: Track = clip.track if clip and clip.track else midi_editor.current_track
	if track and _listed_tracks().has(track):
		_suppress_toggle_apply = true
		track_toggles.set_on(track, TrackToggleState.Kind.VISIBLE, true)
		track_toggles.set_on(track, TrackToggleState.Kind.EDITABLE, true)
		_suppress_toggle_apply = false
		last_track_mode_selected_track = track
		_apply_track_toggles(track)
		_refresh_all_toggles()
	var target := clip
	if not target and track:
		target = _first_clip(track)
	if target:
		midi_editor.scroll_to_song_tick(target.start_ticks)


func _first_clip(track: Track) -> ClipInstance:
	var first: ClipInstance = null
	for ci in track.clip_instances:
		if first == null or ci.start_ticks < first.start_ticks:
			first = ci
	return first


## The clip of the last interacted track (else `fallback_track`) nearest to the last interacted
## position; the track's first clip when nothing was interacted with.
func _nearest_clip_for_clip_mode(fallback_track: Track) -> ClipInstance:
	var track: Track = midi_editor.last_interaction_track
	if not track or not track.clip_instances.size():
		track = fallback_track
	if not track:
		return null
	var tick: int = midi_editor.last_interaction_song_tick
	if tick < 0 or track != midi_editor.last_interaction_track:
		return _first_clip(track)
	var best: ClipInstance = null
	var best_dist := 0
	for ci in track.clip_instances:
		var dist := maxi(maxi(ci.start_ticks - tick, tick - ci.get_end_ticks()), 0)
		if best == null or dist < best_dist:
			best = ci
			best_dist = dist
	return best


func _on_track_selector_track_selected(track: Track, additive := false):
	"""Handle track selection from track selector - update active track in MidiEditor."""
	log.info("Track selected from selector: %s" % track.name)
	if midi_editor and track_mode:
		# The selected track is always visible and editable (REQ-030).
		_suppress_toggle_apply = true
		if not additive:
			# A plain click leaves this as the only editable track.
			for t in _listed_tracks():
				if t != track:
					track_toggles.set_on(t, TrackToggleState.Kind.EDITABLE, false)
		track_toggles.set_on(track, TrackToggleState.Kind.VISIBLE, true)
		track_toggles.set_on(track, TrackToggleState.Kind.EDITABLE, true)
		_suppress_toggle_apply = false
		_apply_track_toggles(track)
		log.info("  - Active track changed to: '%s'" % [track.name])
	track_mode_track_selected.emit(track)


## A note of another track was clicked in the note editor: mirror the switch in the list.
func _on_note_track_picked(track: Track) -> void:
	track_selector.select_track_no_signal(track)
	last_track_mode_selected_track = track
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
