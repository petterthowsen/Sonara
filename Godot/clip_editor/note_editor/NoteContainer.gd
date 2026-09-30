## Base container for rendering and positioning MIDI notes.
## Handles visual note lifecycle, coordinate conversion, and layout.
class_name NoteContainer extends Container

static var logger := Log.make("NoteContainer")

#=========================================================
# CONSTANTS
#=========================================================
# MIDI range - use Midi singleton constants
const MIDI_MIN: int = Midi.MIDI_MIN    # C-2 (MIDI 0)
const MIDI_MAX: int = Midi.MIDI_MAX    # G9 (MIDI 127)
const MIDI_RANGE: int = MIDI_MAX - MIDI_MIN + 1

# VisualNote scene
const visual_note_scene = preload("res://clip_editor/VisualNote.tscn")


#=========================================================
# PROPERTIES
# These must be set by the parent ClipEditor/MidiEditor
#=========================================================
## A note was added, removed or changed, so the set of pitches in use may have
## moved. MidiEditor listens to rebuild Drum View's rows (REQ-016).
signal notes_changed

## Something that sets how far right the content reaches changed (notes, instances). The
## owner (MidiEditor) recomputes one width for all its editors; see content_end_ticks().
signal content_extent_changed

## Shared pitch <-> row <-> Y math, handed down by MidiEditor. Defaults to its own
## chromatic layout so a standalone NoteEditor still positions notes.
var layout: LaneLayout = LaneLayout.chromatic():
	set(l):
		if layout == l:
			return
		if layout and layout.changed.is_connected(_on_layout_changed):
			layout.changed.disconnect(_on_layout_changed)
		layout = l if l else LaneLayout.chromatic()
		layout.changed.connect(_on_layout_changed)
		_on_layout_changed()

@export var note_height := 20.0:
	set(nh):
		if note_height != nh:
			note_height = nh
			if layout and not is_equal_approx(layout.row_height, nh):
				layout.row_height = nh
			# Notify parent ScrollContainer that our size changed
			# and queue relayout
			update_minimum_size()
			_queue_reposition()


## Rows or row height changed: every note needs repositioning and the container
## needs to resize (Drum View is far shorter than 128 chromatic lanes).
func _on_layout_changed() -> void:
	update_minimum_size()
	_queue_reposition()


## Set when notes must be repositioned on the next sort. Other sorts (a width change,
## for example) leave note positions alone: they depend only on ticks, pitch and scale.
var _positions_dirty := false


func _queue_reposition() -> void:
	_positions_dirty = true
	queue_sort()

# Grid helper which must be set by the parent ClipEditor/MidiEditor
var grid_helper: GridHelper = null:
	set = set_grid_helper


func set_grid_helper(gh: GridHelper) -> void:
	# Disconnect from old grid_helper if it exists
	if grid_helper and grid_helper.scale_changed.is_connected(_on_grid_scale_changed):
		grid_helper.scale_changed.disconnect(_on_grid_scale_changed)
	
	grid_helper = gh
	
	# Only scale changes move notes: the notes scroll with h_scroll, not with
	# scroll_position, so scrolling needs no work here.
	if grid_helper:
		grid_helper.scale_changed.connect(_on_grid_scale_changed)
	
	_update_note_positions()
	update_container_width()


func _on_grid_scale_changed() -> void:
	"""Zoom, ppq, time signature or grid spacing changed (never plain scrolling)."""
	# MidiEditor rescales the shared width itself on the same signal.
	_update_note_positions()


# Should be set to track or clip color
var note_color = Color(0.3, 0.6, 0.9):
	set(nc):
		if note_color != nc:
			note_color = nc
			# The shared boxes are per display colour; the old ones are no longer used.
			_style_cache.clear()
			# Notify all visual notes to update their color
			for node in get_children():
				if node is VisualNote:
					node.set_color(note_color)


# Horizontal scroll is derived from grid_helper.scroll_position


# Position offset for song-relative positioning in track-mode
# Set to clip_instance.start_ticks in track-mode, 0 in clip-mode
var position_offset_ticks: int = 0:
	set(value):
		if position_offset_ticks != value:
			position_offset_ticks = value
			_update_note_positions()
			update_container_width()


## Display colour -> StyleBoxFlat shared by every note drawn in that colour. Velocity
## shading is quantised (VisualNote.VELOCITY_SHADES), so this stays small.
var _style_cache: Dictionary = {}
## Text colour -> LabelSettings shared by every note label in that colour.
var _label_settings_cache: Dictionary = {}


## The shared stylebox for notes of `color`, made from the note scene's `base` box.
func note_style(base: StyleBoxFlat, color: Color) -> StyleBoxFlat:
	var box: StyleBoxFlat = _style_cache.get(color)
	if box == null:
		box = base.duplicate()
		box.bg_color = color
		_style_cache[color] = box
	return box


