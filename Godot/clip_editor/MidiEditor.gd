# Midi Editor
# 
# Composed of a VPiano (Vertical Piano keys) on the left side
# and NoteLanes, GridRenderer, one NoteEditor and a ContextNotesLayer on the right.
#
# designed to have a ScrollContainer with only vertical scroll enabled
# I.E VPiano, and notte_area nodes are as tall as the keyboard
#
# vertical zoom is handled by inc/dec the note lane/piano key heights in sync
#
# horizontal zoom supported by h_scroll but we handle it
# 
# handles input and delegates to note_editor(s) for multi-track note editing and selection
class_name MidiEditor extends ScrollContainer

var logger := Log.make("MidiEditor")

@onready var v_piano: VPiano = $HBox/VPiano
## Drum View's replacement for the piano keys. Shares VPiano's slot in the HBox;
## exactly one of the two is visible.
@onready var drum_row_header: DrumRowHeader = $HBox/DrumRowHeader
@onready var note_area: Control = $HBox/NoteArea
@onready var note_lanes: NoteLanes = $HBox/NoteArea/NoteLanes
@onready var grid_renderer: GridRenderer = $HBox/NoteArea/GridRenderer

# h_scroll contains the NoteEditor and, behind it, the ContextNotesLayer
@onready var h_scroll: ScrollContainer = $HBox/NoteArea/HScroll
## The NoteEditors. Only ever one, the scene's: in track mode it is bound to current_track, and
## the other visible tracks are drawn by context_layer. An array so code that loops over
## the editors keeps working.
var note_editors : Array[NoteEditor] = []

## Draws the visible tracks other than current_track (track mode) without a node per note.
var context_layer := ContextNotesLayer.new()

# Active track.color_changed subscriptions, as [track, callable] pairs, so note
# colors follow the track color while the editor is bound.
var _color_bindings : Array = []

# Track-mode state
var track_mode: bool = false  # True when displaying multiple clips across tracks
## The visible tracks in list order (track mode), and the clips the user opened on them.
var _view_tracks: Array[Track] = []
var _edited_clips: Array[ClipInstance] = []
var current_track: Track = null:  # Active track in track-mode
	set(value):
		if current_track != value:
			# The time range is shared by the tracks: carry it to the new track's editor.
			var carried := get_selection_range_song() if track_mode else NO_RANGE
			current_track = value
			_sync_track_views()
			if track_mode and value:
				apply_selection_range_song(carried)
			current_track_changed.emit()
			# Labels and colours come from the focused track's map (REQ-024).
			if is_inside_tree():
				call_deferred("refresh_note_map")
				# The active editor is the one keyboard shortcuts apply to (the track
				# list isn't focusable), so hand it the focus when the track changes.
				if track_mode and is_visible_in_tree():
					var active := get_active_note_editor()
					if active:
						active.call_deferred("grab_focus")

# Primary note editor (backwards compatibility, first in note_editors array)
var note_editor: NoteEditor:
	get:
		if note_editors.is_empty():
			return null
		return note_editors[0]


## Tracks whose notes can be hit and edited, in track-list order (the priority for overlapping
## notes). Set by ClipEditor from its toggle state; bind_to_clips makes every bound track editable.
## Only the current track has notes to select; the others' notes can be clicked (to switch to
## them) and erased.
var editable_tracks: Array[Track] = []:
	set(value):
		editable_tracks = value
		_update_note_editor_states()

const NO_RANGE := Vector2i(-1, -1)


## The active editor's time range in song ticks, or NO_RANGE. Clip mode converts from the
## bound instance's clip-content ticks.
func get_selection_range_song() -> Vector2i:
	var active := get_active_note_editor()
	if not active or not active.selection_manager or not active.selection_manager.has_range():
		return NO_RANGE
	var sm := active.selection_manager
	return Vector2i(_editor_to_song_ticks(active, sm.box_selection_start_tick),
		_editor_to_song_ticks(active, sm.box_selection_end_tick))


## Put a song-tick range on the active editor as a bare range (no notes selected), so it
## survives switching tracks and clips. NO_RANGE clears the range.
func apply_selection_range_song(song_range: Vector2i) -> void:
	var active := get_active_note_editor()
	if not active or not active.selection_manager:
		return
	var start := -1
	var end := -1
	if song_range != NO_RANGE:
		start = maxi(0, _song_to_editor_ticks(active, song_range.x))
		end = _song_to_editor_ticks(active, song_range.y)
	active.selection_manager.set_range(start, end)
	if is_inside_tree():
		_update_selection_overlays()


func _editor_to_song_ticks(editor: NoteEditor, ticks: int) -> int:
	if editor.multi_clip_mode or not editor.clip_instance:
		return ticks
	return editor.clip_instance.clip_to_song_ticks(ticks)


func _song_to_editor_ticks(editor: NoteEditor, ticks: int) -> int:
	if editor.multi_clip_mode or not editor.clip_instance:
		return ticks
	return editor.clip_instance.song_to_clip_ticks(ticks)


func get_active_note_editor() -> NoteEditor:
	"""Get the currently active note editor (respects track selection in track-mode)."""
	if not track_mode:
		# Single-clip mode: use first editor
		return note_editor

	# Track-mode: the editor of the selected track; none when no track is selected
	for editor in note_editors:
		if current_track and _editor_track(editor) == current_track:
			return editor
	return null


## The track a note editor is bound to (multi-clip: its track, single-clip: its instance's).
func _editor_track(editor: NoteEditor) -> Track:
	if not editor:
		return null
	if editor.multi_clip_mode and editor.track:
		return editor.track
	if editor.clip_instance and editor.clip_instance.track:
		return editor.clip_instance.track
	return null

@onready var playhead: TextureRect = $HBox/NoteArea/Playhead

# overlays help render noteselection boundaries and selection box
@onready var overlays: MidiEditorOverlays = $HBox/NoteArea/Overlays

# Playhead position (in clip-local ticks)
var playhead_ticks: int = -1:
	set(value):
		playhead_ticks = value
		_update_playhead_position()

var grid_helper: GridHelper:
	set(gh):
		if grid_helper != gh:
			logger.info("grid_helper changed: ", gh)
			# Disconnect from old grid_helper if it exists
			if grid_helper and grid_helper.changed.is_connected(_on_grid_helper_changed):
				grid_helper.changed.disconnect(_on_grid_helper_changed)

			if grid_helper and grid_helper.scale_changed.is_connected(update_content_width):
				grid_helper.scale_changed.disconnect(update_content_width)

			grid_helper = gh
			note_lanes.grid_helper = gh
			grid_renderer.set_grid_helper(gh)
			context_layer.grid_helper = gh
			
			# Update all note editors
			for editor in note_editors:
				if editor:
					editor.grid_helper = gh

			# Connect to new grid_helper's changed signal
			if grid_helper:
				grid_helper.changed.connect(_on_grid_helper_changed)
				grid_helper.scale_changed.connect(update_content_width)
				update_content_width()


# Local cursor position (in ticks) - propagated to NoteEditor(s)
var cursor_position_ticks: int = 0:
	set(value):
		cursor_position_ticks = value
		# Update all note editors
		for editor in note_editors:
			if editor:
				editor.cursor_position_ticks = cursor_position_ticks


## Shared pitch <-> row <-> Y math. Handed to VPiano, NoteLanes, DrumRowHeader and
## every NoteEditor so they all agree on where a pitch sits, exactly as they share
## one GridHelper horizontally. Chromatic in the piano roll, folded in Drum View.
var lane_layout: LaneLayout = LaneLayout.chromatic(20.0)

## Effective note map for the active track's channel, resolved once per change and
## cached (resolving walks the device chain, so never per frame).
var note_map: NoteMap = NoteMap.new()

## Tells us when a derived Auto map may have changed (REQ-004).
var _note_map_watcher := NoteMapWatcher.new()
var _watched_channel: Channel = null

## True while the editor shows Drum View instead of the piano roll.
var drum_view: bool = false:
	set(value):
		if drum_view == value:
			return
		drum_view = value
		_syncing_drum_view = true
		scale_context.drum_view = value
		_syncing_drum_view = false
		_apply_view_mode()

## Shared scale state (spec 026): handed to the lanes, piano header and every note editor.
## ClipEditor fills in the scale and the snap / fold flags; MidiEditor adds Drum View and the
## keyswitch pitches.
var scale_context := ScaleContext.new()
## Set while drum_view is being mirrored into scale_context, so its `changed` doesn't
## trigger a second view-mode switch.
var _syncing_drum_view := false
## Whether the rows currently shown are the scale fold, and which scale they were built for.
var _fold_applied := false
var _fold_scale_key := ""

## Set while a rebuild was deferred because a drag was in progress (REQ-021).
var _rows_dirty := false
## Set while a rebuild is already queued for the end of this frame, so a clip
## edit touching many notes still costs one rebuild.
var _rebuild_queued := false

## The focused track (track mode) changed.
signal current_track_changed
## A left press hit a note of another editable track; the press switched to that track.
signal note_track_picked(track: Track)

## Emitted whenever the row set or the effective map changed, so ClipEditor can
## refresh the toolbar and the empty-view hint.
signal view_state_changed

## The selected notes of a note editor changed (the toolbar's selection tools follow it).
signal selection_changed

## The user clicked the empty-Drum-View hint (REQ-023).
signal note_map_editor_requested

## Width of the key column (piano keys or Drum View row names) changed. The value lanes below
## keep their header column the same width so stems line up with the notes.
signal key_column_width_changed(width: float)

## The note under the pointer changed (the note area or a value lane stem), for the
## cross-highlight between the two.
signal hovered_note_changed(note: MidiNoteData)

## The note the pointer is over in the note area or a value lane, or null.
var hovered_note_data: MidiNoteData = null
## Velocity and release of the next note drawn: the last touched note's (shared by the editors).
var next_note_values := NextNoteValues.new()
var _last_hover_mouse := Vector2(-1.0, -1.0)
var _hover_from_area := false
var _last_key_column_width := -1.0

## Hint shown when Drum View has no rows to draw. Built in code because it only
## ever appears in this one state.
var _empty_hint: Button = null

