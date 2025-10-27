class_name ClipEditor extends HBoxContainer

var log := Log.make("ClipEditor")

# left panel will show track list when showing multiple clips, with buttons to switch between clips
@onready var left_panel: PanelContainer = $LeftPanel

# main panel shows ruler and midi editor
@onready var main_panel: PanelContainer = $MainPanel

@onready var main_header: PanelContainer = $MainPanel/VBox/PanelContainer/MainHeader

@onready var ruler: Ruler = $MainPanel/VBox/PanelContainer/VBox/Ruler

@onready var midi_editor = $MainPanel/VBox/MidiEditor

# for multi-track clip editing
@onready var track_selector: ClipEditorTrackList = $LeftPanel/VBox/ClipEditorTrackList

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
	
	if Sonara.editor:
		Sonara.editor.clips_selected.connect(_on_editor_clips_selected)
		Sonara.editor.tempo_changed.connect(_on_editor_tempo_changed)
		Sonara.editor.time_signature_changed.connect(_on_editor_time_signature_changed)
		Sonara.editor.playhead_moved.connect(_on_editor_playhead_moved)


func _on_editor_clips_selected(clips: Array[ClipInstance], multi_track: bool):
	"""Handle clip selection from Editor - supports both single and multi-clip modes."""
	log.info("Clips selected: %d clips, multi_track=%s" % [clips.size(), multi_track])
	
	# Store pending data - will bind when we become visible
	pending_clips = clips
	pending_multi_track = multi_track
	
	# If we're already visible, bind immediately
	if is_visible_in_tree():
		_bind_pending_clips()


func _on_editor_tempo_changed(tempo : float):
	if is_visible_in_tree() or true:
		grid_helper.tempo = tempo
	

func _on_editor_time_signature_changed(numerator : int, denominator : int):
	if is_visible_in_tree() or true:
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
	selected_clips = pending_clips
	track_mode = pending_multi_track
	
	# Extract unique tracks from selected clips
	selected_tracks.clear()
	for clip_inst in selected_clips:
		if clip_inst and clip_inst.track and not selected_tracks.has(clip_inst.track):
			selected_tracks.append(clip_inst.track)
	
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
			track_selector.select_track_no_signal(selected_tracks[0])
	
	# In track-mode, the ruler and grid show song-relative positions
	# The playhead conversion in _on_editor_playhead_moved will NOT subtract clip offset
	# This means tick 0 = song start, not clip start
	
	# Bind MidiEditor to track-mode
	# NOTE: MidiEditor now fetches ALL clips from each track internally
	if not selected_clips.is_empty():
		midi_editor.bind_to_clips(selected_clips, selected_tracks)
		# Keep bound_clip_instance for reference, but track_mode flag determines playhead behavior
		bound_clip_instance = selected_clips[0]


func _bind_clip_mode():
	"""Bind to clip-mode: single clip with clip-local ruler (current behavior)."""
	log.info("  - Entering CLIP-MODE")
	
	# Bind to the last selected clip (current behavior)
	if not selected_clips.is_empty():
		var clip_inst = selected_clips[-1]
		log.info("  - Binding to clip instance: ", clip_inst.id)
		midi_editor.bind_to_clip_instance(clip_inst)
		bound_clip_instance = clip_inst

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


func _on_track_selector_track_selected(track: Track):
	"""Handle track selection from track selector - update active track in MidiEditor."""
	log.info("Track selected from selector: %s" % track.name)
	if midi_editor and track_mode:
		midi_editor.current_track = track