## The shared label settings for note labels drawn in `text_color`.
func note_label_settings(base: LabelSettings, text_color: Color) -> LabelSettings:
	var settings: LabelSettings = _label_settings_cache.get(text_color)
	if settings == null:
		settings = base.duplicate()
		settings.font_color = text_color
		settings.shadow_color = Utils.contrasting_shadow_color(text_color)
		_label_settings_cache[text_color] = settings
	# A note can switch colour between row-height changes (a velocity drag), so hand the
	# settings out at the current size.
	var fs := VisualNote.label_font_size_for(layout.row_height)
	if fs > 0 and settings.font_size != fs:
		settings.font_size = fs
	return settings


# SINGLE-CLIP MODE: The clip instance that opened this editor (for context, not edited directly)
var clip_instance: ClipInstance = null

# Convenience to get the Clip of clip_instance
var clip: Clip:
	get:
		return clip_instance.clip if clip_instance else null
	set(clip):
		pass

# MULTI-CLIP MODE: Multiple clip instances for track-mode
# TODO: rename to track_mode since that's what ClipEditor calls it ?
var clip_instances: Array[ClipInstance] = []
var track: Track = null  # Track that owns these clips
var multi_clip_mode: bool = false

# Container for notes
# SINGLE-CLIP MODE: note_id -> VisualNote
# MULTI-CLIP MODE: note_id -> {visual_note: VisualNote, clip_instance: ClipInstance}
var visual_notes_by_id: Dictionary = {}

## MULTI-CLIP MODE: note id -> Array of the VisualNotes showing it, in creation order (one
## per instance of the owning clip; ids from different clips can also collide). Lets
## lookups by bare id skip scanning every child. Pending duplicates are never in it.
var _visuals_by_note_id: Dictionary = {}

## MULTI-CLIP MODE: note key (see _make_note_key) -> Array of the note's loop repeat visuals,
## index k - 1 for loop segment k (null where it never played). A repeat whose note stops
## playing in its pass is hidden, not freed, so a drag can move a note out and back in.
var _repeats: Dictionary = {}
## MULTI-CLIP MODE: ClipInstance -> its loop segments ([] when not looping), as the repeats
## were last built for.
var _loop_segments: Dictionary = {}


func _index_visual(vn: VisualNote) -> void:
	var id := vn.midi_note_data.id
	var list: Array = _visuals_by_note_id.get(id, [])
	list.append(vn)
	_visuals_by_note_id[id] = list


func _unindex_visual(vn: VisualNote, id: int) -> void:
	var list: Array = _visuals_by_note_id.get(id, [])
	list.erase(vn)
	if list.is_empty():
		_visuals_by_note_id.erase(id)


## Track mode: the visuals of `note_data` on every instance of `source_clip` on this track.
func _visuals_of(note_data: MidiNoteData, source_clip: Clip) -> Array[VisualNote]:
	var out: Array[VisualNote] = []
	for ci in _instances_of_clip(source_clip):
		var entry = visual_notes_by_id.get(_make_note_key(ci, note_data))
		if entry is Dictionary and is_instance_valid(entry.visual_note):
			out.append(entry.visual_note)
	return out

## Unique key per (clip_instance, note_id) to avoid collisions when instances share a Clip.
func _make_note_key(ci: ClipInstance, nd: MidiNoteData) -> String:
	return _note_dict_key(ci, nd.id if nd else -1)


## Dictionary key for a visual note: clip-instance id plus note id, or single-clip fallback.
func _note_dict_key(ci: ClipInstance, note_id: int) -> String:
	if ci:
		return "%s:%d" % [str(ci.id), note_id]
	return "single:%d" % note_id


## Wire a clip's note signals, binding the clip itself so the handlers know which
## clip the note belongs to. A clip can appear on the track more than once, so the
## is_connected guards keep repeated instances from connecting twice.
func _connect_clip_signals(c: Clip) -> void:
	# The bound Callable is what gets connected, so it is also what is_connected and
	# disconnect must be given; a bare _on_clip_note_added never matches it.
	var on_added := _on_clip_note_added.bind(c)
	var on_removed := _on_clip_note_removed.bind(c)
	var on_changed := _on_clip_note_changed.bind(c)
	if not c.midi_note_added.is_connected(on_added):
		c.midi_note_added.connect(on_added)
	if not c.midi_note_removed.is_connected(on_removed):
		c.midi_note_removed.connect(on_removed)
	if not c.midi_note_changed.is_connected(on_changed):
		c.midi_note_changed.connect(on_changed)