# note height: drives lane_layout.row_height, which v_piano, note_lanes and the
# note editor(s) all read from
var note_height_min := 8
var note_height_max := 40
@export var note_height := 20:
	set(nh):
		if note_height != nh:
			note_height = clamp(nh, note_height_min, note_height_max)
			lane_layout.row_height = note_height
			if is_inside_tree():
				# Note editors resize from the layout's `changed` signal, but they
				# still mirror note_height for their own minimum size bookkeeping.
				for editor in note_editors:
					if editor:
						editor.note_height = note_height

var scroll_speed_notes = 2

@export var scroll_speed_v : int:
	get:
		return scroll_speed_notes * note_height

@export var scroll_speed_h: float = 50.0

# Zoom sensitivity: derived live from the shared scroll-zoom sensitivity setting
# (Settings › Behavior › Zoom), the same one the arranger follows. Vertical keeps
# its own base (pixels added to the row height per tick); the setting scales it.
var zoom_sensitivity_h: float = 1.6  # Horizontal zoom multiplier per scroll tick
var zoom_sensitivity_v: int = 3      # Vertical zoom delta per scroll tick
@export var pan_zoom_sensitivity: float = 0.5  # Zoom factor per pixel of mouse movement when shift+panning (percentage)

# Horizontal scrolling: the note area is at least min_width_bars wide, reaches
# extra_width_bars past the content, and grows by scroll_growth_bars whenever the view
# comes within one viewport of its right edge, so scrolling right never runs out.
@export var min_width_bars: int = 8
@export var extra_width_bars: int = 4
@export var scroll_growth_bars: int = 16

## How far scrolling has grown the note area, in ticks. Only grows; reset on unbind.
var _scroll_extent_ticks: int = 0
## Width in ticks last given to the note editors.
var _content_width_ticks: int = 0
var _content_width_queued := false

# Horizontal zoom limits (pixels per beat)
@export var zoom_min_pixels_per_beat: float = 2.0
@export var zoom_max_pixels_per_beat: float = 4096

# Smooth scrolling: 0 = instant, higher = smoother (0.1-0.3 recommended)
@export var scroll_smoothing: float = 0.2

# Target scroll positions for smooth scrolling
var target_scroll_vertical: float = 0.0
var target_scroll_horizontal: float = 0.0

# Target for smooth horizontal zooming (like the arranger)
var target_pixels_per_beat: float = 0.0

# Horizontal zoom anchor: the (fractional) beat under the cursor stays at _zoom_anchor_x while
# a wheel zoom animates. The scroll is derived from the current zoom every frame instead of
# being lerped separately, otherwise scroll and zoom disagree mid-animation and the view jitters.
# Beat 0 at x 0 locks the view to the origin.
var _zoom_anchor_active: bool = false
var _zoom_anchor_beat: float = 0.0
var _zoom_anchor_x: float = 0.0

# Middle mouse button panning state
var is_panning: bool = false
var pan_start_mouse_pos: Vector2 = Vector2.ZERO
var pan_start_scroll_v: float = 0.0
var pan_start_scroll_h: float = 0.0
var pan_start_pixels_per_beat: float = 0.0
var pan_start_h_scroll_mouse_pos: Vector2 = Vector2.ZERO  # Mouse pos relative to h_scroll when pan started

# The clip instance that opened this editor (for context, not edited directly)
var clip_instance: ClipInstance = null

## When on, clicking (or placing/dragging) a note plays it on the track's instrument.
var audition_enabled := false:
	set(on):
		audition_enabled = on
		if not on:
			_stop_preview_note()

# The one note currently previewed (piano key or audition), -1 when silent.
var _preview_note := -1
var _preview_channel_id := -1

# Convenience to get the Clip of clip_instance
var clip: Clip:
	get:
		return clip_instance.clip if clip_instance else null
	set(clip):
		pass

func _ready():
	mouse_exited.connect(func(): _update_note_hover(false))
	# Initialize target scroll positions to current values
	target_scroll_vertical = scroll_vertical
	target_scroll_horizontal = h_scroll.scroll_horizontal
	# grid_helper can still be null here: ClipEditor assigns it after this child's _ready.
	target_pixels_per_beat = grid_helper.pixels_per_beat if grid_helper else 64.0
	# Zoom sensitivity follows the shared setting (arranger + MIDI editor)
	_update_zoom_sensitivity()
	Settings.setting_changed.connect(_on_setting_changed)
	lane_layout.row_height = note_height
	v_piano.layout = lane_layout
	note_lanes.layout = lane_layout
	v_piano.scale_context = scale_context
	note_lanes.scale_context = scale_context
	scale_context.changed.connect(_on_scale_context_changed)
	
	context_layer.name = "ContextNotes"
	context_layer.layout = lane_layout
	context_layer.notes_changed.connect(queue_row_rebuild)
	context_layer.content_extent_changed.connect(queue_content_width_update)
	h_scroll.add_child(context_layer)
	h_scroll.move_child(context_layer, 0)  # behind the note editor

	# Find existing NoteEditor in scene tree (from .tscn)
	var scene_note_editor = h_scroll.get_node_or_null("NoteEditor")
	if scene_note_editor:
		note_editors.append(scene_note_editor)
		_configure_note_editor(scene_note_editor)

	h_scroll.resized.connect(_check_scroll_growth)

	v_piano.key_pressed.connect(_on_piano_key_pressed)
	v_piano.key_released.connect(_on_piano_key_released)
	# The Drum View header emits the same signals, so audition works either way.
	drum_row_header.layout = lane_layout
	drum_row_header.key_pressed.connect(_on_piano_key_pressed)
	drum_row_header.key_released.connect(_on_piano_key_released)
	v_piano.key_select_requested.connect(_select_pitch)
	drum_row_header.row_select_requested.connect(_on_row_select_requested)
	v_piano.resized.connect(_emit_key_column_width)
	drum_row_header.resized.connect(_emit_key_column_width)
	v_piano.visibility_changed.connect(_emit_key_column_width)
	drum_row_header.visibility_changed.connect(_emit_key_column_width)
	_note_map_watcher.changed.connect(_on_note_map_changed)
	visibility_changed.connect(_on_visibility_changed)
	_apply_view_mode()

func _process(delta: float):
	# The vertical extent is fixed by the rows, so the target never needs to go past it.
	# (Horizontal content grows while scrolling, so that target is clamped at input instead.)
	target_scroll_vertical = clampf(target_scroll_vertical, 0.0, _max_scroll_v())

	# Smooth scroll interpolation
	if scroll_smoothing > 0:
		var lerp_factor = 1.0 - pow(scroll_smoothing, delta * 60.0)
		scroll_vertical = _step_toward(scroll_vertical, target_scroll_vertical, lerp_factor)

		# Lerp horizontal zoom toward its target, like the arranger's smooth zoom. While a
		# wheel zoom runs the scroll follows the anchor; otherwise it lerps toward its target.
		if _zoom_anchor_active:
			var new_ppb = lerp(grid_helper.pixels_per_beat, target_pixels_per_beat, lerp_factor)
			if absf(new_ppb - target_pixels_per_beat) < 0.01:
				new_ppb = target_pixels_per_beat
				_zoom_anchor_active = false
			grid_helper.pixels_per_beat = new_ppb
			target_scroll_horizontal = roundi(maxf(0.0, _zoom_anchor_beat * new_ppb - _zoom_anchor_x))
			_set_h_scroll(target_scroll_horizontal, true)
		else:
			_set_h_scroll(_step_toward(h_scroll.scroll_horizontal, target_scroll_horizontal, lerp_factor))

	else:
		# Instant scrolling when smoothing is disabled
		scroll_vertical = roundi(target_scroll_vertical)
		_set_h_scroll(target_scroll_horizontal)


	# The context layer draws only what is on screen; tell it what that is.
	context_layer.view_rect = Rect2(h_scroll.scroll_horizontal, scroll_vertical, h_scroll.size.x, size.y)

	# Update playhead position based on scroll/zoom
	_update_playhead_position()
	if _scrubbing:
		_update_scrub()
	_update_hovered_key()
	_update_active_keys()


## One smoothing step from current toward target, landing exactly on it once within half a
## pixel (truncating instead would stall short of the target).
func _step_toward(current: int, target: float, lerp_factor: float) -> int:
	var v := lerpf(float(current), target, lerp_factor)
	if absf(v - target) < 0.5:
		v = target
	return roundi(v)


func _max_scroll_v() -> float:
	var vbar := get_v_scroll_bar()
	return maxf(0.0, vbar.max_value - vbar.page)


func _max_scroll_h() -> float:
	var hbar := h_scroll.get_h_scroll_bar()
	return maxf(0.0, hbar.max_value - hbar.page)


## Scroll the note area horizontally and keep the grid and ruler on the same whole pixel
## (otherwise they drift up to a pixel apart from the notes mid-scroll). Zooming in widens the
## content synchronously (scale_changed), but the scrollbar only learns the new width at the
## next layout pass, so a zoom passes zooming = true to raise its max first, or the scroll
## gets clamped to the old width.
func _set_h_scroll(px: float, zooming := false) -> void:
	var hbar := h_scroll.get_h_scroll_bar()
	var pos := roundi(maxf(0.0, px))
	if zooming and pos + hbar.page > hbar.max_value:
		hbar.max_value = pos + hbar.page
	h_scroll.scroll_horizontal = pos
	grid_helper.scroll_position = h_scroll.scroll_horizontal


func unbind():
	"""Unbind all clip instances and clear note editors."""
	_stop_preview_note()
	_stop_chord_preview()
	clip = null
	clip_instance = null
	track_mode = false
	current_track = null
	_clear_color_bindings()
	_scroll_extent_ticks = 0
	_view_tracks.clear()
	_edited_clips.clear()
	context_layer.set_tracks([], [])
	context_layer.excluded_track = null
	
	# Unbind all note editors
	for editor in note_editors:
		if editor:
			editor.unbind()

