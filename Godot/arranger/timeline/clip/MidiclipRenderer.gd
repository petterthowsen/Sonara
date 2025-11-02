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


func _draw_waveform_placeholder() -> void:
	"""Draw a placeholder while waveform is loading or unavailable."""
	if not clip_instance or not clip_instance.clip:
		return

	var clip = clip_instance.clip

	# Determine placeholder color based on load state
	var bg_color: Color
	var text: String

	match clip.load_state:
		Clip.LoadState.LOADING:
			bg_color = Color(0.3, 0.5, 0.8, 0.3)
			text = "Loading..."
			# Draw progress bar
			var progress = clamp(clip.load_progress, 0.0, 1.0)
			draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * progress, size.y)), Color(0.4, 0.6, 1.0, 0.6), true)
		Clip.LoadState.READY:
			bg_color = Color(0.4, 0.4, 0.4, 0.2)
			text = "Waveform generating..."
		Clip.LoadState.FAILED:
			bg_color = Color(0.6, 0.1, 0.1, 0.4)
			text = "Failed to load"
		_:
			bg_color = Color(0.2, 0.2, 0.2, 0.3)
			text = "Unloaded"

	# Draw background
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)


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
	if clip.type != Clip.ClipType.AUDIO:
		print("[MidiClipRenderer] clip is not audio type!")
		return

	if not clip.audio_waveform:
		print("[MidiClipRenderer] audio_waveform not initialized for clip ", clip.id)
		# Draw placeholder while waveform is loading
		_draw_waveform_placeholder()
		return

	# Check if waveform has any levels loaded
	if clip.audio_waveform.levels.is_empty():
		print("[MidiClipRenderer] waveform has no levels for clip ", clip.id, " (load_state=", clip.load_state, ")")
		_draw_waveform_placeholder()
		return

	if size.x <= 0:
		return  # Can't render if width is zero

	if clip.load_state != Clip.LoadState.READY:
		var bg_color := Color(0.2, 0.2, 0.2, 0.4)
		match clip.load_state:
			Clip.LoadState.LOADING:
				draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)
				draw_rect(
					Rect2(Vector2.ZERO, Vector2(size.x * clamp(clip.load_progress, 0.0, 1.0), size.y)),
					Color(0.3, 0.6, 1.0, 0.6),
					true
				)
			Clip.LoadState.FAILED:
				draw_rect(Rect2(Vector2.ZERO, size), Color(0.6, 0.1, 0.1, 0.5), true)
				draw_line(Vector2(0, 0), Vector2(size.x, size.y), Color(1, 0.3, 0.3, 0.8), 2.0)
				draw_line(Vector2(size.x, 0), Vector2(0, size.y), Color(1, 0.3, 0.3, 0.8), 2.0)
			Clip.LoadState.UNLOADED:
				draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)
		return

	# Simple waveform rendering: for each screen pixel, draw min/max amplitude
	var gain_linear = db_to_linear(clip_instance.gain_offset)
	var channel_count = max(clip.audio_channels, 1)
	var height_per_channel = size.y / channel_count
	var center_y_offset = height_per_channel / 2.0

	# Calculate target waveform resolution based on zoom
	var waveform_pyramid = clip.audio_waveform

	print("[MidiClipRenderer] _draw_waveform start: waveform_pyramid=", waveform_pyramid, " levels=", waveform_pyramid.levels.size() if waveform_pyramid else "N/A")

	if not waveform_pyramid or waveform_pyramid.levels.is_empty():
		print("[MidiClipRenderer] No waveform_pyramid or levels empty, returning")
		return

	# Get the total audio duration in samples
	var total_samples = waveform_pyramid.duration_samples
	print("[MidiClipRenderer] total_samples=", total_samples)

	if total_samples <= 0:
		print("[MidiClipRenderer] total_samples <= 0, returning")
		return

	# Map clip offset and duration to waveform pixels FIRST
	var clip_offset = clip_instance.clip_offset
	var clip_duration = clip_instance.duration_ticks
	var content_length = clip.content_length_ticks

	var offset_ratio = clamp(float(clip_offset) / float(content_length), 0.0, 1.0)
	var duration_ratio = clamp(float(clip_duration) / float(content_length), 0.0, 1.0)

	# Calculate how many samples we're actually displaying (not the entire audio)
	var visible_samples = int(duration_ratio * float(total_samples))
	if visible_samples <= 0:
		visible_samples = 1

	# How many samples per screen pixel for the VISIBLE portion?
	var target_spp = int(float(visible_samples) / max(1.0, float(size.x)))
	if target_spp <= 0:
		target_spp = 1

	# Get best matching waveform level
	var waveform = waveform_pyramid.get_waveform_for_resolution(target_spp)
	if not waveform:
		return

	var waveform_size = waveform.peak_data_left.size() if waveform.peak_data_left else 0
	if waveform_size <= 0:
		return

	var start_pixel = int(offset_ratio * float(waveform_size))
	var end_pixel = int((offset_ratio + duration_ratio) * float(waveform_size))
	start_pixel = clamp(start_pixel, 0, waveform_size - 1)
	end_pixel = clamp(end_pixel, start_pixel + 1, waveform_size)

	var visible_waveform_pixels = end_pixel - start_pixel
	if visible_waveform_pixels <= 0:
		return

	# Draw waveform as polylines for each channel
	print("[MidiClipRenderer] Drawing waveform: target_spp=", target_spp, " waveform_size=", waveform_size, " visible_pixels=", visible_waveform_pixels, " screen_width=", size.x)

	for ch in range(channel_count):
		var peak_data = waveform.peak_data_left if ch == 0 else waveform.peak_data_right
		if not peak_data or peak_data.is_empty():
			print("[MidiClipRenderer] No peak data for channel ", ch)
			continue

		var ch_top = ch * height_per_channel
		var ch_center = ch_top + center_y_offset
		var ch_bottom = ch_top + height_per_channel

		# Build polyline points
		var top_points = PackedVector2Array()
		var bottom_points = PackedVector2Array()

		# Sample and map waveform pixels to screen
		for i in range(visible_waveform_pixels):
			var waveform_idx = start_pixel + i
			if waveform_idx >= peak_data.size():
				break

			var peak_pair = peak_data[waveform_idx]
			var min_amp = clamp(peak_pair.x * gain_linear, -1.0, 1.0)
			var max_amp = clamp(peak_pair.y * gain_linear, -1.0, 1.0)

			# Map to screen coordinates
			var t = float(i) / float(max(1, visible_waveform_pixels - 1))
			var screen_x = t * float(size.x)

			var y_max = ch_center - (max_amp * center_y_offset)
			var y_min = ch_center - (min_amp * center_y_offset)

			top_points.append(Vector2(screen_x, clamp(y_max, ch_top, ch_bottom)))
			bottom_points.append(Vector2(screen_x, clamp(y_min, ch_top, ch_bottom)))

		# Draw waveform as two polylines
		if top_points.size() > 1:
			var color = Color.WHITE if ch == 0 else Color.WHITE.darkened(0.2)
			print("[MidiClipRenderer] Drawing polyline ch=", ch, " points=", top_points.size())
			draw_polyline(top_points, color, 1.0)
			draw_polyline(bottom_points, color, 1.0)

			# Fill between envelopes
			var fill_color = color * Color(1, 1, 1, 0.15)
			for i in range(min(top_points.size(), bottom_points.size())):
				draw_line(top_points[i], bottom_points[i], fill_color, 0.5)
		else:
			print("[MidiClipRenderer] Not enough points: ", top_points.size())

	# Draw center line for each channel
	for ch in range(channel_count):
		draw_line(
			Vector2(0, ch * height_per_channel + center_y_offset),
			Vector2(size.x, ch * height_per_channel + center_y_offset),
			Color(0.5, 0.5, 0.5, 0.3),
			0.5
		)


func db_to_linear(db: float) -> float:
	"""Convert dB to linear gain."""
	return 10.0 ** (db / 20.0)
