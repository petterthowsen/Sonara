# ClipInstance.gd
# Represents a Clip placed on a Track at a specific position
# References a Clip (from Project's clip pool) but adds position and playback parameters
# Multiple ClipInstances can reference the same Clip

class_name ClipInstance extends RefCounted

# ============================================================================
# SIGNALS
# ============================================================================

signal position_changed(new_start_ticks: int)
signal duration_changed(new_duration_ticks: int)
signal loop_changed(enabled: bool)
signal reverse_changed(enabled: bool)
signal muted_changed(muted: bool)
signal instance_modified()  # Any change to instance properties
signal clip_changed(new_clip: Clip)  # Source clip retargeted (Make Unique)

# ============================================================================
# PROPERTIES
# ============================================================================

# Unique identification (GUID-style)
var id: String = ""  # Instance ID

# Clip reference
var clip_id: String = ""  # References a Clip in Project's clip pool
var clip: Clip = null  # Cached reference (set by Track when added)

# Track reference - ClipInstances ALWAYS belong to a track
var track: Track = null  # Parent track (set by Track when added)

# Timeline position
var start_ticks: int = 0  # Position on timeline
var duration_ticks: int = 3840  # How long this instance plays (can differ from clip length)

# Clip content offset (where in the clip's content does this instance start reading from)
var clip_offset: int = 0  # Offset in ticks into the clip's content (allows trimming from left edge)

# Playback parameters
var loop_enabled: bool = false  # Whether to loop the clip content (default: disabled)
var loop_start_ticks: int = 0  # Loop region start, in clip content ticks (same space as clip_offset)
var loop_length_ticks: int = 3840  # Length of loop region

# Audio only: play the source samples backwards (mirrored around the clip's centre).
var reverse_enabled: bool = false

# Instance-specific overrides (don't affect the source Clip)
var transpose: int = 0  # Semitones to transpose MIDI (for MIDI clips)
var gain_offset: float = 0.0  # dB adjustment for this instance
var muted: bool = false  # Mute this instance
var color_override: Color = Color.TRANSPARENT  # If not transparent, overrides clip color

# Processing
var fade_in_ticks: int = 0
var fade_out_ticks: int = 0

# ============================================================================
# LIFECYCLE
# ============================================================================

func _init(instance_id: String = "", ref_clip_id: String = ""):
	"""Initialize clip instance with unique ID and clip reference."""
	if instance_id.is_empty():
		id = _generate_uuid()
	else:
		id = instance_id

	clip_id = ref_clip_id


func _generate_uuid() -> String:
	"""Generate a simple UUID-like identifier."""
	var timestamp = Time.get_unix_time_from_system()
	var random_part = "%08x" % randi()
	return "inst_%d_%s" % [timestamp, random_part]


# ============================================================================
# POSITION AND PLAYBACK
# ============================================================================

## Point this instance at a different source clip and notify timeline UI.
func set_clip(new_clip: Clip) -> void:
	if new_clip == clip:
		return
	clip = new_clip
	clip_id = new_clip.id if new_clip else ""
	clip_changed.emit(clip)
	instance_modified.emit()


func set_position(ticks: int) -> void:
	"""Set the start position on the timeline."""
	if start_ticks != ticks:
		start_ticks = ticks

		# Sync to audio engine if we have track reference
		if track and track.is_engine_connected():
			AudioEngineOSC.send("/track/%d/instance/%s/set_position" % [track.id, id], [start_ticks, duration_ticks, clip_offset])

		position_changed.emit(start_ticks)
		instance_modified.emit()


func set_duration(ticks: int) -> void:
	"""Set the playback duration."""
	if duration_ticks != ticks:
		duration_ticks = max(1, ticks)  # Minimum 1 tick

		# Sync to audio engine if we have track reference
		if track and track.is_engine_connected():
			AudioEngineOSC.send("/track/%d/instance/%s/set_position" % [track.id, id], [start_ticks, duration_ticks, clip_offset])

		duration_changed.emit(duration_ticks)
		instance_modified.emit()


func set_clip_offset(offset: int) -> void:
	"""Set the clip content offset (where to start reading from clip)."""
	if clip_offset != offset:
		clip_offset = max(0, offset)  # Minimum 0 ticks

		# Sync to audio engine if we have track reference
		if track and track.is_engine_connected():
			AudioEngineOSC.send("/track/%d/instance/%s/set_position" % [track.id, id], [start_ticks, duration_ticks, clip_offset])

		instance_modified.emit()


func set_loop_enabled(enabled: bool) -> void:
	"""Enable/disable looping."""
	set_loop(enabled, loop_start_ticks, loop_length_ticks)