func _disconnect_clip_signals(c: Clip) -> void:
	var on_added := _on_clip_note_added.bind(c)
	var on_removed := _on_clip_note_removed.bind(c)
	var on_changed := _on_clip_note_changed.bind(c)
	if c.midi_note_added.is_connected(on_added):
		c.midi_note_added.disconnect(on_added)
	if c.midi_note_removed.is_connected(on_removed):
		c.midi_note_removed.disconnect(on_removed)
	if c.midi_note_changed.is_connected(on_changed):
		c.midi_note_changed.disconnect(on_changed)


## Every clip instance on this track that plays `c`. Notes are clip-local and shared
## by all instances of that clip, so a note edit shows up once per matching instance
## and never on instances of a different clip.
func _instances_of_clip(c: Clip) -> Array[ClipInstance]:
	var out: Array[ClipInstance] = []
	for ci in clip_instances:
		if ci and ci.clip == c:
			out.append(ci)
	return out


## Track mode: follow an instance being moved, trimmed or resized in the arranger.
func _watch_instance(ci: ClipInstance) -> void:
	if ci and not ci.instance_modified.is_connected(_on_instance_modified):
		ci.instance_modified.connect(_on_instance_modified)
	if ci:
		_loop_segments.erase(ci)


func _on_instance_modified() -> void:
	# A moved instance keeps its repeats; a loop, trim or length change can add or drop passes.
	for ci in clip_instances:
		if ci and ci.clip and _compute_loop_segments(ci) != _loop_segments.get(ci, []):
			_loop_segments.erase(ci)
			for nd in ci.clip.midi_notes:
				_sync_repeats(ci, nd)
	_update_note_positions()
	update_container_width()


# ============================================================================
# LOOP REPEATS (track mode)
# ============================================================================
# A looped instance plays its loop region again after the first pass. Each later pass shows
# the notes it plays as VisualNotes of their own (repeat_pass >= 1), bound to the same
# MidiNoteData, so they look and behave like the note: hit-testing, box selection, labels and
# the selection look all come for free, and an edit made through any of them edits the note.

func _compute_loop_segments(ci: ClipInstance) -> Array[Vector3i]:
	if ci.loop_enabled and ci.loop_length_ticks > 0:
		return ci.get_loop_segments()
	return []


## The loop segments of `ci` (cached until its loop, trim or length changes).
func _segments_for(ci: ClipInstance) -> Array[Vector3i]:
	var segs = _loop_segments.get(ci)
	if segs == null:
		segs = _compute_loop_segments(ci)
		_loop_segments[ci] = segs
	return segs


## Make `nd`'s repeat visuals on `ci` match the passes it plays in: create the missing ones,
## hide the ones it no longer plays in, and free those past the instance's last pass.
func _sync_repeats(ci: ClipInstance, nd: MidiNoteData) -> void:
	var key := _make_note_key(ci, nd)
	var segs := _segments_for(ci)
	var nodes: Array = _repeats.get(key, [])
	while nodes.size() > maxi(segs.size() - 1, 0):
		var gone = nodes.pop_back()
		if gone:
			_free_visual(gone)
	for k in range(1, segs.size()):
		var span := NotePlacement.repeat_ticks(nd, segs[k])
		var vn: VisualNote = nodes[k - 1] if k - 1 < nodes.size() else null
		if vn == null and span.y > span.x:
			vn = visual_note_scene.instantiate()
			vn.clip_instance = ci
			vn.repeat_pass = k
			add_child(vn)
			vn.bind_to_note(nd)
			vn.set_color(note_color)
			if nodes.size() < k:
				nodes.resize(k)
			nodes[k - 1] = vn
		elif vn:
			vn._update_visual()
		if vn:
			_update_single_note_position(vn)
	if nodes.is_empty():
		_repeats.erase(key)
	else:
		_repeats[key] = nodes


## The repeat visuals of `nd` on `ci`, shown or hidden.
func _repeats_of(ci: ClipInstance, nd: MidiNoteData) -> Array[VisualNote]:
	var out: Array[VisualNote] = []
	for vn in _repeats.get(_make_note_key(ci, nd), []):
		if vn:
			out.append(vn)
	return out


func _free_repeats(ci: ClipInstance, nd: MidiNoteData) -> void:
	for vn in _repeats_of(ci, nd):
		_free_visual(vn)
	_repeats.erase(_make_note_key(ci, nd))


## Take a note visual out of the editor for good. NoteEditor also drops it from the selection.
func _free_visual(vn: VisualNote) -> void:
	_forget_visual(vn)
	if vn.get_parent() == self:
		remove_child(vn)
	vn.queue_free()


## Hook: `vn` is about to be freed.
func _forget_visual(_vn: VisualNote) -> void:
	pass


