# Draws either midi notes or audio waveform of a clip
class_name MidiclipRenderer extends Control

@export var note_color := Color("#eee")

var clip_instance : ClipInstance:
	set(c):
		if clip_instance and clip_instance.clip:
			if clip_instance.clip.clip_modified.is_connected(_on_clip_modified):
				clip_instance.clip.clip_modified.disconnect(_on_clip_modified)
		clip_instance = c
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
	"""Draw stereo waveform with appropriate resolution based on clip width."""
	if not clip_instance or not clip_instance.clip:
		return

	var clip = clip_instance.clip
	if clip.type != Clip.ClipType.AUDIO or not clip.audio_waveform:
		if clip.type != Clip.ClipType.AUDIO:
			print("clip is not audio type!")
		elif not clip.audio_waveform:
			print("missing audio_waveform!")
		return

	if size.x <= 0:
		return  # Can't render if width is zero

	# Calculate the visible portion of the clip
	var total_audio_samples = clip.audio_samples.size() / clip.audio_channels
	var clip_duration_ticks = clip.content_length_ticks
	var clip_offset = clip_instance.clip_offset
	var instance_duration = clip_instance.duration_ticks
	
	# Convert tick offsets to sample positions
	var offset_ratio = float(clip_offset) / float(clip_duration_ticks) if clip_duration_ticks > 0 else 0.0
	var duration_ratio = float(instance_duration) / float(clip_duration_ticks) if clip_duration_ticks > 0 else 1.0
	
	var start_sample = int(offset_ratio * total_audio_samples)
	var end_sample = int((offset_ratio + duration_ratio) * total_audio_samples)
	var visible_samples = end_sample - start_sample

	# Determine effective samples per pixel based on visible region
	var target_resolution = int(float(visible_samples) / float(size.x))

	# Get the best matching waveform resolution
	var waveform = clip.audio_waveform.get_waveform_for_resolution(target_resolution)
	if not waveform:
		print("missing waveform for resolution: ", target_resolution)
		return

	# Apply gain as visual scale
	var gain_linear = db_to_linear(clip_instance.gain_offset)
	var height_per_channel = size.y / clip.audio_channels
	var center_y_offset = height_per_channel / 2.0

	# Calculate which waveform pixels correspond to the visible region
	var samples_per_waveform_pixel = waveform.samples_per_pixel
	var start_waveform_pixel = int(float(start_sample) / float(samples_per_waveform_pixel))
	var end_waveform_pixel = int(float(end_sample) / float(samples_per_waveform_pixel))
	var visible_waveform_pixels = end_waveform_pixel - start_waveform_pixel

	# Scale factor to map visible waveform pixels to screen width
	var scale_x = float(size.x) / float(visible_waveform_pixels) if visible_waveform_pixels > 0 else 1.0

	# Draw waveforms for each channel
	for ch in range(clip.audio_channels):
		var peak_data = waveform.peak_data_left if ch == 0 else waveform.peak_data_right

		# Only draw the visible portion
		for i in range(visible_waveform_pixels):
			var waveform_pixel = start_waveform_pixel + i
			if waveform_pixel >= peak_data.size():
				break
				
			var peak_pair = peak_data[waveform_pixel]
			var min_sample = peak_pair.x * gain_linear
			var max_sample = peak_pair.y * gain_linear

			# Map waveform pixel to screen position (relative to visible region)
			var pixel_x = i * scale_x

			# Remap from [-1, 1] to pixel space
			var base_y = ch * height_per_channel + center_y_offset
			var min_y = base_y - (min_sample * (center_y_offset - 1.0))
			var max_y = base_y - (max_sample * (center_y_offset - 1.0))

			# Draw vertical line representing min/max for this pixel
			var line_color = Color.WHITE if ch == 0 else Color.WHITE.darkened(0.2)
			draw_line(Vector2(pixel_x, min_y), Vector2(pixel_x, max_y), line_color, 1.0)

		# Draw center line for this channel
		draw_line(
			Vector2(0, ch * height_per_channel + center_y_offset),
			Vector2(size.x, ch * height_per_channel + center_y_offset),
			Color(0.5, 0.5, 0.5, 0.3),
			0.5
		)


func db_to_linear(db: float) -> float:
	"""Convert dB to linear gain."""
	return 10.0 ** (db / 20.0)
