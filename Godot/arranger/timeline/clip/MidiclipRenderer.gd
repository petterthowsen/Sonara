# Draws either midi notes or audio waveform of a clip
class_name MidiclipRenderer extends Control

@export var note_color := Color("#eee")
@export var waveform_color := Color(0.3, 0.6, 0.9, 0.6)  # Semi-transparent blue
@export var waveform_bg_color := Color(0.1, 0.1, 0.1, 0.3)  # Subtle background
## Minimum vertical span in semitones so single-pitch loops still fill the clip.
@export var min_pitch_range: int = 12
## Extra semitones above/below when notes already span more than min_pitch_range.
@export var pitch_padding: int = 1

# LOD caching for zoom-aware rendering
var current_level: int = -1  # Track which LOD level we're currently using


func _ready() -> void:
	## Use nearest-neighbor filtering for crisp waveform textures
	texture_filter = TEXTURE_FILTER_NEAREST
	_connect_grid_helper()


func _exit_tree() -> void:
	_disconnect_grid_helper()


var _connected_grid_helper: GridHelper = null

func _connect_grid_helper() -> void:
	if not Sonara.editor or not Sonara.editor.arranger or not Sonara.editor.arranger.timeline:
		return
	var grid_helper: GridHelper = Sonara.editor.arranger.timeline.grid_helper
	if not grid_helper:
		return
	if _connected_grid_helper == grid_helper:
		return
	_disconnect_grid_helper()
	_connected_grid_helper = grid_helper
	_connected_grid_helper.changed.connect(_on_grid_helper_changed)


func _disconnect_grid_helper() -> void:
	if _connected_grid_helper and _connected_grid_helper.changed.is_connected(_on_grid_helper_changed):
		_connected_grid_helper.changed.disconnect(_on_grid_helper_changed)
	_connected_grid_helper = null


func _on_grid_helper_changed() -> void:
	## Zoom/scroll/tempo changed - recompute LOD selection and redraw.
	_update_lod_for_zoom()
	queue_redraw()

var clip_instance : ClipInstance:
	set(c):
		if clip_instance and clip_instance.clip:
			if clip_instance.clip.clip_modified.is_connected(_on_clip_modified):
				clip_instance.clip.clip_modified.disconnect(_on_clip_modified)
		clip_instance = c
		current_level = -1
		if clip_instance and clip_instance.clip:
			if not clip_instance.clip.clip_modified.is_connected(_on_clip_modified):
				clip_instance.clip.clip_modified.connect(_on_clip_modified)
		_update_lod_for_zoom()
		queue_redraw()


func _on_clip_modified():
	# TODO: for notes:
	# - We should check speifically for midi note changes.
	#
	# for audio, we should only redraw if audio waveform actually changes.
	# gain can simply scale the control - faster ;)
	queue_redraw()


func _update_lod_for_zoom() -> void:
	## Update current_level indicator when zoom/scroll/tempo changes (via GridHelper.changed).
	if not clip_instance or not clip_instance.clip:
		return

	var clip = clip_instance.clip
	if clip.type != Clip.ClipType.AUDIO or clip.audio_waveform == null:
		return

	if not _connected_grid_helper:
		return

	var pixels_per_beat = _connected_grid_helper.pixels_per_beat
	var ppq = _connected_grid_helper.ppq

	# Select which level we would use at current zoom
	var selected_waveform = clip.audio_waveform.get_ready_level_for_zoom(
		pixels_per_beat,
		ppq,
		clip_instance.duration_ticks,
		size.x
	)

	if selected_waveform:
		var new_level = clip.audio_waveform.levels.find(selected_waveform)
		if new_level != current_level:
			current_level = new_level


func _draw() -> void:
	if clip_instance and clip_instance.clip:
		if clip_instance.clip.type == Clip.ClipType.MIDI:
			_draw_midi()
		else:
			_draw_waveform()