## Bring every visual of `nd` (from `source_clip`) up to date with its data: colour, place and,
## in track mode, which loop passes it shows in. Used mid-gesture, before the clip is told.
func refresh_note(nd: MidiNoteData, source_clip: Clip) -> void:
	if not multi_clip_mode:
		var vn := visual_for(clip_instance, nd)
		if vn:
			vn._update_visual()
			_update_single_note_position(vn)
		return
	for ci in _instances_of_clip(source_clip):
		var vn := visual_for(ci, nd)
		if vn:
			vn._update_visual()
			_update_single_note_position(vn)
		_sync_repeats(ci, nd)


## The shown visual of `nd` on `ci` that plays at `song_tick`: the note or one of its loop
## repeats. Falls back to the note's own visual.
func visual_at_song_tick(ci: ClipInstance, nd: MidiNoteData, song_tick: int) -> VisualNote:
	var own := visual_for(ci, nd)
	var candidates: Array[VisualNote] = []
	if own:
		candidates.append(own)
	if multi_clip_mode:
		candidates.append_array(_repeats_of(ci, nd))
	for vn in candidates:
		if not vn.visible:
			continue
		var pos := get_note_song_position(vn)
		if song_tick >= pos.start_tick and song_tick < pos.end_tick:
			return vn
	return own


func unbind():
	# Disconnect from clip signals (single-clip mode)
	if clip:
		_disconnect_clip_signals(clip)

	# Disconnect from all clips (multi-clip mode)
	for ci in clip_instances:
		if ci and ci.clip:
			_disconnect_clip_signals(ci.clip)
		if ci and ci.instance_modified.is_connected(_on_instance_modified):
			ci.instance_modified.disconnect(_on_instance_modified)

	# Keep grid_helper connected. Unbind only clears clip data; zoom/scroll
	# still need to relayout this editor when it is reused (the scene editor).

	# Clear all visual notes. They leave the tree now (not at the end of the frame), so a
	# rebind in the same frame never finds the old ones.
	for node in get_children():
		remove_child(node)
		node.queue_free()

	visual_notes_by_id.clear()
	_visuals_by_note_id.clear()
	_repeats.clear()
	_loop_segments.clear()
	clip_instance = null
	clip_instances.clear()
	track = null
	multi_clip_mode = false


func bind(ci : ClipInstance):
	"""Bind to single clip instance (clip-mode)."""
	logger.info("bind called (single-clip mode)")
	logger.info("  - clip_instance: ", ci)
	logger.info("  - clip_id: ", ci.clip_id if ci else "null")

	if clip_instance != ci:
		if clip_instance or multi_clip_mode:
			unbind()

		multi_clip_mode = false
		clip_instance = ci

		# Connect to clip signals for reactive updates
		if clip:
			_connect_clip_signals(clip)

		_load_clip_notes()
		queue_sort()
		update_container_width()


func bind_to_clips(instances: Array[ClipInstance], owner_track: Track):
	"""Bind to multiple clip instances (track-mode)."""
	logger.info("bind_to_clips called (multi-clip mode)")
	logger.info("  - %d clip instances on track: %s" % [instances.size(), owner_track.name if owner_track else "null"])
	
	if clip_instances.size() == instances.size() and track == owner_track:
		# already bound?
		var bound = true
		for i in range(clip_instances.size()):
			if instances[i] != clip_instances[i]:
				bound = false

		if bound:
			logger.info("  - clip instances already bound!")
			return
	
	# Unbind previous state
	if clip_instance or multi_clip_mode:
		unbind()

	multi_clip_mode = true
	clip_instances = instances.duplicate()  # Duplicate to avoid modifying the track's array
	track = owner_track

	# Connect to all clips' signals for reactive updates
	for ci in clip_instances:
		if ci and ci.clip:
			_connect_clip_signals(ci.clip)
		_watch_instance(ci)

	_load_clip_notes()
	queue_sort()
	update_container_width()


# ============================================================================
# Visual Note Placement
# ============================================================================
func _get_minimum_size() -> Vector2:
	# 128 chromatic lanes in the piano roll, one per visible row in Drum View.
	return Vector2(0, layout.total_height())


func _notification(what):
	if what == NOTIFICATION_SORT_CHILDREN and _positions_dirty:
		_update_note_positions()


func _update_note_positions() -> void:
	"""Update positions of all note instances based on current zoom and scroll."""
	if not grid_helper:
		return

	_positions_dirty = false
	for i in get_child_count():
		var note := get_child(i) as VisualNote
		if note and note.midi_note_data:
			_update_single_note_position(note)


## Every shown visual note in this editor, in child order (clip mode: the clip's notes;
## track mode: the notes the track's instances actually play, loop repeats included).
func get_all_visual_notes() -> Array[VisualNote]:
	var notes: Array[VisualNote] = []
	for child in get_children():
		if child is VisualNote and child.midi_note_data and child.visible and not child.is_pending:
			notes.append(child)
	return notes


## Test hook: how many times _update_single_note_position ran (tests check that
## scrolling leaves notes alone).
var reposition_calls: int = 0