## Set the loop flag and region (content ticks, like `clip_offset`) and sync it to the engine.
func set_loop(enabled: bool, start_ticks_in_clip: int, length_ticks: int) -> void:
	start_ticks_in_clip = maxi(0, start_ticks_in_clip)
	length_ticks = maxi(1, length_ticks)
	if loop_enabled == enabled and loop_start_ticks == start_ticks_in_clip and loop_length_ticks == length_ticks:
		return
	var flag_changed := loop_enabled != enabled
	loop_enabled = enabled
	loop_start_ticks = start_ticks_in_clip
	loop_length_ticks = length_ticks
	if track and track.is_engine_connected():
		AudioEngineOSC.send("/track/%d/instance/%s/set_loop" % [track.id, id],
				[1 if loop_enabled else 0, loop_start_ticks, loop_length_ticks])
	if flag_changed:
		loop_changed.emit(loop_enabled)
	instance_modified.emit()


## Play the source samples backwards for this instance (audio clips only).
func set_reverse_enabled(enabled: bool) -> void:
	if reverse_enabled == enabled:
		return
	reverse_enabled = enabled
	if track and track.is_engine_connected():
		AudioEngineOSC.send("/track/%d/instance/%s/set_reverse" % [track.id, id],
				[1 if reverse_enabled else 0])
	reverse_changed.emit(reverse_enabled)
	instance_modified.emit()


## Silence this instance without removing it.
func set_muted(value: bool) -> void:
	if muted == value:
		return
	muted = value
	if track and track.is_engine_connected():
		AudioEngineOSC.send("/track/%d/instance/%s/set_mute" % [track.id, id], [1 if muted else 0])
	muted_changed.emit(muted)
	instance_modified.emit()


## Override the clip colour for this instance; `Color.TRANSPARENT` clears the override.
func set_color_override(new_color: Color) -> void:
	if color_override == new_color:
		return
	color_override = new_color
	instance_modified.emit()


## End of the source clip's content: its stored length, or the last note's end when that is later.
func content_end_ticks() -> int:
	if clip == null:
		return clip_offset + duration_ticks
	return maxi(clip.content_length_ticks, clip.get_content_length())


## Loop state as [enabled, start_ticks, length_ticks], for undo commands.
func get_loop_state() -> Array:
	return [loop_enabled, loop_start_ticks, loop_length_ticks]


## Loop region to use when looping is switched on: the content the clip shows now (from
## `clip_offset`, at most `duration_ticks`), limited to the clip's content length.
func default_loop_region() -> Vector2i:
	var content_end := content_end_ticks()
	var length := mini(duration_ticks, content_end - clip_offset)
	if length < 1:
		length = duration_ticks
	return Vector2i(clip_offset, length)


## Fold a content tick past the loop end back into the loop region (the engine does the same).
func wrap_content_tick(content_tick: int) -> int:
	if loop_enabled and loop_length_ticks > 0 and content_tick >= loop_start_ticks:
		return loop_start_ticks + (content_tick - loop_start_ticks) % loop_length_ticks
	return content_tick


## True when looping is on and content tick `content_tick` is inside the loop region.
func in_loop_region(content_tick: int) -> bool:
	return loop_enabled and loop_length_ticks > 0 \
			and content_tick >= loop_start_ticks and content_tick < loop_start_ticks + loop_length_ticks


## Fold any content tick into the loop region, from either side. A note in the loop that is
## moved past the loop end comes in again at the loop start, as it does in the next pass.
func fold_into_loop(content_tick: int) -> int:
	if not (loop_enabled and loop_length_ticks > 0):
		return content_tick
	return loop_start_ticks + posmod(content_tick - loop_start_ticks, loop_length_ticks)


## Split the instance into contiguous runs of content, in instance-local ticks. Each entry is
## Vector3i(local_start, local_end, content_start); a run ends where the loop wraps. Without a
## loop there is one run. Stops after `max_segments` so a tiny loop on a long clip stays cheap.
func get_loop_segments(max_segments: int = 512) -> Array[Vector3i]:
	var segments: Array[Vector3i] = []
	var t := 0
	var c := clip_offset
	var loop_end := loop_start_ticks + loop_length_ticks
	var looping := loop_enabled and loop_length_ticks > 0
	while t < duration_ticks and segments.size() < max_segments:
		if looping:
			c = wrap_content_tick(c)
		var run := duration_ticks - t
		if looping:
			run = mini(run, loop_end - c)
		run = maxi(1, run)
		segments.append(Vector3i(t, t + run, c))
		t += run
		c += run
	return segments


## Copy instance-specific playback overrides from `other` (not identity or position).
func copy_overrides_from(other: ClipInstance) -> void:
	if other == null:
		return
	clip_offset = other.clip_offset
	loop_enabled = other.loop_enabled
	loop_start_ticks = other.loop_start_ticks
	loop_length_ticks = other.loop_length_ticks
	reverse_enabled = other.reverse_enabled
	transpose = other.transpose
	gain_offset = other.gain_offset
	muted = other.muted
	fade_in_ticks = other.fade_in_ticks
	fade_out_ticks = other.fade_out_ticks
	color_override = other.color_override