## Draw MIDI notes in a window of at least one octave around their actual pitches.
func _draw_midi():
	var clip = clip_instance.clip
	if clip.midi_notes.is_empty() or size.y <= 0.0:
		return

	var display := _display_pitch_range(clip.find_lowest_note(), clip.find_highest_note())
	var lowest: int = display.x
	var highest: int = display.y
	var pitch_count := highest - lowest + 1
	var note_height := size.y / float(pitch_count)

	var clip_length_ticks = clip_instance.duration_ticks
	var clip_offset = clip_instance.clip_offset
	var visible_start = clip_offset
	var visible_end = clip_offset + clip_length_ticks

	for note: MidiNoteData in clip.midi_notes:
		var note_end = note.start_tick + note.duration_ticks
		if note_end <= visible_start or note.start_tick >= visible_end:
			continue

		var note_local_start = note.start_tick - clip_offset
		var note_local_end = note_end - clip_offset
		var draw_start = max(note_local_start, 0)
		var draw_end = min(note_local_end, clip_length_ticks)
		var draw_duration = draw_end - draw_start

		var x = remap(draw_start, 0, clip_length_ticks, 0, size.x)
		var w = remap(draw_duration, 0, clip_length_ticks, 0, size.x)
		var y = (highest - note.note) * note_height
		y = clampf(y, 0.0, size.y - note_height)

		draw_rect(Rect2(x, y, w, note_height), note_color, true, -1.0, true)


## Expand [lowest, highest] to at least one octave, centered, clamped to 0–127.
func _display_pitch_range(lowest: int, highest: int) -> Vector2i:
	var lo := mini(lowest, highest)
	var hi := maxi(lowest, highest)
	var span := hi - lo
	if span < min_pitch_range:
		var extra: int = min_pitch_range - span
		var down: int = int(extra / 2)
		lo -= down
		hi += extra - down
	else:
		lo -= pitch_padding
		hi += pitch_padding
	if lo < Midi.MIDI_MIN:
		hi = mini(Midi.MIDI_MAX, hi - lo)
		lo = Midi.MIDI_MIN
	if hi > Midi.MIDI_MAX:
		lo = maxi(Midi.MIDI_MIN, lo - (hi - Midi.MIDI_MAX))
		hi = Midi.MIDI_MAX
	return Vector2i(lo, hi) 


func _draw_waveform() -> void:
	"""Render audio waveform with multi-resolution LOD and stereo split.

	Visual design:
	- Left channel rendered in top half of clip
	- Right channel rendered in bottom half of clip (stereo split)
	- Mono audio rendered in top half
	- Filled polygon between min/max peaks
	- Progressive loading: placeholder text while waveform loads
	"""
	if not clip_instance or not clip_instance.clip:
		return

	var clip = clip_instance.clip

	# Ensure we have an audio waveform to render
	if clip.audio_waveform == null or clip.audio_waveform.levels.is_empty():
		_draw_loading_placeholder()
		return

	# Get grid helper for zoom information
	var timeline = Sonara.editor.arranger.timeline
	if not timeline:
		return

	var pixels_per_beat = timeline.grid_helper.pixels_per_beat
	var ppq = timeline.grid_helper.ppq

	# Validate essential inputs
	if size.x <= 0 or size.y <= 0:
		return
	if ppq <= 0:
		_draw_loading_placeholder()
		return

	# Select appropriate waveform level based on zoom
	# Use get_ready_level_for_zoom to ensure the waveform is fully loaded and ready
	var waveform: Waveform = clip.audio_waveform.get_ready_level_for_zoom(
		pixels_per_beat,
		ppq,
		clip_instance.duration_ticks,
		size.x
	)

	if waveform == null:
		_draw_loading_placeholder()
		return

	# Draw background for waveform area
	draw_rect(Rect2(0, 0, size.x, size.y), waveform_bg_color, true)

	# Calculate channel heights (stereo split: top and bottom)
	var channel_height = size.y / 2.0 if waveform.channels > 1 else size.y

	# Validate channel height
	if channel_height <= 0:
		return

	var center_y_left = channel_height / 2.0
	var center_y_right = size.y - channel_height / 2.0 if waveform.channels > 1 else center_y_left

	# Calculate the sample range of this clip within the waveform
	# clip_offset: how many ticks are trimmed from the start of the audio
	# duration_ticks: how many ticks of the trimmed audio are used in the clip
	#
	# IMPORTANT: Use recorded_bpm, not project tempo!
	# The waveform cache is generated from the ORIGINAL audio samples.
	# clip_offset/duration_ticks are in project timeline ticks, so we need to know:
	# "at this clip's recorded_bpm, how many audio samples do these ticks represent?"
	var sample_rate = float(clip.audio_sample_rate)
	var recorded_bpm = clip.recorded_bpm

	# Convert ticks to samples in the original audio:
	# ticks -> beats -> seconds -> samples
	# samples = ticks / ppq * (60.0 / recorded_bpm) * sample_rate
	var samples_per_tick = sample_rate * 60.0 / (recorded_bpm * float(ppq)) if ppq > 0 and recorded_bpm > 0 else 0.0

	var waveform_start_sample = int(clip_instance.clip_offset * samples_per_tick)
	var waveform_end_sample = waveform_start_sample + int(clip_instance.duration_ticks * samples_per_tick)

	# Draw using pre-rendered chunked textures for performance
	# Calculate which portion of the waveform to draw (based on clip_offset and duration)
	var start_block = int(waveform_start_sample / waveform.resolution)
	var end_block = int(waveform_end_sample / waveform.resolution)

	# Clamp to valid block range
	start_block = clamp(start_block, 0, waveform.num_blocks - 1)
	end_block = clamp(end_block, start_block, waveform.num_blocks - 1)

	# Draw left channel (top half)
	if not waveform.texture_chunks_left.is_empty():
		_draw_chunked_waveform(
			waveform.texture_chunks_left,
			start_block,
			end_block,
			Rect2(0, 0, size.x, channel_height),
			waveform.TEXTURE_HEIGHT,
			waveform.TEXTURE_CHUNK_WIDTH
		)

	# Draw right channel (bottom half) if stereo
	if waveform.channels > 1 and not waveform.texture_chunks_right.is_empty():
		_draw_chunked_waveform(
			waveform.texture_chunks_right,
			start_block,
			end_block,
			Rect2(0, channel_height, size.x, channel_height),
			waveform.TEXTURE_HEIGHT,
			waveform.TEXTURE_CHUNK_WIDTH
		)