func _update_single_note_position(note: VisualNote) -> void:
	"""Update the position and size of a single visual note."""
	reposition_calls += 1
	if not note.midi_note_data:
		return

	var note_data = note.midi_note_data
	if note.repeat_pass > 0:
		_update_repeat_position(note)
		return

	# Calculate position offset based on mode
	var offset_ticks = 0
	if multi_clip_mode:
		# MULTI-CLIP MODE: place the note where its instance plays it, and hide the
		# trimmed-away content outside the instance window, as the arranger does.
		var ci: ClipInstance = note.clip_instance
		if ci:
			offset_ticks = ci.content_origin_ticks()
			if not ci.plays_clip_span(note_data.start_tick, note_data.start_tick + note_data.duration_ticks):
				note.visible = false
				return
	else:
		# SINGLE-CLIP MODE: Use position_offset_ticks (usually 0 in clip-mode)
		offset_ticks = position_offset_ticks

	# Pitches with no row are hidden. Drum View's row set always covers every used
	# pitch (REQ-016), so this only ever hides notes mid-rebuild.
	if layout.row_of_pitch(note_data.note) < 0:
		note.visible = false
		return
	note.visible = true

	var rect := NotePlacement.note_rect(note_data, offset_ticks, layout, grid_helper)
	note.set_drum_mode(layout.is_folded())
	note.position = rect.position
	note.size = rect.size
	note.update_label_visibility(layout.row_height)


## Place a loop repeat in its pass, cut off at the loop wrap; hidden when the note does not
## play in that pass (any more).
func _update_repeat_position(note: VisualNote) -> void:
	var ci: ClipInstance = note.clip_instance
	var segs := _segments_for(ci) if ci else ([] as Array[Vector3i])
	var rect := Rect2()
	if note.repeat_pass < segs.size():
		rect = NotePlacement.repeat_rect(note.midi_note_data, ci, segs[note.repeat_pass], layout, grid_helper)
	if not rect.has_area():
		note.visible = false
		return
	note.visible = true
	note.set_drum_mode(layout.is_folded())
	note.position = rect.position
	note.size = rect.size
	note.update_label_visibility(layout.row_height)


func get_note_song_position(note: VisualNote) -> Dictionary:
	"""Get the song-relative position for a note (accounts for clip offset in track-mode).
	
	Returns a dictionary with 'start_tick' and 'end_tick' keys.
	This is used by NoteSelectionManager to work in the correct coordinate space.
	"""
	if not note or not note.midi_note_data:
		return {"start_tick": 0, "end_tick": 0}
	
	var note_data = note.midi_note_data
	var offset_ticks = 0

	if note.repeat_pass > 0 and note.clip_instance:
		# A loop repeat: where that pass plays it, ending at the loop wrap.
		var ci: ClipInstance = note.clip_instance
		var segs := _segments_for(ci)
		if note.repeat_pass < segs.size():
			var span := NotePlacement.repeat_ticks(note_data, segs[note.repeat_pass])
			if span.y > span.x:
				return {"start_tick": ci.start_ticks + span.x, "end_tick": ci.start_ticks + span.y}

	if multi_clip_mode:
		# MULTI-CLIP MODE: song position is where the note's instance plays it
		var ci: ClipInstance = note.clip_instance
		if ci:
			offset_ticks = ci.content_origin_ticks()
	else:
		# SINGLE-CLIP MODE: Use position_offset_ticks (0 in clip-mode, set in track-mode)
		offset_ticks = position_offset_ticks
	
	return {
		"start_tick": note_data.start_tick + offset_ticks,
		"end_tick": note_data.start_tick + note_data.duration_ticks + offset_ticks
	}


## Ask the owner to recompute the content width. Cheap: MidiEditor batches these into one
## width update per frame for all its editors.
func update_container_width() -> void:
	content_extent_changed.emit()


## Rightmost tick this editor's content reaches, in its own ticks. Track mode: the end of
## the last instance on the track. Clip mode: the last note end plus position_offset_ticks.
func content_end_ticks() -> int:
	var rightmost_tick := 0
	if multi_clip_mode:
		for ci in clip_instances:
			if ci:
				rightmost_tick = maxi(rightmost_tick, ci.get_end_ticks())
	elif clip:
		for nd in clip.midi_notes:
			rightmost_tick = maxi(rightmost_tick, nd.start_tick + nd.duration_ticks + position_offset_ticks)
	return rightmost_tick


func _load_clip_notes() -> void:
	logger.info("_load_clip_notes called")

	visual_notes_by_id.clear()
	_visuals_by_note_id.clear()

	if multi_clip_mode:
		# MULTI-CLIP MODE: Load notes from all clip instances
		_load_notes_from_multiple_clips()
	else:
		# SINGLE-CLIP MODE: Load notes from single clip
		_load_notes_from_single_clip()

	# Update all note positions
	_update_note_positions()
	update_container_width()