func bind_to_clip_instance(ci : ClipInstance):
	"""Bind to a single clip instance (clip-mode)."""
	logger.info("bind_to_clip_instance called (clip-mode)")
	logger.info("  - clip_instance: ", ci)
	logger.info("  - clip_id: ", ci.clip_id if ci else "null")
	logger.info("  - clip: ", ci.clip if ci else "null")

	var carried := get_selection_range_song()
	if clip_instance or track_mode:
		unbind()
	
	track_mode = false
	clip_instance = ci
	
	# Bind to the first (and only) note editor
	if note_editor:
		note_editor.visible = true
		_configure_note_editor(note_editor)
		if clip_instance and clip_instance.track:
			_bind_track_color(note_editor, clip_instance.track)
		note_editor.bind(clip_instance)
		# Clip-mode: no position offset (notes show at clip-local positions)
		note_editor.position_offset_ticks = 0
		note_editor.edited_clip_instances.clear()
		# The time range survives opening another clip (same song position).
		apply_selection_range_song(carried)
	
	call_deferred("refresh_note_map")
	call_deferred("frame_clip_instance")


func bind_to_clips(clips: Array[ClipInstance], tracks: Array[Track]):
	"""Bind to multiple clips in track-mode (song-relative positioning).

	Shows ALL clips of every given track: the first track in a NoteEditor, the rest in the
	context layer. This gives a complete timeline view for each selected track.
	"""
	logger.info("[MidiEditor] bind_to_clips called (track-mode)")
	logger.info("  - %d clips across %d tracks" % [clips.size(), tracks.size()])

	var carried := get_selection_range_song()
	# Unbind previous state
	if clip_instance or track_mode:
		unbind()

	track_mode = true
	_view_tracks = tracks.duplicate()
	_edited_clips = clips.duplicate()

	# Store reference to first clip for convenience (optional, may not be used)
	if not clips.is_empty():
		clip_instance = clips[0]

	# Every bound track is editable unless the caller narrows it (set_track_views users)
	editable_tracks = tracks.duplicate()

	# Set first track as active by default
	if not tracks.is_empty():
		current_track = tracks[0]
	_sync_track_views()
	# The time range survives rebinding (same song ticks in track mode).
	apply_selection_range_song(carried)

	call_deferred("refresh_note_map")
	call_deferred("scroll_to_note")


## Binds `editor` to all of `track`'s clips; `clips` are the opened ones (what Ctrl+C copies
## when nothing is selected).
func _bind_editor_to_track(editor: NoteEditor, track: Track, clips: Array[ClipInstance]) -> void:
	_configure_note_editor(editor)
	editor.visible = true
	# Bind to ALL clips on this track (multi-clip mode)
	editor.bind_to_clips(track.clip_instances, track)
	_set_edited_clips(editor, track, clips)
	# Rebinding drops the notes but not the range, which only the active editor keeps.
	if editor.selection_manager:
		editor.selection_manager.clear_selection()
	# Set color from track (and keep following it)
	_bind_track_color(editor, track)


func _set_edited_clips(editor: NoteEditor, track: Track, clips: Array[ClipInstance]) -> void:
	editor.edited_clip_instances.clear()
	for ci in clips:
		if ci and ci.track == track:
			editor.edited_clip_instances.append(ci)


## Makes the display match `tracks` (the visible ones): current_track gets the note editor
## (when it is among them), all of them are known to the context layer, which draws every one
## but the current track.
func set_track_views(tracks: Array[Track], edited_clips: Array[ClipInstance]) -> void:
	if not track_mode:
		if clip_instance:
			unbind()
		track_mode = true

	_view_tracks = tracks.duplicate()
	_edited_clips = edited_clips.duplicate()
	_sync_track_views()

	if not tracks.is_empty() and not clip_instance:
		clip_instance = edited_clips[0] if not edited_clips.is_empty() else null
	_update_selection_overlays()
	queue_content_width_update()
	call_deferred("refresh_note_map")


## Track mode: bind the note editor to current_track if it is shown, else hide it, and hand
## the layer the tracks. Cheap when nothing changed.
func _sync_track_views() -> void:
	if not track_mode or note_editors.is_empty():
		return
	var editor := note_editors[0]
	var wanted: Track = current_track if _view_tracks.has(current_track) else null
	if wanted == null:
		if _editor_track(editor) != null or editor.visible:
			_clear_color_bindings_for(editor)
			editor.unbind()
			if editor.selection_manager:
				editor.selection_manager.clear_selection()
			editor.visible = false
	elif _editor_track(editor) != wanted or not editor.visible:
		_clear_color_bindings_for(editor)
		editor.unbind()
		_bind_editor_to_track(editor, wanted, _edited_clips)
		# The new track's notes may reach further right than the old one's.
		queue_content_width_update()
		queue_row_rebuild()
	else:
		_set_edited_clips(editor, wanted, _edited_clips)
	_update_note_editor_states()


func _clear_color_bindings_for(editor: NoteEditor) -> void:
	for i in range(_color_bindings.size() - 1, -1, -1):
		var track: Track = _color_bindings[i][0]
		var cb: Callable = _color_bindings[i][1]
		if cb.get_bound_arguments()[0] != editor:
			continue
		if is_instance_valid(track) and track.color_changed.is_connected(cb):
			track.color_changed.disconnect(cb)
		_color_bindings.remove_at(i)


func _bind_track_color(editor: NoteEditor, track: Track) -> void:
	"""Apply the track color to the editor and keep it in sync with later changes."""
	if not editor or not track:
		return
	editor.note_color = track.color
	var cb := Callable(self, "_on_track_color_changed").bind(editor)
	if not track.color_changed.is_connected(cb):
		track.color_changed.connect(cb)
		_color_bindings.append([track, cb])


func _on_track_color_changed(new_color: Color, editor: NoteEditor) -> void:
	if is_instance_valid(editor):
		editor.note_color = new_color


func _clear_color_bindings() -> void:
	for binding in _color_bindings:
		var track: Track = binding[0]
		var cb: Callable = binding[1]
		if is_instance_valid(track) and track.color_changed.is_connected(cb):
			track.color_changed.disconnect(cb)
	_color_bindings.clear()


# set vertical scroll to the given note, or default to average note or C3 if no notes
func scroll_to_note(note: int = -1):
	if note == -1:
		if not clip or not clip.midi_notes.size():
			note = 60
		else:
			note = clip.find_average_note()
	
	var y := lane_layout.pitch_to_y(note)
	target_scroll_vertical = max(0, y - (size.y * 0.5))


## Clip-content tick to bring into view the next time the instance is framed (-1 = the start).
## Set by the arranger when a clip is opened by double-clicking its body.
var pending_focus_tick: int = -1


## Scroll so `content_tick` (clip content ticks) sits a quarter of the way into the view.
func focus_content_tick(content_tick: int) -> void:
	if track_mode or not grid_helper:
		return
	var floor_px := grid_helper.ticks_to_pixels(clip_instance.clip_offset) if clip_instance else 0.0
	var x := grid_helper.ticks_to_pixels(maxi(0, content_tick)) - size.x * 0.25
	target_scroll_horizontal = maxf(x, floor_px)


## Clip-mode: scroll to the start of the instance's visible content (or the tick the user opened
## the clip at) and centre vertically on the median pitch of the notes it plays (C3 if none).
func frame_clip_instance() -> void:
	if track_mode or not clip_instance or not grid_helper:
		return
	var range_start := clip_instance.clip_offset
	var range_end := range_start + clip_instance.duration_ticks
	var pitches: Array[int] = []
	if clip:
		for n in clip.midi_notes:
			if n.start_tick < range_end and n.start_tick + n.duration_ticks > range_start:
				pitches.append(n.note)
	var note := 60
	if not pitches.is_empty():
		pitches.sort()
		@warning_ignore("integer_division")
		note = pitches[pitches.size() / 2]
	scroll_to_note(note)
	target_scroll_horizontal = max(0.0, grid_helper.ticks_to_pixels(range_start))
	if pending_focus_tick >= 0:
		focus_content_tick(pending_focus_tick)
		pending_focus_tick = -1


## Scroll horizontally so `song_tick` is at the left edge (track mode: ticks are song ticks).
func scroll_to_song_tick(song_tick: int) -> void:
	if not grid_helper:
		return
	target_scroll_horizontal = maxf(0.0, grid_helper.ticks_to_pixels(maxi(0, song_tick)))


func set_horizontal_zoom(new_pixels_per_beat: float) -> void:
	"""Set horizontal zoom level while maintaining the visual position under the mouse cursor."""
	if not grid_helper:
		return
	
	# Store old value for ratio calculation
	var old_pixels_per_beat = grid_helper.pixels_per_beat
	
	# Clamp new zoom
	var clamped_ppb = clamp(new_pixels_per_beat, zoom_min_pixels_per_beat, zoom_max_pixels_per_beat)
	
	# If we hit the limits or no change, don't adjust
	if clamped_ppb == old_pixels_per_beat:
		return
	
	# Get mouse position relative to h_scroll viewport
	var h_scroll_mouse_pos = h_scroll.get_local_mouse_position()
	
	# Store the current scroll position before zoom
	var old_scroll = h_scroll.scroll_horizontal
	
	# Calculate the zoom ratio
	var zoom_ratio = clamped_ppb / old_pixels_per_beat
	
	# Programmatic zoom: cancel any in-flight wheel zoom animation and keep the
	# target in sync so the lerp in _process doesn't drag the zoom back.
	target_pixels_per_beat = clamped_ppb
	_zoom_anchor_active = false
	# Apply zoom (this triggers grid_helper.changed signal)
	grid_helper.pixels_per_beat = clamped_ppb
	
	# Calculate the content position under the mouse before zoom
	var old_content_x = old_scroll + h_scroll_mouse_pos.x
	
	# Scale the content position by the zoom ratio
	var new_content_x = old_content_x * zoom_ratio
	
	# Calculate the new scroll to keep the same content under the mouse
	var scroll_offset = new_content_x - h_scroll_mouse_pos.x

	# Stick to the origin when already within a beat of it (same rule as the
	# arranger and _smooth_horizontal_zoom).
	if old_scroll < old_pixels_per_beat:
		scroll_offset = 0.0
	# Snap to zero if we're close to the start (nice UX touch)
	var snap_threshold = 30.0
	if scroll_offset > 0 and scroll_offset < snap_threshold:
		scroll_offset = 0.0
	
	# Apply scroll immediately (bypassing smooth scrolling for zoom)
	target_scroll_horizontal = max(0, scroll_offset)
	_set_h_scroll(target_scroll_horizontal, true)


