## Draws the notes of every visible track except the active one, in one _draw() and with no
## node per note (the arranger's MidiclipRenderer does the same for clip contents).
##
## In track mode only one track is edited at a time. The others are context: drawn dimmed,
## clickable to switch to them, and erasable. None of that needs a node per note, so the node
## count depends on the active track alone, however many tracks are visible.
##
## Lives inside MidiEditor's h_scroll, behind the active NoteEditor, and is as large as it.
## MidiEditor tells it which part of that space is on screen (`view_rect`); only notes in
## that part are drawn or searched.
class_name ContextNotesLayer extends Control

## Something that sets how far right the content reaches changed (an instance moved).
signal content_extent_changed

## A note of one of the drawn tracks was added, removed or changed, so the set of pitches in
## use may have moved. MidiEditor listens to rebuild Drum View's rows (REQ-016).
signal notes_changed

const ALPHA_EDITABLE := 0.85
const ALPHA_VIEW_ONLY := 0.5
## Brightness range a velocity maps to; the same as VisualNote's.
const BRIGHTNESS_MIN := 0.2
const BRIGHTNESS_MAX := 0.8
## Start tick and note position share one int64 sort key: tick * stride + position.
const SORT_KEY_STRIDE := 1 << 24

var grid_helper: GridHelper = null:
	set(gh):
		if grid_helper == gh:
			return
		if grid_helper and grid_helper.scale_changed.is_connected(queue_redraw):
			grid_helper.scale_changed.disconnect(queue_redraw)
		grid_helper = gh
		if grid_helper:
			grid_helper.scale_changed.connect(queue_redraw)
		queue_redraw()

var layout: LaneLayout = LaneLayout.chromatic():
	set(l):
		if layout == l:
			return
		if layout and layout.changed.is_connected(_on_layout_changed):
			layout.changed.disconnect(_on_layout_changed)
		layout = l if l else LaneLayout.chromatic()
		layout.changed.connect(_on_layout_changed)
		_on_layout_changed()

## The part of this control that is on screen, in its own coordinates. Set every frame by
## MidiEditor; only a change redraws.
var view_rect := Rect2():
	set(r):
		if view_rect != r:
			view_rect = r
			queue_redraw()

## The tracks in list order, and which of them can be hit and erased.
var _tracks: Array[Track] = []
var _editable: Dictionary = {}  # Track -> true

## The track that is not drawn because a NoteEditor shows it (the active one).
var excluded_track: Track = null:
	set(t):
		if excluded_track != t:
			excluded_track = t
			queue_redraw()

## Clips whose note signals are connected.
var _watched_clips: Dictionary = {}  # Clip -> true

## Clip -> {notes: Array[MidiNoteData] sorted by start_tick, max_duration: int}.
var _index: Dictionary = {}
## Track colour -> PackedColorArray of the fill per velocity shade.
var _shades: Dictionary = {}

## Test hook: how many clip indexes were built.
var index_builds := 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.changed.connect(_on_layout_changed)


func _get_minimum_size() -> Vector2:
	return Vector2(0, layout.total_height())


func _on_layout_changed() -> void:
	update_minimum_size()
	queue_redraw()


## Know `tracks` (list order). `editable` is the subset whose notes `note_at` can hit.
func set_tracks(tracks: Array[Track], editable: Array[Track]) -> void:
	var same_tracks := tracks == _tracks
	if not same_tracks:
		_disconnect_all()
		_tracks = tracks.duplicate()
		for t in _tracks:
			_watch_track(t)
	_editable.clear()
	for t in editable:
		_editable[t] = true
	queue_redraw()


## Opacity of a track's notes: editable tracks slightly dimmed, view-only ones more.
func alpha_for(t: Track) -> float:
	return ALPHA_EDITABLE if _editable.has(t) else ALPHA_VIEW_ONLY


func track_count() -> int:
	return _tracks.size()


## Song tick the last instance on the drawn tracks ends at.
func content_end_ticks() -> int:
	var end_ticks := 0
	for t in _tracks:
		for ci in t.clip_instances:
			if ci:
				end_ticks = maxi(end_ticks, ci.get_end_ticks())
	return end_ticks


# ============================================================================
# CHANGE TRACKING
# ============================================================================

func _watch_track(t: Track) -> void:
	t.color_changed.connect(_on_track_color_changed)
	t.clip_instance_added.connect(_on_instance_added)
	t.clip_instance_removed.connect(_on_instance_removed)
	for ci in t.clip_instances:
		_watch_instance(ci)