func _load_notes_from_single_clip() -> void:
	"""Load notes from single clip instance (clip-mode)."""
	if not clip:
		logger.error("No clip to load!")
		return

	for note_data in clip.midi_notes:
		# Create visual note instance
		var note_instance = visual_note_scene.instantiate()
		add_child(note_instance)
		note_instance.bind_to_note(note_data)

		# Set color from track
		note_instance.set_color(note_color)

		visual_notes_by_id[_make_note_key(clip_instance, note_data)] = note_instance

	logger.info("Loaded %d notes from clip '%s'" % [clip.midi_notes.size(), clip.name])


func _load_notes_from_multiple_clips() -> void:
	"""Load notes from multiple clip instances (track-mode)."""
	if clip_instances.is_empty():
		logger.warn("No clip instances to load!")
		return

	var total_notes = 0

	for ci in clip_instances:
		if not ci or not ci.clip:
			continue

		# Debug per-clip summary
		var clip_note_count = ci.clip.midi_notes.size()
		logger.info("  - clip instance id=%s start=%d end=%d notes=%d" % [str(ci.id), ci.start_ticks, ci.get_end_ticks(), clip_note_count])

		for note_data in ci.clip.midi_notes:
			# Create visual note instance
			var note_instance = visual_note_scene.instantiate()
			add_child(note_instance)
			# Attach clip instance to the visual note for positioning and lookups
			# (before binding, so its first visual update already knows it)
			note_instance.clip_instance = ci
			note_instance.bind_to_note(note_data)
			_index_visual(note_instance)

			# Set color from track
			note_instance.set_color(note_color)

			# Track in dictionary (multi-clip mode: {visual_note, clip_instance})
			visual_notes_by_id[_make_note_key(ci, note_data)] = {
				"visual_note": note_instance,
				"clip_instance": ci
			}
			_sync_repeats(ci, note_data)

			total_notes += 1
	
	logger.info("Loaded %d notes from %d clip instances on track '%s'" % [total_notes, clip_instances.size(), track.name if track else "null"])


# ============================================================================
# REACTIVE SIGNAL HANDLERS - Clip data changes
# ============================================================================
func _on_clip_note_added(note_data: MidiNoteData, source_clip: Clip) -> void:
	"""Handle when a note is added to the clip (reactive)."""
	if multi_clip_mode:
		# Create a visual note for each instance OF THE CLIP THAT GAINED THE NOTE.
		# Other clips on this track must not get one: their visuals would claim
		# ownership of the note and later edits would be routed to the wrong clip.
		for ci in _instances_of_clip(source_clip):
			# Avoid duplicates
			var key = _make_note_key(ci, note_data)
			if visual_notes_by_id.has(key):
				continue
			var vn = visual_note_scene.instantiate()
			add_child(vn)
			vn.clip_instance = ci
			vn.bind_to_note(note_data)
			vn.set_color(note_color)
			_index_visual(vn)
			visual_notes_by_id[key] = {
				"visual_note": vn,
				"clip_instance": ci
			}
			_update_single_note_position(vn)
			_sync_repeats(ci, note_data)
	else:
		# Single-clip mode
		var single_key = _note_dict_key(clip_instance, note_data.id)
		if visual_notes_by_id.has(single_key):
			push_warning("[NoteContainer] Note %d already has a visual representation" % note_data.id)
			return
		var vn_single = visual_note_scene.instantiate()
		add_child(vn_single)
		vn_single.bind_to_note(note_data)
		vn_single.set_color(note_color)
		visual_notes_by_id[single_key] = vn_single
		_update_single_note_position(vn_single)

	update_container_width()
	logger.info("Reactively added visual note %d" % note_data.id)
	notes_changed.emit()


func _on_clip_note_removed(note_data: MidiNoteData, source_clip: Clip) -> void:
	"""Handle when a note is removed from the clip (reactive)."""
	if multi_clip_mode:
		# Remove the visuals on every instance of the emitting clip, and only those.
		for vn in _visuals_of(note_data, source_clip):
			visual_notes_by_id.erase(_make_note_key(vn.clip_instance, note_data))
			_unindex_visual(vn, note_data.id)
			vn.queue_free()
		for ci in _instances_of_clip(source_clip):
			_free_repeats(ci, note_data)
	else:
		var single_key = _note_dict_key(clip_instance, note_data.id)
		if not visual_notes_by_id.has(single_key):
			push_warning("[NoteContainer] Cannot remove visual note %d - not found" % note_data.id)
			return
		var vn_single: VisualNote = visual_notes_by_id[single_key]
		visual_notes_by_id.erase(single_key)
		if vn_single:
			vn_single.queue_free()
	update_container_width()

	logger.info("Reactively removed visual note %d" % note_data.id)
	notes_changed.emit()