## Smooth (lerped) horizontal zoom anchored at the mouse, matching the arranger's
## Shift + wheel zoom. Instant when scroll smoothing is disabled.
func _smooth_horizontal_zoom(factor: float) -> void:
	if scroll_smoothing <= 0:
		set_horizontal_zoom(grid_helper.pixels_per_beat * factor)
		return
	# Step from the running target so quick wheel ticks accumulate instead of being lost.
	var base_ppb := target_pixels_per_beat if _zoom_anchor_active else grid_helper.pixels_per_beat
	var new_ppb := clampf(base_ppb * factor, zoom_min_pixels_per_beat, zoom_max_pixels_per_beat)
	if is_equal_approx(new_ppb, base_ppb):
		return
	var viewport_width := h_scroll.size.x
	var mouse_x := clampf(h_scroll.get_local_mouse_position().x, 0.0, viewport_width)
	var scroll := float(h_scroll.scroll_horizontal)
	var origin_anchored := _zoom_anchor_active and _zoom_anchor_beat == 0.0 and _zoom_anchor_x == 0.0
	# Stick to the origin when we're already within a beat of it (same rule as the arranger):
	# the mouse-anchored formula would otherwise creep the view away from the start.
	if scroll < grid_helper.pixels_per_beat and (not _zoom_anchor_active or origin_anchored):
		_zoom_anchor_beat = 0.0
		_zoom_anchor_x = 0.0
	elif not _zoom_anchor_active or absf(_zoom_anchor_x - mouse_x) > 1.0:
		# Keep the anchor beat while a zoom is running (re-deriving it from the half-animated
		# view would compound rounding); start a new one otherwise.
		_zoom_anchor_beat = (scroll + mouse_x) / grid_helper.pixels_per_beat
		_zoom_anchor_x = mouse_x
	_zoom_anchor_active = true
	target_pixels_per_beat = new_ppb
	target_scroll_horizontal = maxf(0.0, _zoom_anchor_beat * new_ppb - _zoom_anchor_x)


func _update_zoom_sensitivity() -> void:
	var choice := str(Settings.get_value(Utils.SCROLL_ZOOM_SENSITIVITY_SETTING))
	var multiplier := Utils.scroll_zoom_multiplier(choice)
	zoom_sensitivity_h = multiplier
	zoom_sensitivity_v = maxi(1, roundi(3.0 * (multiplier / Utils.SCROLL_ZOOM_NORMAL)))


func _on_setting_changed(key: String, _value) -> void:
	if key == Utils.SCROLL_ZOOM_SENSITIVITY_SETTING:
		_update_zoom_sensitivity()
	

func _zoom_vertical(delta_note_height: int):
	"""Zoom vertically while maintaining the visual position of notes at the mouse cursor."""
	var note_editor_mouse_pos = note_editor.get_local_mouse_position()
	var old_scroll := float(scroll_vertical)
	var old_total_height := lane_layout.total_height()

	# Store the old note height for ratio calculation
	var old_note_height = note_height
	
	# Apply zoom
	note_height += delta_note_height
	note_height = clamp(note_height, note_height_min, note_height_max)
	
	# If we hit the limits, don't adjust scroll
	if note_height == old_note_height:
		return

	# Calculate the zoom ratio
	var zoom_ratio = float(note_height) / float(old_note_height)
	
	# Calculate the new scroll position to keep the same note under the mouse
	# Use the zoom ratio to calculate the expected change in note position
	# The note position should scale by the zoom ratio
	var old_note_y = note_editor_mouse_pos.y
	var new_note_y = old_note_y * zoom_ratio
	
	# Calculate the scroll offset needed to keep the note under the mouse
	var scroll_offset = new_note_y - note_editor_mouse_pos.y
	
	# The rows have their new height now, but the scrollbar only learns the new content height
	# at the next layout pass. Grow or shrink its max by the same amount first, otherwise
	# zooming in clamps the scroll to the old height and the view snaps.
	var vbar := get_v_scroll_bar()
	vbar.max_value += lane_layout.total_height() - old_total_height

	# Apply scroll immediately (bypassing smooth scrolling for zoom)
	target_scroll_vertical = clampf(old_scroll + scroll_offset, 0.0, _max_scroll_v())
	scroll_vertical = roundi(target_scroll_vertical)



func _unhandled_input(event: InputEvent):
	"""Unhandled input handler - catch events not consumed by child nodes."""
	if not visible or not is_visible_in_tree():
		return

	if event is InputEventMouseButton:
		var mevent = event as InputEventMouseButton

		# Always catch right mouse release to exit erase mode (safety handler)
		if mevent.button_index == MOUSE_BUTTON_RIGHT and mevent.is_released():
			_stop_chord_preview()
			var active_editor = get_active_note_editor()
			if active_editor and (active_editor.erasing_mode or active_editor.interaction_mode == NoteEditor.InteractionMode.ERASING):
				logger.info("Right mouse released - forcing erase mode exit (safety handler)")
				active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
				on_interaction_finished()
				active_editor.erasing_mode = false
				_forget_erased_notes()
				_update_selection_overlays()
				accept_event()


func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		# Middle mouse button panning
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				# Start panning
				is_panning = true
				pan_start_mouse_pos = event.position
				# Start from what is on screen: the targets may still be animating
				pan_start_scroll_v = scroll_vertical
				pan_start_scroll_h = h_scroll.scroll_horizontal
				if _zoom_anchor_active and grid_helper:
					target_pixels_per_beat = grid_helper.pixels_per_beat
					_zoom_anchor_active = false
				pan_start_pixels_per_beat = grid_helper.pixels_per_beat if grid_helper else 0.0
				pan_start_h_scroll_mouse_pos = h_scroll.get_local_mouse_position()
				accept_event()
			else:
				# Stop panning
				is_panning = false
				accept_event()

		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if event.alt_pressed:
				# alt scroll up: scroll left
				target_scroll_horizontal = max(0, target_scroll_horizontal - scroll_speed_h)
			elif event.shift_pressed:
				# horizontal zoom in (smooth, like the arranger)
				_smooth_horizontal_zoom(zoom_sensitivity_h)
			elif event.ctrl_pressed:
				# vertical zoom in
				_zoom_vertical(zoom_sensitivity_v)
			else:
				# vertical scroll up
				target_scroll_vertical = max(0, target_scroll_vertical - scroll_speed_v)
			accept_event()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.alt_pressed:
				# alt scroll down: scroll right
				target_scroll_horizontal = clampf(target_scroll_horizontal + scroll_speed_h, 0.0, maxf(_max_scroll_h(), target_scroll_horizontal))
			elif event.shift_pressed:
				# horizontal zoom out (smooth, like the arranger)
				_smooth_horizontal_zoom(1.0 / zoom_sensitivity_h)
			elif event.ctrl_pressed:
				# vertical zoom out
				_zoom_vertical(-zoom_sensitivity_v)
			else:
				# scroll down
				target_scroll_vertical = minf(target_scroll_vertical + scroll_speed_v, _max_scroll_v())
			accept_event()

		# Delegate left/right mouse buttons to note editor
		elif event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			_handle_note_editing_mouse_button(event)

	elif event is InputEventMouseMotion:
		if is_panning:
			# Calculate the delta from the starting position
			var delta = event.position - pan_start_mouse_pos

			# Zoom or scroll based on modifiers
			if event.shift_pressed:
				# Shift + middle mouse: delta.y controls horizontal zoom proportionally, anchored at mouse position
				# Negative delta.y (moving up) = zoom in, positive (moving down) = zoom out
				# Scale the sensitivity by the starting zoom level for consistent feel across all zoom levels
				var zoom_factor = 1.0 - (delta.y * pan_zoom_sensitivity / 50)
				var new_ppb = pan_start_pixels_per_beat * zoom_factor
				new_ppb = clamp(new_ppb, zoom_min_pixels_per_beat, zoom_max_pixels_per_beat)

				# Calculate zoom ratio
				var zoom_ratio = new_ppb / pan_start_pixels_per_beat

				# Calculate the content position under the mouse anchor point before zoom
				var old_content_x = pan_start_scroll_h + pan_start_h_scroll_mouse_pos.x

				# Scale by zoom ratio
				var new_content_x = old_content_x * zoom_ratio

				# Calculate new scroll to keep the same content under the anchor point
				var zoom_scroll = new_content_x - pan_start_h_scroll_mouse_pos.x

				# Apply zoom
				grid_helper.pixels_per_beat = new_ppb
				# Direct write: cancel any in-flight wheel zoom animation
				target_pixels_per_beat = new_ppb
				_zoom_anchor_active = false

				# Apply horizontal panning on top of zoom scroll adjustment
				target_scroll_horizontal = max(0, zoom_scroll - delta.x)

				# Vertical scroll not affected when shift is pressed
				target_scroll_vertical = pan_start_scroll_v
			else:
				# Normal panning: Update scroll positions (negative delta because we're moving the viewport opposite to mouse movement)
				target_scroll_horizontal = clampf(pan_start_scroll_h - delta.x, 0.0, _max_scroll_h())
				target_scroll_vertical = clampf(pan_start_scroll_v - delta.y, 0.0, _max_scroll_v())

			# For panning, apply immediately for better responsiveness
			_set_h_scroll(target_scroll_horizontal, event.shift_pressed)
			scroll_vertical = roundi(target_scroll_vertical)


			accept_event()
		else:
			# Delegate mouse motion to note editor when not panning
			_handle_note_editing_mouse_motion(event)

	elif event is InputEventKey:
		# Only reached while MidiEditor itself holds focus (e.g. after using its
		# scrollbars). Normally the focused NoteEditor handles keys in its own
		# _gui_input and MidiEditor only sees the resulting key_input_handled.
		var active_editor = get_active_note_editor()
		if active_editor:
			active_editor.handle_key_input(event)
			# Selection may have changed (Ctrl+A); keep the range markers in step.
			_update_selection_overlays()


