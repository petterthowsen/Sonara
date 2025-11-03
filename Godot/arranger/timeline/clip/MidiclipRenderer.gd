# Draws either midi notes or audio waveform of a clip
class_name MidiclipRenderer extends Control

@export var note_color := Color("#eee")
@export var waveform_color := Color(0.3, 0.6, 0.9, 0.6)  # Semi-transparent blue
@export var waveform_bg_color := Color(0.1, 0.1, 0.1, 0.3)  # Subtle background

# LOD caching for zoom-aware rendering
var _last_pixels_per_beat: float = -1.0
var _last_selected_waveform: Waveform = null
var _last_selected_lod_level: int = -1
var current_level: int = -1  # Track which LOD level we're currently using


func _ready() -> void:
	## Use nearest-neighbor filtering for crisp waveform textures
	texture_filter = TEXTURE_FILTER_NEAREST

# Debouncing for LOD level changes
var _pending_level: int = -1  # Target level we want to switch to
var _debounce_time: float = 0.0  # Accumulated time at current pending level
const LOD_DEBOUNCE_DELAY: float = 0.15  # Wait 150ms before switching LOD level

var clip_instance : ClipInstance:
	set(c):
		if clip_instance and clip_instance.clip:
			if clip_instance.clip.clip_modified.is_connected(_on_clip_modified):
				clip_instance.clip.clip_modified.disconnect(_on_clip_modified)
		clip_instance = c
		# Reset debounce state when clip changes
		_pending_level = -1
		_debounce_time = 0.0
		current_level = -1
		if clip_instance and clip_instance.clip:
			if not clip_instance.clip.clip_modified.is_connected(_on_clip_modified):
				clip_instance.clip.clip_modified.connect(_on_clip_modified)
		queue_redraw()


func _on_clip_modified():
	print("clip modified")
	# TODO: for notes:
	# - We should check speifically for midi note changes.
	#
	# for audio, we should only redraw if audio waveform actually changes.
	# gain can simply scale the control - faster ;)
	queue_redraw()


func _process(delta: float) -> void:
	## Poll zoom level changes and update current_level indicator with debouncing
	if not clip_instance or not clip_instance.clip:
		return

	var clip = clip_instance.clip
	if clip.type != Clip.ClipType.AUDIO or clip.audio_waveform == null:
		return

	# Get current zoom
	var timeline = Sonara.editor.arranger.timeline
	if not timeline:
		return

	var pixels_per_beat = timeline.grid_helper.pixels_per_beat
	var ppq = timeline.grid_helper.ppq

	# Select which level we would use at current zoom
	var selected_waveform = clip.audio_waveform.get_ready_level_for_zoom(
		pixels_per_beat,
		ppq,
		clip_instance.duration_ticks,
		size.x
	)

	if selected_waveform:
		var new_level = clip.audio_waveform.levels.find(selected_waveform)
		
		# Debounce logic: track pending level and accumulate time
		if new_level != _pending_level:
			# Level changed, reset debounce timer
			_pending_level = new_level
			_debounce_time = 0.0
		else:
			# Level is stable, accumulate time
			_debounce_time += delta
			
			# If we've waited long enough and it's different from current, apply the change
			if _debounce_time >= LOD_DEBOUNCE_DELAY and _pending_level != current_level:
				print_rich("[color=blue][LOD_CHANGE][/color] Zoom: %.1f px/beat → Level %d (block_size=%d, num_blocks=%d)" % [
					pixels_per_beat,
					_pending_level,
					selected_waveform.resolution,
					selected_waveform.num_blocks
				])
				current_level = _pending_level
				queue_redraw()  # Redraw when level actually changes


func _draw() -> void:
	if clip_instance and clip_instance.clip:
		if clip_instance.clip.type == Clip.ClipType.MIDI:
			_draw_midi()
		else:
			_draw_waveform()

func _draw_midi():
	# get the lowest and highest notes
	var clip = clip_instance.clip
	
	var lowest = clip.find_lowest_note()
	var highest = clip.find_highest_note()
	var note_range = highest - lowest
	
	# If all notes are the same, we need to avoid division by zero
	# and ensure the note is visible
	if note_range == 0:
		note_range = 1
		lowest = highest - 1  # Extend range by 1 to make the note visible
	
	# Calculate note height to fit all notes within the control height
	var note_height = size.y / (note_range + 2)
	
	var clip_length_ticks = clip_instance.duration_ticks
	var clip_offset = clip_instance.clip_offset
	
	# Calculate the visible range of the clip (in clip-local ticks)
	var visible_start = clip_offset
	var visible_end = clip_offset + clip_length_ticks

	for note:MidiNoteData in clip.midi_notes:
		var note_end = note.start_tick + note.duration_ticks
		
		# Skip notes that are completely outside the visible range
		if note_end <= visible_start or note.start_tick >= visible_end:
			continue
		
		# Calculate note position relative to the visible window
		var note_local_start = note.start_tick - clip_offset
		var note_local_end = note_end - clip_offset
		
		# Clip the note to the visible range (handle partial visibility)
		var draw_start = max(note_local_start, 0)
		var draw_end = min(note_local_end, clip_length_ticks)
		var draw_duration = draw_end - draw_start
		
		# Map to screen coordinates
		var x = remap(draw_start, 0, clip_length_ticks, 0, size.x)
		var w = remap(draw_duration, 0, clip_length_ticks, 0, size.x)
		
		# Remap note number to Y position, ensuring it stays within bounds
		# Note: We subtract note_height because we're drawing from the top down
		var y = remap(note.note, lowest, highest, size.y - note_height, 0)
		
		# Ensure the note stays within vertical bounds
		y = clamp(y, 0, size.y - note_height)
		
		draw_rect(Rect2(x, y, w, note_height), note_color, true, -1.0, true) 


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

	# ZOOM CHANGE DETECTION: Check if zoom level changed since last draw
	var zoom_changed = not is_equal_approx(_last_pixels_per_beat, pixels_per_beat)
	if zoom_changed:
		_last_pixels_per_beat = pixels_per_beat
		_last_selected_waveform = null  # Force re-selection
		_last_selected_lod_level = -1

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

	# Log zoom and LOD info (concise single line)
	var current_lod_level = clip.audio_waveform.levels.find(waveform)
	if zoom_changed:
		print_rich("[color=magenta][WAVEFORM][/color] Zoom: %.1f px/beat | LOD: level %d (%d blocks, %d ch) | Clip: offset=%d ticks, duration=%d ticks" % [
			pixels_per_beat, current_lod_level, waveform.num_blocks, waveform.channels, clip_instance.clip_offset, clip_instance.duration_ticks
		])
		print_rich("[color=cyan][WAVEFORM][/color] Sample range: %d to %d (%.2f samples/tick)" % [
			waveform_start_sample, waveform_end_sample, samples_per_tick
		])

		# Debug: show all available levels
		print_rich("[color=green][LOD_LEVELS][/color] Available levels: %d" % clip.audio_waveform.levels.size())
		for i in range(clip.audio_waveform.levels.size()):
			var lvl = clip.audio_waveform.levels[i]
			if lvl:
				var blocks_per_px = float(lvl.num_blocks) / size.x if size.x > 0 else 0.0
				print_rich("  Level %d: %d blocks (res=%d) = %.2f blocks/px %s" % [
					i, lvl.num_blocks, lvl.resolution, blocks_per_px,
					"[SELECTED]" if i == current_lod_level else ""
				])
			else:
				print_rich("  Level %d: null" % i)
		# Uncomment to see detailed waveform info:
		# print(waveform)

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