func _draw_chunked_waveform(chunks: Array[ImageTexture], start_block: int, end_block: int, dest_rect: Rect2, texture_height: int, chunk_width: int) -> void:
	"""Draw a waveform from chunked textures.

	Args:
		chunks: Array of texture chunks (each chunk_width pixels wide)
		start_block: First block to draw (in waveform block coordinates)
		end_block: Last block to draw (in waveform block coordinates)
		dest_rect: Destination rectangle on screen
		texture_height: Height of each texture chunk
		chunk_width: Width of each texture chunk (except possibly the last one)
	"""
	if chunks.is_empty() or dest_rect.size.x <= 0:
		return

	# Calculate which chunks contain the visible blocks
	var start_chunk_idx := int(start_block / chunk_width)
	var end_chunk_idx := int(end_block / chunk_width)

	# Clamp to valid chunk range
	start_chunk_idx = clamp(start_chunk_idx, 0, chunks.size() - 1)
	end_chunk_idx = clamp(end_chunk_idx, start_chunk_idx, chunks.size() - 1)

	# Total visible blocks
	var total_visible_blocks = end_block - start_block + 1

	# Draw each relevant chunk
	for chunk_idx in range(start_chunk_idx, end_chunk_idx + 1):
		var chunk_texture = chunks[chunk_idx]
		if not chunk_texture:
			continue

		# Calculate block range for this chunk
		var chunk_block_start = chunk_idx * chunk_width
		var chunk_block_end = chunk_block_start + chunk_width - 1

		# Calculate visible portion within this chunk
		var visible_chunk_start = maxi(start_block, chunk_block_start)
		var visible_chunk_end = mini(end_block, chunk_block_end)

		# Convert to chunk-local coordinates
		var src_x = visible_chunk_start - chunk_block_start
		var src_width = visible_chunk_end - visible_chunk_start + 1

		# Calculate destination X coordinate (proportional position in dest_rect)
		var visible_block_offset = visible_chunk_start - start_block
		var dest_x = dest_rect.position.x + (dest_rect.size.x * float(visible_block_offset) / float(total_visible_blocks))
		var dest_width = dest_rect.size.x * float(src_width) / float(total_visible_blocks)

		# Source and destination rects
		var src_rect = Rect2(src_x, 0, src_width, texture_height)
		var chunk_dest_rect = Rect2(dest_x, dest_rect.position.y, dest_width, dest_rect.size.y)

		# Draw this chunk
		draw_texture_rect_region(chunk_texture, chunk_dest_rect, src_rect, Color.WHITE, false, true)




func _draw_loading_placeholder() -> void:
	"""Draw placeholder text while waveform is loading."""
	draw_rect(Rect2(0, 0, size.x, size.y), waveform_bg_color, true)

	var text = "Loading waveform..."
	var font = get_theme_default_font()
	var font_size = get_theme_default_font_size()

	var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(font, Vector2(4, size.y / 2), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.GRAY)