func _on_clip_note_changed(note_data: MidiNoteData, source_clip: Clip) -> void:
	"""Handle when a note is modified in the clip (reactive)."""
	if not multi_clip_mode and not visual_notes_by_id.has(_note_dict_key(clip_instance, note_data.id)):
		push_warning("[NoteContainer] Cannot update visual note %d - not found" % note_data.id)
		return
	# Track mode: every instance of the emitting clip, and only those, with their loop repeats.
	refresh_note(note_data, source_clip)
	update_container_width()

	logger.info("Reactively updated visual note %d" % note_data.id)
	notes_changed.emit()


## Pitches (-> velocity) of the shown notes sounding at `tick`, in this editor's ticks
## (clip-content in clip mode, song in track mode). With `only_played`, clip mode also
## requires the tick to fall inside the bound instance's played window, so this matches
## what playback actually sounds.
func pitches_sounding_at(tick: int, only_played: bool = true) -> Dictionary:
	var out := {}
	if only_played and not multi_clip_mode and clip_instance:
		if not clip_instance.plays_content_tick(tick):
			return out
	for child in get_children():
		if not (child is VisualNote and child.visible and child.midi_note_data) or child.is_pending:
			continue
		var nd: MidiNoteData = child.midi_note_data
		var pos := get_note_song_position(child)
		if tick >= pos.start_tick and tick < pos.end_tick:
			out[nd.note] = maxi(out.get(nd.note, 0), nd.velocity)
	return out


# ============================================================================
# COORDINATE CONVERSION
# ============================================================================

func y_to_note(y: float) -> int:
	"""Convert Y pixel position to MIDI note number (the row's pitch in Drum View)."""
	return layout.y_to_pitch(y)


func note_to_y(note : int) -> float:
	return layout.pitch_to_y(note)


## Size of a Drum View hit marker; see NotePlacement.drum_marker_size.
func drum_marker_size(duration_ticks: int = 0) -> Vector2:
	return NotePlacement.drum_marker_size(layout, grid_helper, duration_ticks)


## Top Y of a note's *visual*, which in Drum View is the centred hit marker rather than
## the whole row. Drag code positions notes through this so markers don't
## jump to the row's top edge mid-drag.
func note_visual_y(pitch: int) -> float:
	return NotePlacement.visual_y(layout, pitch)


## Vertical delta between two Y positions, measured in rows and signed so that
## positive is upward (a higher pitch). In the piano roll this is the semitone
## delta; in Drum View it counts visible rows (REQ-020).
func y_delta_to_steps(from_y: float, to_y: float) -> int:
	return layout.y_to_row(from_y) - layout.y_to_row(to_y)


## Move a pitch by whole rows, saturating at the ends (REQ-020).
func step_note(note: int, steps: int) -> int:
	return layout.step_pitch(note, steps)


func ticks_to_pixels(ticks: int) -> float:
	"""Convert ticks to horizontal pixels using GridHelper."""
	return grid_helper.ticks_to_pixels(ticks)


func pixels_to_ticks(pixels: float) -> int:
	"""Convert horizontal pixels to ticks using GridHelper."""
	return grid_helper.pixels_to_ticks(pixels)


# ============================================================================
# HELPER METHODS
# ============================================================================
func get_snap_interval() -> int:
	"""Get the current snap interval from the grid helper."""
	if grid_helper:
		return grid_helper.get_snap_interval()
	return 960  # Default to quarter note


func _get_note_at_position(pos: Vector2) -> VisualNote:
	"""Find which note is at the given position (if any). Loop repeats are notes too."""
	# Iterate through children in reverse (top-most first), without copying the child list
	for i in range(get_child_count() - 1, -1, -1):
		var child := get_child(i) as VisualNote
		if child and child.visible and not child.is_pending and child.get_rect().has_point(pos):
			return child
	return null


func get_visual_note(note_id: int) -> VisualNote:
	"""Get visual note by id. In multi-clip mode, scan children for matching note_id."""
	if not multi_clip_mode:
		var keyed = visual_notes_by_id.get(_note_dict_key(clip_instance, note_id), null)
		if keyed is VisualNote:
			return keyed
		# Legacy integer keys from earlier in-progress code
		var legacy = visual_notes_by_id.get(note_id, null)
		if legacy is VisualNote:
			return legacy
		return null
	var list: Array = _visuals_by_note_id.get(note_id, [])
	return list[0] if not list.is_empty() else null


## The visual showing `note_data` through `ci` (track mode), or the note's only visual
## (clip mode). Null when there is none.
func visual_for(ci: ClipInstance, note_data: MidiNoteData) -> VisualNote:
	var entry = visual_notes_by_id.get(_make_note_key(ci, note_data))
	if entry is Dictionary:
		return entry.visual_note if is_instance_valid(entry.visual_note) else null
	return entry as VisualNote