# ============================================================================
# NOTE EDITING INPUT DELEGATION
# ============================================================================
func _handle_note_editing_mouse_button(mevent: InputEventMouseButton) -> void:
	"""Delegate mouse button events to note editor."""
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	# Convert mouse position to active note_editor local space
	var note_editor_pos = active_editor.make_canvas_position_local(mevent.global_position)

	# Left mouse button
	if mevent.button_index == MOUSE_BUTTON_LEFT:
		if mevent.is_pressed():
			_handle_left_mouse_press(note_editor_pos, mevent)
		else:
			_handle_left_mouse_release(note_editor_pos, mevent)

	# Right mouse button - erase mode
	elif mevent.button_index == MOUSE_BUTTON_RIGHT:
		if mevent.is_pressed() and mevent.alt_pressed:
			# Alt+right-click: hear everything at this moment, for as long as it's held.
			_start_chord_preview(active_editor.pixels_to_ticks(note_editor_pos.x))
			accept_event()
		elif mevent.is_pressed():
			_handle_right_mouse_press(note_editor_pos, mevent)
		elif mevent.is_released():
			if not _scrubbing:
				_handle_right_mouse_release()
			else:
				_stop_chord_preview()
				accept_event()


## The note under a global position, or {}. The active editor's notes win, then the other
## editable tracks in list order (REQ-035); tracks that are hidden or not editable are never hit.
## A hit on the active track is {editor, visual}; a hit on any other track is
## {track, instance, data}, found in the data (the context layer has no nodes).
func _note_hit(global_pos: Vector2) -> Dictionary:
	var active := get_active_note_editor()
	if active:
		var note := active.get_note_at_position(active.make_canvas_position_local(global_pos))
		if note:
			return {"editor": active, "visual": note}
	if track_mode:
		return context_layer.note_at(context_layer.make_canvas_position_local(global_pos))
	return {}


## Erase a note of a track that only the context layer draws, as one undo step.
func _erase_context_note(hit: Dictionary) -> void:
	var instance: ClipInstance = hit.instance
	var data: MidiNoteData = hit.data
	var note_clip := instance.clip
	ClipNotesStateCommand.record_edit("Erase Note", note_clip, func(): note_clip.remove_midi_note(data))
	queue_row_rebuild()


func _erase_hit(hit: Dictionary) -> void:
	if hit.has("editor"):
		hit.editor.erase_note(hit.visual)
	else:
		_erase_context_note(hit)


func _forget_erased_notes() -> void:
	for editor in note_editors:
		if editor:
			editor.last_erased_note = null


## Note under a Ctrl+press, until the mouse either moves (duplicate) or is released
## (toggle selection).
var _ctrl_press_note: VisualNote = null
var _ctrl_press_pos: Vector2 = Vector2.ZERO


## Song tick and track of the last left press in the note area (a note or empty space), or
## -1 / null. ClipEditor uses it to pick the clip to focus when switching modes.
var last_interaction_song_tick: int = -1
var last_interaction_track: Track = null


func _handle_left_mouse_press(note_editor_pos: Vector2, mevent: InputEventMouseButton) -> void:
	"""Handle left mouse button press for note editing."""
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	# The group-scale handle sits past the notes, so it wins over everything under it.
	if not mevent.ctrl_pressed and active_editor.is_over_group_scale_handle(note_editor_pos) \
			and active_editor.begin_group_scale(note_editor_pos.x):
		accept_event()
		_update_selection_overlays()
		return

	# A note of another editable track switches to that track before the gesture starts: the
	# note editor is rebound to it and the press carries on as a press on its note.
	var hit := _note_hit(mevent.global_position)
	var clicked_note: VisualNote = hit.get("visual") if not hit.is_empty() else null
	if not hit.is_empty() and not hit.has("editor"):
		current_track = hit.track
		note_track_picked.emit(current_track)
		active_editor = get_active_note_editor()
		if not active_editor:
			return
		note_editor_pos = active_editor.make_canvas_position_local(mevent.global_position)
		# The visual under the mouse (a loop repeat, say), else the note's own.
		clicked_note = active_editor.get_note_at_position(note_editor_pos)
		if not clicked_note or clicked_note.midi_note_data != hit.data:
			clicked_note = active_editor.visual_for(hit.instance, hit.data)
		if not clicked_note:
			accept_event()
			return

	if grid_helper:
		var press_tick := grid_helper.pixels_to_ticks(note_editor_pos.x)
		last_interaction_song_tick = _editor_to_song_ticks(active_editor, press_tick)
		last_interaction_track = _editor_track(active_editor)

	if clicked_note:
		# Clicking on a note
		if not mevent.ctrl_pressed:
			_audition_visual_note(clicked_note)
		if mevent.ctrl_pressed:
			# Ctrl+click toggles selection on release; Ctrl+drag duplicates instead.
			_ctrl_press_note = clicked_note
			_ctrl_press_pos = mevent.global_position
			accept_event()
		elif clicked_note._is_over_resize_handle(note_editor_pos - clicked_note.position):
			active_editor._on_resize_started(clicked_note, note_editor_pos)
			active_editor.interaction_mode = NoteEditor.InteractionMode.RESIZING
			accept_event()
		else:
			active_editor._on_drag_started(clicked_note, note_editor_pos)
			active_editor.interaction_mode = NoteEditor.InteractionMode.DRAGGING
			accept_event()
	else:
		# Clicking on empty space
		if mevent.ctrl_pressed:
			active_editor.selection_manager.start_box_selection(note_editor_pos)
			active_editor.interaction_mode = NoteEditor.InteractionMode.BOX_SELECTING
			accept_event()
		else:
			var placed: VisualNote = active_editor.place_note_at_position(note_editor_pos)
			_audition_visual_note(placed)
			accept_event()

	_update_selection_overlays()


func _handle_left_mouse_release(note_editor_pos: Vector2, mevent: InputEventMouseButton) -> void:
	"""Handle left mouse button release for note editing."""
	_stop_preview_note()
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	if _ctrl_press_note:
		# Ctrl+click without a drag: plain selection toggle.
		if is_instance_valid(_ctrl_press_note):
			active_editor.selection_manager.toggle_note_selection(_ctrl_press_note)
		_ctrl_press_note = null
		accept_event()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.DUPLICATING:
		_stop_preview_note()
		active_editor.finish_duplicate_drag()
		on_interaction_finished()
		accept_event()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.BOX_SELECTING:
		var notes_in_box = active_editor.get_notes_in_box(active_editor.selection_manager.box_selection_rect)
		active_editor.selection_manager.end_box_selection(notes_in_box)
		active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		on_interaction_finished()
		accept_event()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.DRAGGING or active_editor.interaction_mode == NoteEditor.InteractionMode.PLACING_AND_DRAGGING:
		if active_editor.dragging_note:
			active_editor._on_drag_ended(active_editor.dragging_note)
		active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		on_interaction_finished()
		accept_event()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.SCALING:
		active_editor.end_group_scale()
		on_interaction_finished()
		_update_selection_overlays()
		accept_event()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.RESIZING:
		if active_editor.resizing_note:
			active_editor._on_resize_ended(active_editor.resizing_note)
		active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		on_interaction_finished()
		accept_event()

	elif active_editor.placed_note_awaiting_drag:
		logger.info("Note placed without drag")
		active_editor.update_container_width()
		active_editor.placed_note_awaiting_drag = null
		accept_event()
	else:
		accept_event()

	_update_selection_overlays()


func _handle_right_mouse_press(note_editor_pos: Vector2, mevent: InputEventMouseButton) -> void:
	"""Handle right mouse button press for erase mode."""
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	active_editor.interaction_mode = NoteEditor.InteractionMode.ERASING
	active_editor.erasing_mode = true
	active_editor.last_erased_note = null

	# Erasing works on any editable track's note and never switches the selected track.
	var hit := _note_hit(mevent.global_position)
	if not hit.is_empty():
		_erase_hit(hit)
		accept_event()
	else:
		active_editor.selection_manager.clear_selection()
		logger.info("Right-click on empty space - cleared selection, erase mode active")

	_update_selection_overlays()


func _handle_right_mouse_release() -> void:
	"""Handle right mouse button release - exit erase mode."""
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	if active_editor.erasing_mode or active_editor.interaction_mode == NoteEditor.InteractionMode.ERASING:
		logger.info("Right mouse released - exiting erase mode")
		active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
		on_interaction_finished()
		active_editor.erasing_mode = false
		_forget_erased_notes()
		_update_selection_overlays()


func _handle_note_editing_mouse_motion(mevent: InputEventMouseMotion) -> void:
	"""Delegate mouse motion to note editor."""
	var active_editor = get_active_note_editor()
	if not active_editor:
		return

	var note_editor_pos = active_editor.make_canvas_position_local(mevent.global_position)

	# Check for newly placed note waiting for drag
	if active_editor.placed_note_awaiting_drag and active_editor.placed_note_awaiting_drag.midi_note_data:
		var current_mouse_pos = get_global_mouse_position()
		var distance = current_mouse_pos.distance_to(active_editor.placed_note_mouse_pos)

		if distance >= active_editor.DRAG_THRESHOLD:
			logger.info("Starting drag after placement (moved %.1f pixels)" % distance)
			active_editor.start_place_and_drag(active_editor.placed_note_awaiting_drag)
			active_editor.placed_note_awaiting_drag = null
			accept_event()
			_update_selection_overlays()
			return

	# Ctrl held on a note and dragged past the threshold: start duplicating.
	if _ctrl_press_note:
		if not is_instance_valid(_ctrl_press_note):
			_ctrl_press_note = null
		elif get_global_mouse_position().distance_to(_ctrl_press_pos) >= active_editor.DRAG_THRESHOLD:
			var grabbed := _ctrl_press_note
			_ctrl_press_note = null
			var start_pos: Vector2 = active_editor.make_canvas_position_local(_ctrl_press_pos)
			if active_editor.start_duplicate_drag(grabbed, start_pos):
				_audition_visual_note(active_editor.dup_anchor)
				active_editor.update_duplicate_drag(note_editor_pos)
			accept_event()
			_update_selection_overlays()
			return

	# Handle active interactions
	if active_editor.interaction_mode == NoteEditor.InteractionMode.DUPLICATING:
		active_editor.update_duplicate_drag(note_editor_pos)
		_retrigger_audition_on_pitch_change(active_editor.dup_anchor)
		accept_event()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.BOX_SELECTING:
		active_editor.selection_manager.update_box_selection(note_editor_pos)
		var notes_in_box = active_editor.get_notes_in_box(active_editor.selection_manager.box_selection_rect)
		active_editor.selection_manager._set_selected_notes(notes_in_box)
		accept_event()
		_update_selection_overlays()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.DRAGGING or active_editor.interaction_mode == NoteEditor.InteractionMode.PLACING_AND_DRAGGING:
		if active_editor.dragging_note:
			active_editor._on_drag_updated(active_editor.dragging_note, note_editor_pos)
			_retrigger_audition_on_pitch_change(active_editor.dragging_note)
			accept_event()
			_update_selection_overlays()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.RESIZING:
		if active_editor.resizing_note:
			active_editor._on_resize_updated(active_editor.resizing_note, note_editor_pos)
			accept_event()
			_update_selection_overlays()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.SCALING:
		active_editor.update_group_scale_from_mouse(note_editor_pos)
		accept_event()
		_update_selection_overlays()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.ERASING:
		var hit := _note_hit(mevent.global_position)
		if not hit.is_empty() and (not hit.has("editor") or hit.visual != active_editor.last_erased_note):
			_erase_hit(hit)
			accept_event()
			_update_selection_overlays()

	elif active_editor.interaction_mode == NoteEditor.InteractionMode.NONE:
		active_editor.update_hover_cursor(note_editor_pos)
		_update_note_hover(active_editor.get_note_at_position(note_editor_pos) != null)
		# A note of another track can be clicked too: show the hand over it.
		if track_mode and active_editor.mouse_default_cursor_shape == Control.CURSOR_ARROW \
				and not context_layer.note_at(context_layer.make_canvas_position_local(mevent.global_position)).is_empty():
			active_editor.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