func _watch_instance(ci: ClipInstance) -> void:
	if ci == null:
		return
	if not ci.instance_modified.is_connected(_on_instance_modified):
		ci.instance_modified.connect(_on_instance_modified)
	if ci.clip:
		_watch_clip(ci.clip)


func _disconnect_all() -> void:
	for t in _tracks:
		if not is_instance_valid(t):
			continue
		if t.color_changed.is_connected(_on_track_color_changed):
			t.color_changed.disconnect(_on_track_color_changed)
		if t.clip_instance_added.is_connected(_on_instance_added):
			t.clip_instance_added.disconnect(_on_instance_added)
		if t.clip_instance_removed.is_connected(_on_instance_removed):
			t.clip_instance_removed.disconnect(_on_instance_removed)
		for ci in t.clip_instances:
			if ci and ci.instance_modified.is_connected(_on_instance_modified):
				ci.instance_modified.disconnect(_on_instance_modified)
	for c in _watched_clips.keys():
		_unwatch_clip(c)
	_watched_clips.clear()
	_index.clear()
	_shades.clear()
	_tracks.clear()


func _exit_tree() -> void:
	_disconnect_all()


func _on_track_color_changed(_color: Color) -> void:
	_shades.clear()
	queue_redraw()


func _on_instance_modified() -> void:
	queue_redraw()
	content_extent_changed.emit()


func _on_instance_added(instance: ClipInstance) -> void:
	_watch_instance(instance)
	queue_redraw()
	content_extent_changed.emit()
	notes_changed.emit()


func _on_instance_removed(_instance: ClipInstance) -> void:
	queue_redraw()
	content_extent_changed.emit()
	notes_changed.emit()


func _watch_clip(c: Clip) -> void:
	if _watched_clips.has(c):
		return
	_watched_clips[c] = true
	# The bound Callable is what gets connected, so it is also what disconnect is given.
	var cb := _on_clip_notes_changed.bind(c)
	c.midi_note_added.connect(cb)
	c.midi_note_removed.connect(cb)
	c.midi_note_changed.connect(cb)


func _unwatch_clip(c: Clip) -> void:
	if not is_instance_valid(c):
		return
	var cb := _on_clip_notes_changed.bind(c)
	if c.midi_note_added.is_connected(cb):
		c.midi_note_added.disconnect(cb)
	if c.midi_note_removed.is_connected(cb):
		c.midi_note_removed.disconnect(cb)
	if c.midi_note_changed.is_connected(cb):
		c.midi_note_changed.disconnect(cb)


func _on_clip_notes_changed(_note: MidiNoteData, c: Clip) -> void:
	_index.erase(c)
	queue_redraw()
	notes_changed.emit()


# ============================================================================
# NOTE INDEX
# ============================================================================

## The clip's notes sorted by start tick, with its longest note. Built the first time the
## clip is on screen or searched, and dropped when its notes change.
func _index_of(c: Clip) -> Dictionary:
	var entry = _index.get(c)
	if entry != null:
		return entry
	index_builds += 1
	var notes: Array[MidiNoteData] = c.midi_notes.duplicate()
	var sorted := true
	var max_duration := 0
	var previous := -1
	var keys := PackedInt64Array()
	for i in notes.size():
		var nd := notes[i]
		if nd.start_tick < previous:
			sorted = false
		previous = nd.start_tick
		max_duration = maxi(max_duration, nd.duration_ticks)
		keys.append(nd.start_tick * SORT_KEY_STRIDE + i)
	if not sorted:
		# Sort packed keys (start tick, then position) natively; a script comparator
		# over every clip in the project would be slow.
		keys.sort()
		var ordered: Array[MidiNoteData] = []
		for key in keys:
			ordered.append(notes[posmod(key, SORT_KEY_STRIDE)])
		notes = ordered
	entry = {"notes": notes, "max_duration": max_duration}
	_index[c] = entry
	return entry


## Index of the first note starting at or after `tick` (notes.size() when none does).
static func _first_at_or_after(notes: Array[MidiNoteData], tick: int) -> int:
	var lo := 0
	var hi := notes.size()
	while lo < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi) / 2
		if notes[mid].start_tick < tick:
			lo = mid + 1
		else:
			hi = mid
	return lo


# ============================================================================
# DRAWING
# ============================================================================

