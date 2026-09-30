## Where a note sits in the editor, in the coordinates of the note area (pixels).
##
## One place for the placement rules, used by NoteContainer (which positions a VisualNote
## node) and ContextNotesLayer (which draws the same notes as plain rects), so the two
## can't drift apart.
class_name NotePlacement extends RefCounted


## The rect of a note whose clip-content start is `nd.start_tick`, shown through an instance
## whose content origin is `offset_ticks` (song ticks). A rect without area means the note is
## not drawn: its pitch has no row (Drum View shows only the rows in use).
##
## Piano roll: a bar spanning the note's duration, one row tall. Drum View: a hit marker at
## the note's start, centred in the row; the stored duration is untouched (REQ-022).
static func note_rect(nd: MidiNoteData, offset_ticks: int, layout: LaneLayout, gh: GridHelper) -> Rect2:
	if layout.row_of_pitch(nd.note) < 0:
		return Rect2()
	var x := gh.ticks_to_pixels(nd.start_tick + offset_ticks)
	if layout.is_folded():
		return Rect2(Vector2(x, visual_y(layout, nd.note)), drum_marker_size(layout, gh, nd.duration_ticks))
	var width := gh.ticks_to_pixels(nd.duration_ticks)
	return Rect2(x, layout.pitch_to_y(nd.note), maxf(1.0, width), layout.row_height)


## Where `nd` plays in one later pass of a looped instance, as instance-local [start, end).
## `seg` is that pass from ClipInstance.get_loop_segments (instance-local start and end, content
## start). Like the engine, a pass only starts the notes that begin inside it and ends them at
## the loop wrap. Vector2i.ZERO when the note does not start in this pass.
static func repeat_ticks(nd: MidiNoteData, seg: Vector3i) -> Vector2i:
	var content_start := seg.z
	var content_end := content_start + (seg.y - seg.x)
	if nd.start_tick < content_start or nd.start_tick >= content_end:
		return Vector2i.ZERO
	var note_end := mini(nd.start_tick + nd.duration_ticks, content_end)
	return Vector2i(seg.x + nd.start_tick - content_start, seg.x + note_end - content_start)


## Where `nd` is drawn in one later pass of a looped instance (see repeat_ticks): cut off where
## the pass ends. Empty when the note does not play in this pass or its pitch has no row.
static func repeat_rect(nd: MidiNoteData, ci: ClipInstance, seg: Vector3i, layout: LaneLayout, gh: GridHelper) -> Rect2:
	var span := repeat_ticks(nd, seg)
	if span.y <= span.x:
		return Rect2()
	var rect := note_rect(nd, 0, layout, gh)
	if not rect.has_area():
		return rect
	rect.position.x = gh.ticks_to_pixels(ci.start_ticks + span.x)
	if not layout.is_folded():
		rect.size.x = maxf(gh.ticks_to_pixels(ci.start_ticks + span.y) - rect.position.x, 1.0)
	return rect


## Size of a Drum View hit marker: a fixed width that fills the row vertically.
## The width is deliberately independent of the row height, so zooming vertically
## only makes the markers taller. It is still capped so a marker is never wider
## than one grid step, nor wider than the note itself.
##
## `duration_ticks` is the note's own length. Notes on one pitch never overlap in
## the data, so clamping to that length is what actually guarantees the markers
## don't overlap on screen: the grid step alone is wrong whenever notes are
## shorter than the current snap, and the old 3 px floor overlapped once a step
## shrank below it at low zoom. Pass 0 for the generic marker size with no note in hand.
static func drum_marker_size(layout: LaneLayout, gh: GridHelper, duration_ticks: int = 0) -> Vector2:
	var h := VisualNote.drum_marker_height(layout.row_height)
	var w := VisualNote.DRUM_MARKER_WIDTH
	var step_px := gh.ticks_to_pixels(gh.get_snap_interval())
	if step_px > 0.0:
		w = minf(w, step_px - 1.0)
	if duration_ticks > 0:
		w = minf(w, gh.ticks_to_pixels(duration_ticks) - 1.0)
	return Vector2(maxf(1.0, w), h)


## Top Y of a note's *visual*, which in Drum View is the centred hit marker rather than the
## whole row.
static func visual_y(layout: LaneLayout, pitch: int) -> float:
	var y := layout.pitch_to_y(pitch)
	if layout.is_folded():
		y += (layout.row_height - VisualNote.drum_marker_height(layout.row_height)) * 0.5
	return y