var _note_hover_on := false


## Help bar: while the pointer is over a note, show what dragging it can do. A state wins over
## hover, and a drag's own state (begun later) wins over this one.
func _update_note_hover(over_note: bool) -> void:
	if over_note == _note_hover_on:
		return
	_note_hover_on = over_note
	if over_note:
		Hotkeys.begin_state(self, "note_hover")
	else:
		Hotkeys.end_state(self)


func _exit_tree() -> void:
	_update_note_hover(false)


# ============================================================================
# TIME-RANGE SELECTION FROM THE RULER (Ctrl/Cmd drag)
# ============================================================================

## True while a Ctrl/Cmd drag that started on the ruler is box-selecting. The ruler
## keeps the mouse, so motion and release are followed in _input.
var _ruler_box_selecting := false


## Start a box select at note-editor content X that spans every row, so it picks
## notes purely by time.
func begin_time_range_selection(content_x: float) -> void:
	var active_editor := get_active_note_editor()
	if not active_editor:
		return
	active_editor.selection_manager.start_box_selection(Vector2(content_x, 0.0))
	active_editor.interaction_mode = NoteEditor.InteractionMode.BOX_SELECTING
	_ruler_box_selecting = true
	_update_ruler_box_selection()


func _update_ruler_box_selection() -> void:
	var active_editor := get_active_note_editor()
	if not active_editor:
		return
	var x := active_editor.get_local_mouse_position().x
	active_editor.selection_manager.update_box_selection(Vector2(x, lane_layout.total_height()))
	active_editor.selection_manager._set_selected_notes(active_editor.get_notes_in_box(active_editor.selection_manager.box_selection_rect))
	_update_selection_overlays()


func _input(event: InputEvent) -> void:
	if not _ruler_box_selecting:
		return
	if event is InputEventMouseMotion:
		_update_ruler_box_selection()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_ruler_box_selecting = false
		var active_editor := get_active_note_editor()
		if active_editor:
			var sm := active_editor.selection_manager
			sm.end_box_selection(active_editor.get_notes_in_box(sm.box_selection_rect))
			active_editor.interaction_mode = NoteEditor.InteractionMode.NONE
			on_interaction_finished()
			_update_selection_overlays()
			get_viewport().set_input_as_handled()


# ============================================================================
# SELECTION OVERLAYS UPDATE
# ============================================================================
func _update_selection_overlays() -> void:
	"""Update overlays with current selection state."""
	var active_editor = get_active_note_editor()
	if not active_editor or not active_editor.selection_manager or not grid_helper or not overlays:
		return

	var sm = active_editor.selection_manager

	# Update box selection
	overlays.is_box_selecting = sm.is_box_selecting
	if sm.is_box_selecting and sm.box_selection_rect.size.length() > 0:
		# Transform box from active_editor space to overlays space
		var box_global_pos = active_editor.get_global_transform() * sm.box_selection_rect.position
		var box_local_pos = overlays.make_canvas_position_local(box_global_pos)
		overlays.box_selection_rect = Rect2(box_local_pos, sm.box_selection_rect.size)
	else:
		# Clear the box when not actively selecting
		overlays.box_selection_rect = Rect2()

	# Update selection range markers
	var selection_length = sm.box_selection_end_tick - sm.box_selection_start_tick
	overlays.show_selection_markers = selection_length > 0

	if overlays.show_selection_markers:
		# Use the box_selection_start_tick and box_selection_end_tick directly
		# These are grid-snapped positions from the user's box selection gesture
		# In track-mode, these are already song-relative ticks (from ruler conversion)
		# In clip-mode, these are clip-local ticks
		# Do NOT add clip offsets - the ticks are already in the correct coordinate space

		var start_tick = sm.box_selection_start_tick
		var end_tick = sm.box_selection_end_tick

		# Convert to pixels in content space
		var start_x_content = grid_helper.ticks_to_pixels(start_tick)
		var end_x_content = grid_helper.ticks_to_pixels(end_tick)

		# Position relative to note_area, accounting for h_scroll offset (same as playhead)
		overlays.selection_start_x = start_x_content - h_scroll.scroll_horizontal + h_scroll.position.x
		overlays.selection_end_x = end_x_content - h_scroll.scroll_horizontal + h_scroll.position.x

	overlays.queue_redraw()


func _on_grid_helper_changed() -> void:
	"""Called when grid_helper properties change (zoom, scroll, time signature, etc.)"""
	_update_playhead_position()
	_update_selection_overlays()
	_check_scroll_growth()


# ============================================================================
# CONTENT WIDTH (shared by every note editor)
# ============================================================================

## Recompute the note area width after this frame. Editors ask for this whenever their
## content extent may have changed, so an edit touching many notes still costs one update.
func queue_content_width_update() -> void:
	if _content_width_queued:
		return
	_content_width_queued = true
	_flush_content_width.call_deferred()


func _flush_content_width() -> void:
	_content_width_queued = false
	update_content_width()


## Give every note editor the same width: the widest content plus extra_width_bars, at least
## min_width_bars, and at least as far as scrolling has grown it.
func update_content_width() -> void:
	if not grid_helper:
		return
	var bar := grid_helper.get_ticks_per_bar()
	var end_ticks := 0
	for editor in note_editors:
		if editor:
			end_ticks = maxi(end_ticks, editor.content_end_ticks())
	end_ticks = maxi(end_ticks, context_layer.content_end_ticks())
	_content_width_ticks = maxi(maxi(min_width_bars * bar, end_ticks + extra_width_bars * bar), _scroll_extent_ticks)
	var width := grid_helper.ticks_to_pixels(_content_width_ticks)
	for editor in note_editors:
		if editor:
			editor.custom_minimum_size.x = width
	context_layer.custom_minimum_size.x = width
	_check_scroll_growth()


## Grow the note area by whole scroll_growth_bars chunks once the view is within one
## viewport of its right edge. Cheap enough to run on every scroll step.
func _check_scroll_growth() -> void:
	if not grid_helper or not is_node_ready():
		return
	var needed := grid_helper.pixels_to_ticks(h_scroll.scroll_horizontal + 2.0 * h_scroll.size.x)
	if needed <= _content_width_ticks:
		return
	var chunk := maxi(1, scroll_growth_bars * grid_helper.get_ticks_per_bar())
	@warning_ignore("integer_division")
	_scroll_extent_ticks = maxi(_scroll_extent_ticks, (needed + chunk - 1) / chunk * chunk)
	queue_content_width_update()


func _update_playhead_position() -> void:
	"""Update the Playhead control position based on playhead_ticks."""
	if not grid_helper or not playhead:
		return

	if playhead_ticks < 0:
		playhead.visible = false
		return

	# Convert ticks to pixels in content space
	var playhead_x_content = grid_helper.ticks_to_pixels(playhead_ticks)

	# Position relative to note_area, accounting for h_scroll offset
	var x: float = playhead_x_content - h_scroll.scroll_horizontal + h_scroll.position.x
	playhead.position.x = x - 3 # offset to center the playhead on the pixel, it's 3px wide.
	# It draws above the notes (z_index), so it must also stay off the piano keys when
	# scrolled out of the note area.
	playhead.visible = x >= 0.0 and x <= note_area.size.x


func _update_note_editor_states() -> void:
	"""Track mode: give the context layer the tracks it draws and can hit. Clip mode: the note
	editor is the only thing shown."""
	if not track_mode:
		for editor in note_editors:
			if editor:
				editor.z_index = 1
				editor.modulate.a = 1.0
		context_layer.set_tracks([], [])
		context_layer.excluded_track = null
		return

	# The context layer dims per track: editable tracks slightly, view-only ones more.
	context_layer.set_tracks(_view_tracks, editable_tracks)
	context_layer.excluded_track = current_track
	var active := get_active_note_editor()
	if active:
		active.z_index = 1
		active.modulate.a = 1.0


func _on_note_editor_selection_changed(_notes: Array[VisualNote]) -> void:
	selection_changed.emit()


