## Clip instances of one track, found or made by song tick. Static and node-free, so the note
## editor (for its own track) and the note gestures (for a note of any track, which must stay on
## its own track when dropped) share one set of rules.
class_name TrackClips extends RefCounted

static var logger := Log.make("TrackClips")


## The instance of `track` that plays song tick `tick`, or null.
static func clip_at(track: Track, tick: int) -> ClipInstance:
	for ci in track.clip_instances:
		if ci and tick >= ci.start_ticks and tick < ci.get_end_ticks():
			return ci
	return null


## The instance of `track` at `tick`, or a new one on empty space: at least four bars, starting
## on a bar line (after the previous clip if that overlaps) and extended in whole bars to reach
## `min_end_tick`, as far as the next clip allows. The new clip is created as an undoable step,
## like creating one on the timeline. Null when there is no room or no project.
static func get_or_create(track: Track, tick: int, ticks_per_bar: int, min_end_tick: int = -1) -> ClipInstance:
	var existing := clip_at(track, tick)
	if existing:
		return existing

	logger.info("Creating new clip at tick %d on track '%s'" % [tick, track.name])

	# Snap start position to bar boundary
	@warning_ignore("integer_division")
	var clip_start_ticks := int(tick / ticks_per_bar) * ticks_per_bar

	# Find previous and next clips on the track
	var prev_clip_end: int = -1
	var next_clip_start: int = -1
	for instance in track.clip_instances:
		var clip_end := instance.start_ticks + instance.duration_ticks
		if clip_end <= clip_start_ticks:
			if prev_clip_end == -1 or clip_end > prev_clip_end:
				prev_clip_end = clip_end
		if instance.start_ticks > clip_start_ticks:
			if next_clip_start == -1 or instance.start_ticks < next_clip_start:
				next_clip_start = instance.start_ticks

	# Adjust start position if it overlaps with previous clip
	if prev_clip_end != -1 and clip_start_ticks < prev_clip_end:
		@warning_ignore("integer_division")
		clip_start_ticks = ((prev_clip_end + ticks_per_bar - 1) / ticks_per_bar) * ticks_per_bar

	var default_length := ticks_per_bar * 4
	if min_end_tick > clip_start_ticks:
		@warning_ignore("integer_division")
		var bars_needed: int = (min_end_tick - clip_start_ticks + ticks_per_bar - 1) / ticks_per_bar
		default_length = maxi(default_length, bars_needed * ticks_per_bar)
	var clip_length_ticks: int
	if next_clip_start != -1:
		var max_length := next_clip_start - clip_start_ticks
		if max_length <= 0:
			logger.error("Cannot create clip: no space between existing clips at tick %d" % tick)
			return null
		clip_length_ticks = mini(default_length, max_length)
	else:
		clip_length_ticks = default_length

	# The track's own project first: there is no Editor in headless tests
	var project: Project = track.get_project_ref()
	if not project and Sonara.editor:
		project = Sonara.editor.project
	if not project:
		logger.error("Cannot create clip: no project available")
		return null

	var new_clip_instance := ClipActions.create_clip(project, track, clip_start_ticks, clip_length_ticks)
	if new_clip_instance == null:
		logger.error("Cannot create clip: track rejected the instance")
		return null
	logger.info("Created clip '%s' at tick %d (length: %d)" % [new_clip_instance.clip.name, clip_start_ticks, clip_length_ticks])
	return new_clip_instance