## Fill colours for a track's notes, one per velocity shade, at the track's dimming.
func _fills_for(t: Track) -> PackedColorArray:
	var base := t.color
	var fills = _shades.get(base)
	if fills == null:
		fills = PackedColorArray()
		var display := Utils.display_color(base)
		for i in VisualNote.VELOCITY_SHADES:
			var normalized := float(i) / (VisualNote.VELOCITY_SHADES - 1)
			var brightness := lerpf(BRIGHTNESS_MIN, BRIGHTNESS_MAX, normalized)
			fills.append(Utils.display_color(Color.from_hsv(display.h, display.s, brightness)))
		_shades[base] = fills
	return fills


static func _shade_of(velocity: int) -> int:
	var normalized := (velocity - 1) / 126.0
	return clampi(roundi(normalized * (VisualNote.VELOCITY_SHADES - 1)), 0, VisualNote.VELOCITY_SHADES - 1)


func _draw() -> void:
	if grid_helper == null or _tracks.is_empty():
		return
	var first_tick := grid_helper.pixels_to_ticks(view_rect.position.x)
	var last_tick := grid_helper.pixels_to_ticks(view_rect.end.x)
	var top := view_rect.position.y - layout.row_height
	var bottom := view_rect.end.y
	for t in _tracks:
		if t == excluded_track:
			continue
		var fills := _fills_for(t)
		var alpha := alpha_for(t)
		for ci in t.clip_instances:
			if ci == null or ci.clip == null:
				continue
			# Instances outside the screen cost nothing, not even their index.
			if ci.get_end_ticks() < first_tick or ci.start_ticks > last_tick:
				continue
			_draw_instance(ci, fills, alpha, first_tick, last_tick, top, bottom)


func _draw_instance(ci: ClipInstance, fills: PackedColorArray, alpha: float,
		first_tick: int, last_tick: int, top: float, bottom: float) -> void:
	var entry := _index_of(ci.clip)
	var notes: Array[MidiNoteData] = entry.notes
	var origin := ci.content_origin_ticks()
	# A note starting before the screen can still reach into it, by at most the longest note.
	var i := _first_at_or_after(notes, first_tick - origin - int(entry.max_duration))
	var end_of_screen := last_tick - origin
	while i < notes.size():
		var nd := notes[i]
		i += 1
		if nd.start_tick > end_of_screen:
			break
		if not ci.plays_clip_span(nd.start_tick, nd.start_tick + nd.duration_ticks):
			continue
		var rect := NotePlacement.note_rect(nd, origin, layout, grid_helper)
		if not rect.has_area() or rect.end.y < top or rect.position.y > bottom:
			continue
		var color := fills[_shade_of(nd.velocity)]
		color.a = alpha
		draw_rect(rect, color)


# ============================================================================
# HIT-TESTING
# ============================================================================

## The note of an editable track under `local_pos` (this control's coordinates), as
## {track, instance, data}, or {}. Tracks are searched in list order, so of overlapping notes
## the earlier track wins, and within a track the one drawn last.
func note_at(local_pos: Vector2) -> Dictionary:
	if grid_helper == null or _editable.is_empty():
		return {}
	if local_pos.y < 0.0 or local_pos.y >= layout.total_height():
		return {}
	var pitch := layout.y_to_pitch(local_pos.y)
	if pitch < 0:
		return {}
	var tick := grid_helper.pixels_to_ticks(local_pos.x)
	for t in _tracks:
		if t == excluded_track or not _editable.has(t):
			continue
		var hit := _note_at_on_track(t, local_pos, tick, pitch)
		if not hit.is_empty():
			return hit
	return {}


func _note_at_on_track(t: Track, local_pos: Vector2, tick: int, pitch: int) -> Dictionary:
	var found := {}
	for ci in t.clip_instances:
		if ci == null or ci.clip == null:
			continue
		var entry := _index_of(ci.clip)
		var notes: Array[MidiNoteData] = entry.notes
		var origin := ci.content_origin_ticks()
		var clip_tick := tick - origin
		var i := _first_at_or_after(notes, clip_tick - int(entry.max_duration))
		while i < notes.size():
			var nd := notes[i]
			i += 1
			if nd.start_tick > clip_tick:
				break
			if nd.note != pitch or not ci.plays_clip_span(nd.start_tick, nd.start_tick + nd.duration_ticks):
				continue
			if NotePlacement.note_rect(nd, origin, layout, grid_helper).has_point(local_pos):
				found = {"track": t, "instance": ci, "data": nd}
	return found