## Keep a note editor sized to content and wired to this MidiEditor's grid.
## The scene editor is reused across binds; re-assigning grid_helper reconnects
## zoom/scroll so its notes keep following the piano roll.
func _configure_note_editor(editor: NoteEditor) -> void:
	if editor == null:
		return
	editor.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	editor.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	editor.layout = lane_layout
	editor.scale_context = scale_context
	if not editor.notes_changed.is_connected(queue_row_rebuild):
		editor.notes_changed.connect(queue_row_rebuild)
	if not editor.content_extent_changed.is_connected(queue_content_width_update):
		editor.content_extent_changed.connect(queue_content_width_update)
	if not editor.notes_changed.is_connected(_invalidate_sounding):
		editor.notes_changed.connect(_invalidate_sounding)
	# The focused note editor handles keys itself (see NoteEditor._gui_input); the
	# range overlays are ours, so refresh them when that changed the selection.
	if not editor.selection_range_restored.is_connected(_update_selection_overlays):
		editor.selection_range_restored.connect(_update_selection_overlays)
	if not editor.key_input_handled.is_connected(_update_selection_overlays):
		editor.key_input_handled.connect(_update_selection_overlays)
	if editor.selection_manager and not editor.selection_manager.selection_changed.is_connected(_on_note_editor_selection_changed):
		editor.selection_manager.selection_changed.connect(_on_note_editor_selection_changed)
	editor.next_values = next_note_values
	if not editor.note_touched.is_connected(next_note_values.take_from):
		editor.note_touched.connect(next_note_values.take_from)
	editor.note_height = note_height
	editor.cursor_position_ticks = cursor_position_ticks
	if grid_helper:
		editor.grid_helper = grid_helper


# ============================================================================
# KEY HOVER + NOTE PREVIEW (piano keys and audition mode)
# ============================================================================
func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		_stop_preview_note()
		_stop_chord_preview()
		v_piano.hovered_note = -1
		drum_row_header.hovered_note = -1


## Highlight the piano key for the lane under the mouse (note area or piano).
func _update_hovered_key() -> void:
	var note := -1
	var header: Control = drum_row_header if drum_view else v_piano
	var hovered: Control = get_viewport().gui_get_hovered_control() if is_visible_in_tree() else null
	if hovered and (hovered == self or is_ancestor_of(hovered)) and not is_panning:
		if hovered == header:
			note = header.get_note_at_position(header.get_local_mouse_position())
		else:
			var y := note_lanes.get_local_mouse_position().y
			if y >= 0.0 and y < lane_layout.total_height():
				note = lane_layout.y_to_pitch(y)
	header.hovered_note = note
	_update_hovered_note(hovered)


# ============================================================================
# VALUE LANES (docs/specs/019-note-values)
# ============================================================================

## Current width of the visible key column.
func key_column_width() -> float:
	var header: Control = drum_row_header if drum_view else v_piano
	return header.size.x


func _emit_key_column_width() -> void:
	var w := key_column_width()
	if not is_equal_approx(w, _last_key_column_width):
		_last_key_column_width = w
		key_column_width_changed.emit(w)


## One entry per visible, editable note shown by the note editors, for the value lanes:
## visual, note_data, clip, color, ghost, selected, x_start and x_end. x are in the
## coordinates of the HScroll (its scrolled content is shifted, so the scroll is included).
## Context notes (other tracks) are not in note_editors, so they get no stems. A stem is a
## ghost when it is a loop repeat or another instance's visual of a note already listed.
func value_stems() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary = {}
	var folded := lane_layout.is_drum()
	for editor in note_editors:
		if editor == null:
			continue
		var color: Color = editor.note_color if track_mode else Color(0.3, 0.6, 0.9)
		var selected: Array[VisualNote] = editor.selection_manager.selected_notes if editor.selection_manager else ([] as Array[VisualNote])
		for vn in editor.get_all_visual_notes():
			var nd := vn.midi_note_data
			var x0 := editor.position.x + vn.position.x  # the editor's own position already carries the scroll
			var x1 := x0 + (editor.ticks_to_pixels(nd.duration_ticks) if folded else vn.size.x)
			var ghost := vn.repeat_pass > 0 or seen.has(nd)
			seen[nd] = true
			out.append({
				"visual": vn,
				"note_data": nd,
				"clip": editor._clip_for_visual_note(vn),
				"color": color,
				"ghost": ghost,
				"selected": vn in selected,
				"x_start": x0,
				"x_end": x1,
			})
	return out


func _on_row_select_requested(row: int, additive: bool) -> void:
	var pitch := lane_layout.pitch_at_row(row)
	if pitch >= 0:
		_select_pitch(pitch, additive)


## Select the editable notes of `pitch` (a drum row is one pitch). `additive` keeps the
## current selection too.
func _select_pitch(pitch: int, additive: bool) -> void:
	var editor := get_active_note_editor()
	if editor == null or editor.selection_manager == null:
		return
	var picked: Array[VisualNote] = []
	if additive:
		picked.append_array(editor.selection_manager.selected_notes)
	for vn in editor.get_all_visual_notes():
		if vn.midi_note_data.note == pitch and vn not in picked:
			picked.append(vn)
	editor.selection_manager.select_all(picked)
	_update_selection_overlays()


## Union of the selected notes of every note editor.
func selected_note_data() -> Array[MidiNoteData]:
	var out: Array[MidiNoteData] = []
	for editor in note_editors:
		if editor == null or editor.selection_manager == null:
			continue
		for vn in editor.selection_manager.selected_notes:
			if vn.midi_note_data and vn.midi_note_data not in out:
				out.append(vn.midi_note_data)
	return out


## Highlight `nd` in the note area (a stem under the pointer), or clear with null.
func set_hovered_note(nd: MidiNoteData) -> void:
	if nd == hovered_note_data:
		return
	hovered_note_data = nd
	for editor in note_editors:
		if editor == null:
			continue
		for child in editor.get_children():
			if child is VisualNote:
				child.set_value_hover(nd != null and child.midi_note_data == nd)
	hovered_note_changed.emit(nd)


## Follows the pointer over the note area. Only re-tests when the mouse moved.
func _update_hovered_note(hovered: Control) -> void:
	var over_area := hovered != null and note_area.is_ancestor_of(hovered) and not is_panning
	if not over_area:
		if _hover_from_area:
			_hover_from_area = false
			set_hovered_note(null)
		return
	var mouse := get_global_mouse_position()
	if mouse == _last_hover_mouse:
		return
	_last_hover_mouse = mouse
	var editor := get_active_note_editor()
	if editor == null:
		return
	var vn := editor.get_note_at_position(editor.make_canvas_position_local(mouse))
	_hover_from_area = vn != null
	set_hovered_note(vn.midi_note_data if vn else null)


# ============================================================================
# NOTE MAPS AND DRUM VIEW
# ============================================================================

## Channel whose note map applies: the focused track's in track-mode, otherwise
## the bound clip's track's.
func get_active_channel() -> Channel:
	var t: Track = current_track if track_mode else (clip_instance.track if clip_instance else null)
	if t == null:
		return null
	# The track's own link first: it needs no editor, which keeps this usable
	# headless and during load, before Sonara.editor is wired up.
	var ch := t.get_linked_channel()
	if ch:
		return ch
	var project: Project = Sonara.editor.project if Sonara.editor else null
	return project.get_channel_by_id(t.default_channel_id) if project else null


## Re-bind the watcher and re-resolve the map for the channel now in focus. Called
## whenever the binding changes; the watcher then keeps it current by itself.
func refresh_note_map() -> void:
	var channel := get_active_channel()
	if channel != _watched_channel:
		_watched_channel = channel
		_note_map_watcher.bind(channel)
	_bind_live_channel(channel)
	note_map = NoteMapResolver.effective_map(channel)
	scale_context.keyswitches = note_map.keyswitches
	v_piano.note_map = note_map
	note_lanes.note_map = note_map
	drum_row_header.note_map = note_map
	rebuild_rows()
	view_state_changed.emit()


## The Auto map's source changed (a pad renamed, moved, added or recoloured), or
## the assignment did. Coalesced to one call per frame by NoteMapWatcher.
func _on_note_map_changed() -> void:
	refresh_note_map()


## Whether this channel's clips should open in Drum View (REQ-028).
func wants_drum_view() -> bool:
	return NoteMapResolver.wants_drum_view(get_active_channel())


## Every clip instance currently on screen: all of the visible tracks' in track mode.
func _visible_clips() -> Array:
	var clips: Array = []
	if track_mode:
		for t in _view_tracks:
			clips.append_array(t.clip_instances)
		return clips
	for editor in note_editors:
		if editor == null:
			continue
		if editor.multi_clip_mode:
			clips.append_array(editor.clip_instances)
		elif editor.clip_instance:
			clips.append(editor.clip_instance)
	return clips


## Rows for Drum View: the union across every editor of its map's pitches and the
## pitches its clips use (REQ-016, REQ-024).
func compute_rows() -> PackedInt32Array:
	if not drum_view and scale_context.fold_active():
		return ScaleRows.rows_for(scale_context.scale, _visible_clips())
	return DrumRows.rows_for(note_map, _visible_clips())


## The rows are a folded list: Drum View, or the piano roll folded to the project scale.
func _rows_folded() -> bool:
	return drum_view or scale_context.fold_active()


## Scale, snap, fold or keyswitches changed. Fold flipping switches the layout mode; a new
## scale while folded rebuilds the rows (deferred during a drag by rebuild_rows).
func _on_scale_context_changed() -> void:
	if _syncing_drum_view or not is_node_ready():
		return
	var fold := scale_context.fold_active()
	if fold != _fold_applied:
		_apply_view_mode()
	elif fold and _scale_key() != _fold_scale_key:
		_fold_scale_key = _scale_key()
		rebuild_rows()


func _scale_key() -> String:
	return "%d:%s" % [scale_context.scale.root, scale_context.scale.type_id]


## Recompute the folded row set. Deferred while a drag is running so rows can't
## reshuffle under the cursor (REQ-021); the drag's end calls this again.
func rebuild_rows() -> void:
	if not _rows_folded():
		return
	var active := get_active_note_editor()
	if active and active.interaction_mode != NoteEditor.InteractionMode.NONE:
		_rows_dirty = true
		return
	_rows_dirty = false
	lane_layout.set_rows(compute_rows(), drum_view)
	_update_empty_hint()
	view_state_changed.emit()


## Called when an interaction finishes, so a row set that changed mid-drag is
## applied once the cursor is released (REQ-021).
func on_interaction_finished() -> void:
	if _rows_dirty:
		rebuild_rows()