func get_end_ticks() -> int:
	"""Get the end position on the timeline."""
	return start_ticks + duration_ticks


## Song tick where clip-content tick 0 would land. Content before clip_offset is
## trimmed away, so this can be before start_ticks (even negative).
func content_origin_ticks() -> int:
	return start_ticks - clip_offset


## Clip-content tick -> song tick for this instance.
func clip_to_song_ticks(clip_ticks: int) -> int:
	return clip_ticks + content_origin_ticks()


## Song tick -> clip-content tick for this instance.
func song_to_clip_ticks(song_ticks: int) -> int:
	return song_ticks - content_origin_ticks()


## Content range [start, end) of the first run: what the instance plays from its own start
## until the loop wraps (or all of it, without a loop). Notes are shown at their place in
## the song only for this run; later passes are repeats.
func first_run_range() -> Vector2i:
	if not (loop_enabled and loop_length_ticks > 0):
		return Vector2i(clip_offset, clip_offset + duration_ticks)
	var start := wrap_content_tick(clip_offset)
	var run := maxi(1, mini(duration_ticks, loop_start_ticks + loop_length_ticks - start))
	return Vector2i(start, start + run)


## True when a clip-content span [start, end) is at least partly inside the first run
## (see `first_run_range`), the part of the content this instance plays at its own position.
func plays_clip_span(start: int, end: int) -> bool:
	var run := first_run_range()
	return start < run.y and end > run.x


## True when playback reaches clip-content tick `content_tick` at some point in this
## instance: in the first run, or, once the loop has wrapped, in the loop region.
func plays_content_tick(content_tick: int) -> bool:
	var run := first_run_range()
	if content_tick >= run.x and content_tick < run.y:
		return true
	if not (loop_enabled and loop_length_ticks > 0):
		return false
	var wrapped_length := mini(duration_ticks - (run.y - run.x), loop_length_ticks)
	return content_tick >= loop_start_ticks and content_tick < loop_start_ticks + wrapped_length


## Clip-content tick the instance is at when the song is at `song_ticks`. Inside the
## instance a loop is folded into its region, so this is the tick playback actually reads.
func song_to_played_content_ticks(song_ticks: int) -> int:
	var content := song_to_clip_ticks(song_ticks)
	if song_ticks >= start_ticks and song_ticks < get_end_ticks():
		return wrap_content_tick(content)
	return content


func get_effective_color() -> Color:
	"""Get the color to display (override or clip's color)."""
	if color_override.a > 0.0:
		return color_override
	if clip:
		return clip.color
	return Color.WHITE


# ============================================================================
# SERIALIZATION
# ============================================================================

func to_json() -> Dictionary:
	return {
		"id": id,
		"clip_id": clip_id,
		"start_ticks": start_ticks,
		"duration_ticks": duration_ticks,
		"clip_offset": clip_offset,
		"loop_enabled": loop_enabled,
		"loop_start_ticks": loop_start_ticks,
		"loop_length_ticks": loop_length_ticks,
		"reverse_enabled": reverse_enabled,
		"transpose": transpose,
		"gain_offset": gain_offset,
		"muted": muted,
		"color_override": color_override.to_html() if color_override.a > 0.0 else "",
		"fade_in_ticks": fade_in_ticks,
		"fade_out_ticks": fade_out_ticks
	}


static func from_json(data: Dictionary) -> ClipInstance:
	var instance_id = data.get("id", "")
	var ref_clip_id = data.get("clip_id", "")
	var instance = ClipInstance.new(instance_id, ref_clip_id)

	instance.start_ticks = data.get("start_ticks", 0)
	instance.duration_ticks = data.get("duration_ticks", 3840)
	instance.clip_offset = data.get("clip_offset", 0)
	instance.loop_enabled = data.get("loop_enabled", false)
	instance.loop_start_ticks = data.get("loop_start_ticks", 0)
	instance.loop_length_ticks = data.get("loop_length_ticks", 3840)
	instance.reverse_enabled = data.get("reverse_enabled", false)
	instance.transpose = data.get("transpose", 0)
	instance.gain_offset = data.get("gain_offset", 0.0)
	instance.muted = data.get("muted", false)

	var color_str = data.get("color_override", "")
	if not color_str.is_empty():
		instance.color_override = Color.from_string(color_str, Color.TRANSPARENT)

	instance.fade_in_ticks = data.get("fade_in_ticks", 0)
	instance.fade_out_ticks = data.get("fade_out_ticks", 0)

	return instance