func get_clip_instance_for_note(note_id: int) -> ClipInstance:
	"""Get the clip instance that owns this note (multi-clip mode)."""
	if not multi_clip_mode:
		return clip_instance
	var vn := get_visual_note(note_id)
	return vn.clip_instance if vn else null


func get_clip_at_position(tick: int) -> ClipInstance:
	"""Get the clip instance at the given tick position (multi-clip mode)."""
	if not multi_clip_mode:
		return clip_instance

	for ci in clip_instances:
		if ci and tick >= ci.start_ticks and tick < ci.get_end_ticks():
			return ci
	return null


func get_or_create_clip_at_position(tick: int, min_end_tick: int = -1) -> ClipInstance:
	"""Get clip at position, or create a new one if empty space (multi-clip mode).

	A new clip is at least four bars long, extended in whole bars to reach `min_end_tick`
	(a paste passes its span end) as far as the next clip allows.
	"""
	# First try to find existing clip
	var existing = get_clip_at_position(tick)
	if existing:
		return existing

	# No clip at position - create a new one
	if not multi_clip_mode or not track:
		logger.error("Cannot create clip: not in multi-clip mode or no track set")
		return null

	logger.info("Creating new clip at tick %d on track '%s'" % [tick, track.name])

	# Calculate clip boundaries (snap to bars for clean organization)
	var ticks_per_bar = grid_helper.get_ticks_per_bar() if grid_helper else 3840

	# Snap start position to bar boundary
	@warning_ignore("integer_division")
	var clip_start_ticks = int(tick / ticks_per_bar) * ticks_per_bar

	# Find previous and next clips on the track
	var prev_clip_end: int = -1
	var next_clip_start: int = -1
	
	for instance in track.clip_instances:
		var clip_end = instance.start_ticks + instance.duration_ticks
		
		# Check for previous clip
		if clip_end <= clip_start_ticks:
			if prev_clip_end == -1 or clip_end > prev_clip_end:
				prev_clip_end = clip_end
		
		# Check for next clip
		if instance.start_ticks > clip_start_ticks:
			if next_clip_start == -1 or instance.start_ticks < next_clip_start:
				next_clip_start = instance.start_ticks
	
	# Adjust start position if it overlaps with previous clip
	if prev_clip_end != -1 and clip_start_ticks < prev_clip_end:
		# Snap to bar after previous clip ends
		@warning_ignore("integer_division")
		clip_start_ticks = ((prev_clip_end + ticks_per_bar - 1) / ticks_per_bar) * ticks_per_bar
		logger.info("  - Adjusted start to %d to avoid previous clip" % clip_start_ticks)

	# Calculate clip length
	var default_length = ticks_per_bar * 4  # Default: 4 bars
	if min_end_tick > clip_start_ticks:
		@warning_ignore("integer_division")
		var bars_needed: int = (min_end_tick - clip_start_ticks + ticks_per_bar - 1) / ticks_per_bar
		default_length = maxi(default_length, bars_needed * ticks_per_bar)
	var clip_length_ticks: int
	
	if next_clip_start != -1:
		# Constrain to end before the next clip
		var max_length = next_clip_start - clip_start_ticks
		
		# Ensure there's actually space for a clip
		if max_length <= 0:
			logger.error("Cannot create clip: no space between existing clips at tick %d" % tick)
			return null
		
		clip_length_ticks = min(default_length, max_length)
		logger.info("  - Constrained length to %d ticks (next clip at %d)" % [clip_length_ticks, next_clip_start])
	else:
		# No next clip, use default length
		clip_length_ticks = default_length

	# Create clip in project (the track's own project first: no Editor in headless tests)
	var project: Project = track.get_project_ref()
	if not project and Sonara.editor:
		project = Sonara.editor.project
	if not project:
		logger.error("Cannot create clip: no project available")
		return null

	# Undoable, like creating a clip on the timeline
	var new_clip_instance := ClipActions.create_clip(
		project, track, clip_start_ticks, clip_length_ticks, "Clip %d" % project.clips.size()
	)
	if new_clip_instance == null:
		logger.error("Cannot create clip: track rejected the instance")
		return null
	var new_clip := new_clip_instance.clip

	logger.info("Created clip '%s' (instance: %s) at tick %d (length: %d)" % [new_clip.name, new_clip_instance.id, clip_start_ticks, clip_length_ticks])

	# Add the new clip instance to our tracking and connect signals
	# (no need to rebind everything, just add the new one)
	clip_instances.append(new_clip_instance)
	
	# Connect to new clip's signals for reactive updates
	if new_clip:
		_connect_clip_signals(new_clip)
	_watch_instance(new_clip_instance)
	
	# Refresh container width to account for new clip
	update_container_width()

	return new_clip_instance