## Ask for a row rebuild after the current frame. Notes added, erased or dragged
## to a new pitch change the row set; while a drag is running rebuild_rows()
## defers itself, and on_interaction_finished() picks it up on release.
func queue_row_rebuild() -> void:
	if not _rows_folded() or _rebuild_queued:
		return
	_rows_dirty = true
	_rebuild_queued = true
	_flush_row_rebuild.call_deferred()


func _flush_row_rebuild() -> void:
	_rebuild_queued = false
	rebuild_rows()


## Swap the header controls and the layout mode, keeping the selection and a
## visible pitch on screen (REQ-015).
func _apply_view_mode() -> void:
	if not is_inside_tree():
		return
	# A pitch that is on screen now, so the same row can be brought back after the
	# switch. Selection lives in the note editors and is untouched either way.
	var anchor := _visible_anchor_pitch()

	v_piano.visible = not drum_view
	drum_row_header.visible = drum_view
	_fold_applied = scale_context.fold_active()
	_fold_scale_key = _scale_key()
	if _rows_folded():
		lane_layout.set_rows(compute_rows(), drum_view)
	else:
		lane_layout.set_chromatic()
	_rows_dirty = false

	if anchor >= 0 and lane_layout.row_of_pitch(anchor) >= 0:
		call_deferred("scroll_to_note", anchor)
	_update_empty_hint()
	view_state_changed.emit()


## A pitch to keep in view across a mode switch: the first selected note's, else
## whatever sits in the middle of the viewport.
func _visible_anchor_pitch() -> int:
	var active := get_active_note_editor()
	if active and active.selection_manager:
		for vn in active.selection_manager.selected_notes:
			if vn and vn.midi_note_data:
				return vn.midi_note_data.note
	if lane_layout.total_height() <= 0:
		return -1
	return lane_layout.y_to_pitch(scroll_vertical + size.y * 0.5)


## True when Drum View has nothing to show, so ClipEditor can offer the hint
## that opens the note map editor (REQ-023).
func drum_view_is_empty() -> bool:
	return drum_view and lane_layout.row_count() == 0


## Show or hide the "nothing to show here" hint over the note area (REQ-023).
func _update_empty_hint() -> void:
	var should_show := drum_view_is_empty()
	if _empty_hint == null:
		if not should_show:
			return
		_empty_hint = Button.new()
		_empty_hint.name = "DrumViewEmptyHint"
		_empty_hint.text = "No drum rows yet — set up a note map for this channel"
		_empty_hint.flat = true
		_empty_hint.focus_mode = Control.FOCUS_NONE
		_empty_hint.mouse_filter = Control.MOUSE_FILTER_STOP
		_empty_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		_empty_hint.offset_top = 24.0
		_empty_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_empty_hint.pressed.connect(func(): note_map_editor_requested.emit())
		note_area.add_child(_empty_hint)
	_empty_hint.visible = should_show


## Channel that previews should play on: the focused track in track-mode,
## otherwise the bound clip's track.
func _get_preview_channel_id() -> int:
	var t: Track = current_track if track_mode else (clip_instance.track if clip_instance else null)
	return t.default_channel_id if t else -1


func _start_preview_note(note: int, velocity: float) -> void:
	_stop_preview_note()
	var channel_id := _get_preview_channel_id()
	if channel_id < 0:
		return
	_preview_note = note
	_preview_channel_id = channel_id
	MidiManager.send_note_to_channel(channel_id, note, MidiNoteData.to_midi_velocity(velocity), true)


func _stop_preview_note() -> void:
	if _preview_note < 0:
		return
	MidiManager.send_note_to_channel(_preview_channel_id, _preview_note, 0, false)
	_preview_note = -1
	_preview_channel_id = -1


# ============================================================================
# CHORD PREVIEW (Alt + right mouse button)
# ============================================================================

## True from an Alt+right press until the button is released: a vertical line follows the
## mouse and sounds whatever it crosses.
var _scrubbing := false
## Pitches currently sounding from the scrub, with the channel they went to.
var _chord_preview_notes: Array[int] = []
var _chord_preview_channel_id := -1
var _scrub_tick := -1


## Start the scrub: play every note of the active editor that sounds at `tick`. While held,
## `_update_scrub` follows the mouse and sounds notes the line moves onto.
func _start_chord_preview(tick: int) -> void:
	_stop_chord_preview()
	if not get_active_note_editor() or _get_preview_channel_id() < 0:
		return
	_scrubbing = true
	_chord_preview_channel_id = _get_preview_channel_id()
	_apply_scrub_tick(tick)
	_update_scrub_line()


## Move the line to `tick`: release pitches it left, sound (and flash) the ones it reached.
## A pitch that stays under the line keeps ringing instead of retriggering.
func _apply_scrub_tick(tick: int) -> void:
	var active_editor := get_active_note_editor()
	if not active_editor:
		return
	_scrub_tick = tick
	# Trimmed-away content still previews: the click is about what is drawn there.
	var visuals := active_editor.visuals_sounding_at(tick, false)
	var now := {}
	for vn in visuals:
		var pitch := vn.midi_note_data.note
		now[pitch] = maxf(now.get(pitch, 0.0), vn.midi_note_data.velocity)
	for pitch in _chord_preview_notes.duplicate():
		if not now.has(pitch):
			MidiManager.send_note_to_channel(_chord_preview_channel_id, pitch, MidiManager.NOTE_OFF_RELEASE, false)
			_chord_preview_notes.erase(pitch)
	for pitch in now:
		if _chord_preview_notes.has(pitch):
			continue
		_chord_preview_notes.append(pitch)
		MidiManager.send_note_to_channel(_chord_preview_channel_id, pitch, MidiNoteData.to_midi_velocity(now[pitch]), true)
		for vn in visuals:
			if vn.midi_note_data.note == pitch:
				overlays.add_glow(vn)


## Called every frame while scrubbing, so scrolling under a held mouse keeps it going.
func _update_scrub() -> void:
	var active_editor := get_active_note_editor()
	if not active_editor:
		_stop_chord_preview()
		return
	var tick := active_editor.pixels_to_ticks(active_editor.make_canvas_position_local(get_global_mouse_position()).x)
	if tick != _scrub_tick:
		_apply_scrub_tick(tick)
	_update_scrub_line()


func _update_scrub_line() -> void:
	var x := overlays.make_canvas_position_local(get_global_mouse_position()).x
	overlays.set_scrub_x(clampf(x, 0.0, overlays.size.x))


func _stop_chord_preview() -> void:
	for pitch in _chord_preview_notes:
		MidiManager.send_note_to_channel(_chord_preview_channel_id, pitch, MidiManager.NOTE_OFF_RELEASE, false)
	_chord_preview_notes.clear()
	_chord_preview_channel_id = -1
	_scrub_tick = -1
	if _scrubbing:
		_scrubbing = false
		if overlays:
			overlays.set_scrub_x(-1.0)


# ============================================================================
# HELD KEYS: live MIDI on the active channel, and notes under the playhead
# ============================================================================

## Set by ClipEditor from the editor's playback signals; while true, the notes under
## the playhead show as held keys.
var transport_playing := false

## Pitch -> true for notes held live on the active channel (MIDI input, virtual
## keyboard, previews), from Channel.live_note.
var _live_notes: Dictionary = {}
var _live_channel: Channel = null

## What the active editor had sounding at _sounding_tick, so the scan only reruns when
## the playhead moves (it reports ~20 times a second, the editor redraws every frame).
var _sounding: Dictionary = {}
var _sounding_tick := -1
var _sounding_editor: NoteEditor = null


func _invalidate_sounding() -> void:
	_sounding_tick = -1


## Follow live notes on the channel now in focus.
func _bind_live_channel(channel: Channel) -> void:
	if channel == _live_channel:
		return
	if _live_channel and is_instance_valid(_live_channel) and _live_channel.live_note.is_connected(_on_live_note):
		_live_channel.live_note.disconnect(_on_live_note)
	_live_channel = channel
	_live_notes.clear()
	if _live_channel:
		_live_channel.live_note.connect(_on_live_note)


func _on_live_note(pitch: int, _velocity: int, is_on: bool) -> void:
	if is_on:
		_live_notes[pitch] = true
	else:
		_live_notes.erase(pitch)


## Show held keys on the header: live notes, plus whatever the active editor has under
## the playhead while the transport runs.
func _update_active_keys() -> void:
	var held := _live_notes
	if transport_playing and playhead_ticks >= 0:
		var active_editor := get_active_note_editor()
		if active_editor:
			if playhead_ticks != _sounding_tick or active_editor != _sounding_editor:
				_sounding = active_editor.pitches_sounding_at(playhead_ticks)
				_sounding_tick = playhead_ticks
				_sounding_editor = active_editor
			held = _sounding.duplicate()
			held.merge(_live_notes)
	var header = drum_row_header if drum_view else v_piano
	header.set_active_notes(held)


func _on_piano_key_pressed(note: int, velocity: int) -> void:
	_start_preview_note(note, MidiNoteData.from_midi_velocity(velocity))


func _on_piano_key_released(note: int) -> void:
	if note == _preview_note:
		_stop_preview_note()


func _audition_visual_note(vn: VisualNote) -> void:
	if not audition_enabled or vn == null or vn.midi_note_data == null:
		return
	_start_preview_note(vn.midi_note_data.note, vn.midi_note_data.velocity)


## Minimum time between audition retriggers during a drag (about twice per second).
const AUDITION_THROTTLE_MSEC := 500
var _last_throttled_audition_msec := -AUDITION_THROTTLE_MSEC


## True, and starts a new interval, when a drag-driven audition may sound now. A refused
## retrigger is not remembered, so the next mouse move tries again with the then-current value.
func audition_throttle_ready() -> bool:
	var now := Time.get_ticks_msec()
	if now - _last_throttled_audition_msec < AUDITION_THROTTLE_MSEC:
		return false
	_last_throttled_audition_msec = now
	return true


## While dragging with audition on, replay the note whenever its pitch changes (throttled).
func _retrigger_audition_on_pitch_change(vn: VisualNote) -> void:
	if not audition_enabled or _preview_note < 0 or vn == null or vn.midi_note_data == null:
		return
	if vn.midi_note_data.note != _preview_note and audition_throttle_ready():
		_start_preview_note(vn.midi_note_data.note, vn.midi_note_data.velocity)
