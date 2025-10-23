# Editor.gd
# Main DAW Editor - manages project lifecycle and UI coordination
# Data classes (Project, Track, Channel) now handle their own audio engine sync

class_name Editor extends Control

# ============================================================================
# SIGNALS - UI event notifications
# ============================================================================

# Project lifecycle
signal project_opened(project: Project)
signal project_activated(project: Project)  # Alias for project_opened, for clarity
signal project_closed()
signal project_saved(path: String)
signal project_modified()  # Any change that requires saving

# tempo, time signature
signal tempo_changed(tempo: float)
signal time_signature_changed(numerator: int, denominator: int)

# Transport
signal playback_started()
signal playback_stopped()
signal playhead_moved(ticks: int)

# Selection / Focus
signal clip_instance_selected(instance: ClipInstance)  # Emitted when a clip instance is selected

signal channel_focused(channel : Channel)
signal track_focused(track : Track)

# ============================================================================
# NODE REFERENCES
# ============================================================================

@onready var main_menu: MenuBar = $VBox/MainBar/MainMenu

@onready var play_button: Button = $VBox/MainBar/Middle/TransportControls/Buttons/PlayButton
@onready var stop_button: Button = $VBox/MainBar/Middle/TransportControls/Buttons/StopButton

@onready var tempo_spinbox: SpinBox = $VBox/MainBar/Middle/TransportStatus/HBox/Options/Tempo
@onready var time_signature_edit: LineEdit = $VBox/MainBar/Middle/TransportStatus/HBox/Options/TimeSignature

@onready var transport_position_label: Label = $VBox/MainBar/Middle/TransportStatus/HBox/Status/Position
@onready var transport_time_label: Label = $VBox/MainBar/Middle/TransportStatus/HBox/Status/Time

# Center area is a Vsplit of primary (large, top) and secondary (below, short) panels
# - Primary: Arranger/Mixer/ClipEditor (switchable)
# - Secondary: can show device lane, mini clip editor or mini mixer (switchable)
@onready var center_vsplit : VSplitContainer = $VBox/Main/HSplitContainer/HSplit/CenterArea/VSplit
@onready var primary_panel: PanelContainer = $VBox/Main/HSplitContainer/HSplit/CenterArea/VSplit/Primary
@onready var seconday_panel: PanelContainer = $VBox/Main/HSplitContainer/HSplit/CenterArea/VSplit/Secondary

# primary panels: arranger, mixer and clip editor
@onready var arranger: Arranger = $VBox/Main/HSplitContainer/HSplit/CenterArea/VSplit/Primary/Arranger
@onready var mixer: Mixer = $VBox/Main/HSplitContainer/HSplit/CenterArea/VSplit/Primary/Mixer
@onready var clip_editor: ClipEditor = $VBox/Main/HSplitContainer/HSplit/CenterArea/VSplit/Primary/ClipEditor

# secondary panels
@onready var device_lane : DeviceLane = $VBox/Main/HSplitContainer/HSplit/CenterArea/VSplit/Secondary/DeviceLane

# ============================================================================
# STATE
# ============================================================================

# Current project instance
var project: Project = null

# Project file path
var project_path: String = ""

# Modified flag
var is_modified: bool = false

# Transport state
var is_playing: bool = false
var playhead_ticks: int = 0
var audio_engine_playhead: int = 0  # Authoritative playhead from audio engine
var playhead_interpolation_speed: float = 0.0  # For smooth UI updates

# Selection State (Channels and tracks)
var focused_channel : Channel

# View state
enum View { ARRANGER, MIXER, EDITOR }
var current_view: View = View.ARRANGER

# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready():
	# Connect UI signals
	_connect_ui_signals()

	# Connect to audio engine OSC signals
	_connect_audio_engine_signals()

	# Set initial view
	_update_view_visibility()
	
	# Disable processing until playback starts
	set_process(false)
	
	# Initialize a new, blank project and open it
	var new_project = Project.new()
	new_project.project_name = "Untitled"
	new_project.created_date = Time.get_unix_time_from_system()
	open_project(new_project)
	
	# for testing, create a instrument track
	project.create_instrument_track() 


func _connect_ui_signals():
	# Transport controls
	play_button.toggled.connect(_on_play_toggled)
	stop_button.pressed.connect(_on_stop_pressed)
	
	# Tempo/time signature
	tempo_spinbox.value_changed.connect(_on_tempo_changed)
	time_signature_edit.text_submitted.connect(_on_time_signature_changed)
	
	# Arranger selection changes
	arranger.clips_selected.connect(_on_arranger_clips_selected)
	
	# Mixer
	mixer.channel_focused.connect(_on_mixer_channel_focused)


func _on_mixer_channel_focused(channel : Channel):
	if focused_channel != channel:
		focused_channel = channel
		channel_focused.emit(channel)


func _connect_audio_engine_signals():
	"""Connect to audio engine OSC signals."""
	if AudioEngineOSC:
		# Listen for transport updates
		AudioEngineOSC.listen("/status/playhead", _on_playhead_received)
		AudioEngineOSC.listen("/status/playing", _on_playing_received)
		AudioEngineOSC.engine_connected.connect(_on_audio_engine_connected)
		print("[Editor] Connected to audio engine OSC signals")

func _unhandled_input(event: InputEvent) -> void:
	"""Handle input actions."""
	# Check for pause_here with shift modifier
	if event.is_action_pressed("pause_here"):
		if event is InputEventKey and event.shift_pressed:
			if is_playing:
				# Pause without seeking
				pause_here()
			else:
				# Start playback from current position
				play()
			accept_event()
			return

	# Check for play/pause without shift
	if event.is_action_pressed("play"):
		# Only handle if shift is NOT pressed (to avoid conflict with pause_here)
		if event is InputEventKey and not event.shift_pressed:
			if is_playing:
				# When playing, pause and seek to start_position
				pause()
				if project:
					set_playhead(project.start_position_ticks)
			else:
				play()
			accept_event()
			return
	elif event.is_action_pressed("switch_extra_view"):
		switch_extra_view()
		accept_event()
	elif event.is_action_pressed("switch_view"):
		switch_view()
		accept_event()
	
	if event.is_action_pressed("toggle_device_lane"):
		# only if no modifiers are pressed
		if event is InputEventKey:
			var kevent = event as InputEventKey
			if kevent.get_modifiers_mask() == 0:
				toggle_device_lane()
				accept_event()


# ============================================================================
# PROJECT MANAGEMENT
# ============================================================================
func open_project(p: Project) -> void:
	"""Open a project and connect it to audio engine."""
	if project != null:
		close_project()

	project = p
	is_modified = false

	# Update UI state
	_update_transport_ui()

	# Emit project opened/activated signals for UI
	project_opened.emit(project)
	project_activated.emit(project)

	# Connect to audio engine immediately (OSC messages dropped if engine not running)
	if AudioEngineOSC:
		# Clear project (this clears clips, tracks, channels from engine)
		AudioEngineOSC.send("/project/clear", [])
		project.connect_to_engine()

	print("[Editor] Project opened: ", project.project_name)

func close_project() -> void:
	"""Close the current project."""
	if project == null:
		return

	# TODO: Prompt to save if modified
	if is_modified:
		print("[Editor] Warning: Closing modified project without saving")

	# Disconnect from audio engine
	project.disconnect_from_engine()

	project = null
	project_path = ""
	is_modified = false
	playhead_ticks = 0
	is_playing = false

	project_closed.emit()
	print("[Editor] Project closed")

func save_project(path: String = "") -> bool:
	"""Save the current project to a file."""
	if project == null:
		push_error("[Editor] Cannot save: No project open")
		return false
	
	# Use provided path or existing path
	var save_path = path if path != "" else project_path
	
	if save_path == "":
		push_error("[Editor] Cannot save: No file path specified")
		return false
	
	# Update modified date
	project.modified_date = Time.get_unix_time_from_system()
	
	# Serialize to JSON
	var json_data = project.to_json()
	var json_string = JSON.stringify(json_data, "\t")
	
	# Write to file
	var file = FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		push_error("[Editor] Failed to open file for writing: ", save_path)
		return false
	
	file.store_string(json_string)
	file.close()
	
	project_path = save_path
	is_modified = false
	
	project_saved.emit(save_path)
	print("[Editor] Project saved: ", save_path)
	return true

func load_project(path: String) -> bool:
	"""Load a project from a file."""
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[Editor] Failed to open file for reading: ", path)
		return false
	
	var json_string = file.get_as_text()
	file.close()
	
	var json_data = JSON.parse_string(json_string)
	if json_data == null:
		push_error("[Editor] Failed to parse JSON from file: ", path)
		return false
	
	var loaded_project = Project.from_json(json_data)
	if loaded_project == null:
		push_error("[Editor] Failed to deserialize project from JSON")
		return false
	
	project_path = path
	open_project(loaded_project)
	print("[Editor] Project loaded: ", path)
	return true

# Note: Track and Channel management now done via Project methods
# UI components should call project.create_track(), channel.set_volume(), etc.

# ============================================================================
# TRANSPORT CONTROL
# ============================================================================

func play() -> void:
	"""Start playback from current playhead position."""
	if is_playing:
		return

	# Send play command to audio engine (it will update our state)
	AudioEngineOSC.send("/transport/play", [])
	print("[Editor] Play command sent to audio engine")


func pause() -> void:
	"""Pause playback (stops playing but keeps playhead position)."""
	# Send pause command to audio engine (it will update our state)
	AudioEngineOSC.send("/transport/pause", [])
	print("[Editor] Pause command sent to audio engine")


func pause_here() -> void:
	"""Pause playback without seeking (keeps playhead where it is)."""
	pause()


func stop() -> void:
	"""Stop playback and handle start position based on playback state."""
	if is_playing:
		# If playing, stop and seek to start_position
		AudioEngineOSC.send("/transport/stop", [])
		print("[Editor] Stop command sent to audio engine (seeking to start position)")
		if project:
			set_playhead(project.start_position_ticks)
	else:
		# If not playing, reset start_position to origin and seek there
		if project:
			project.set_start_position(0)
		set_playhead(0)
		print("[Editor] Stop: reset start position and playhead to origin")


func set_playhead(ticks: int) -> void:
	"""Set playhead position."""
	# Send seek command to audio engine
	AudioEngineOSC.send("/transport/seek", [ticks])
	# Update both local and engine playhead immediately to avoid desync
	playhead_ticks = ticks
	audio_engine_playhead = ticks
	playhead_moved.emit(ticks)
	_update_transport_ui()


func set_tempo(new_tempo: float) -> void:
	"""Set project tempo."""
	if project == null:
		return

	project.tempo = clamp(new_tempo, 20.0, 999.0)

	# Sync to audio engine if connected
	if project._is_connected:
		AudioEngineOSC.send("/transport/tempo", [project.tempo])

	_mark_modified()
	_update_transport_ui()
	tempo_changed.emit(project.tempo)


func set_time_signature(numerator: int, denominator: int) -> void:
	"""Set project time signature."""
	if project == null:
		return

	project.time_numerator = numerator
	project.time_denominator = denominator

	# Sync to audio engine if connected
	if project._is_connected:
		AudioEngineOSC.send("/transport/time_signature", [numerator, denominator])

	_mark_modified()
	_update_transport_ui()
	time_signature_changed.emit(numerator, denominator)


# ============================================================================
# VIEW MANAGEMENT
# ============================================================================

func switch_view() -> void:
	"""Toggle between arranger and mixer views."""
	if current_view == View.ARRANGER:
		current_view = View.MIXER
	else:
		current_view = View.ARRANGER
	
	_update_view_visibility()
	print("[Editor] Switched to ", View.keys()[current_view], " view")


func switch_extra_view() -> void:
	"""Toggle between aranger/mixer and Clip Editor"""
	if current_view == View.EDITOR:
		current_view = View.ARRANGER
	else:
		current_view = View.EDITOR
	
	_update_view_visibility()
	print("[Editor] Switched to ", View.keys()[current_view], " view")


func toggle_device_lane():
	print("toggglng device lane")
	if seconday_panel.visible and device_lane.visible:
		# hide device lane
		device_lane.hide()
		seconday_panel.hide()
	else:
		# show
		device_lane.show()
		
		device_lane.bind_to_channel(focused_channel)
		
		if not seconday_panel.visible:
			seconday_panel.show()


# ============================================================================
# UI CALLBACKS
# ============================================================================

func _on_play_toggled(pressed: bool) -> void:
	"""Play button toggled."""
	if pressed:
		play()
	else:
		pause()  # Use pause instead of stop to preserve playhead position

func _on_stop_pressed() -> void:
	"""Stop button pressed - stop and reset to 0."""
	stop()  # This will reset playhead to 0 in the engine

func _on_tempo_changed(value: float) -> void:
	set_tempo(value)

func _on_time_signature_changed(text: String) -> void:
	# Parse "4/4" format
	var parts = text.split("/")
	if parts.size() == 2:
		var num = parts[0].to_int()
		var den = parts[1].to_int()
		if num > 0 and den > 0:
			set_time_signature(num, den)


func _on_arranger_clips_selected(clips: Array[ClipInstance], multi_track: bool) -> void:
	"""Handle clip selection from Arranger."""
	if clips.is_empty():
		return
	
	var last := clips[-1]
	clip_instance_selected.emit(last)


# ============================================================================
# INTERNAL HELPERS
# ============================================================================

func _mark_modified() -> void:
	"""Mark project as modified."""
	if not is_modified:
		is_modified = true
		project_modified.emit()

func _update_transport_ui() -> void:
	"""Update transport UI elements."""
	if project == null:
		return
	
	# Update tempo
	if tempo_spinbox:
		tempo_spinbox.set_value_no_signal(project.tempo)
	
	# Update time signature
	if time_signature_edit:
		time_signature_edit.text = "%d/%d" % [project.time_numerator, project.time_denominator]
	
	# Update position display
	if transport_position_label and project:
		var bbt = _ticks_to_bbt(playhead_ticks)
		transport_position_label.text = "%d.%d.%d.%03d" % [bbt.bar, bbt.beat, bbt.sixteenth, bbt.tick]
	
	# Update time display
	if transport_time_label and project:
		var seconds = _ticks_to_seconds(playhead_ticks)
		var minutes = int(seconds / 60)
		var secs = int(seconds) % 60
		var ms = int((seconds - int(seconds)) * 1000)
		transport_time_label.text = "%02d:%02d.%03d" % [minutes, secs, ms]

func _ticks_to_bbt(ticks: int) -> Dictionary:
	"""Convert ticks to bars/beats/sixteenths/ticks (4-number format like Bitwig)."""
	if project == null:
		return {"bar": 1, "beat": 1, "sixteenth": 1, "tick": 0}
	
	@warning_ignore("integer_division")
	var ticks_per_bar = project.ppq * project.time_numerator
	@warning_ignore("integer_division")
	var bar = ticks / ticks_per_bar
	var remaining = ticks % ticks_per_bar
	
	@warning_ignore("integer_division")
	var beat = remaining / project.ppq
	var beat_remainder = remaining % project.ppq
	
	# Sixteenth note = quarter of a beat (PPQ / 4)
	@warning_ignore("integer_division")
	var ticks_per_sixteenth = project.ppq / 4
	@warning_ignore("integer_division")
	var sixteenth = beat_remainder / ticks_per_sixteenth
	var tick = beat_remainder % ticks_per_sixteenth
	
	return {"bar": bar + 1, "beat": beat + 1, "sixteenth": sixteenth + 1, "tick": tick}

func _ticks_to_seconds(ticks: int) -> float:
	"""Convert ticks to seconds."""
	if project == null:
		return 0.0
	
	var seconds_per_tick = 60.0 / (project.tempo * project.ppq)
	return ticks * seconds_per_tick

func _update_view_visibility() -> void:
	"""Update visibility of arranger and mixer based on current view."""
	arranger.visible = (current_view == View.ARRANGER)
	mixer.visible = (current_view == View.MIXER)
	clip_editor.visible = (current_view == View.EDITOR)

	if clip_editor.visible:
		clip_editor.call_deferred("grab_focus")

func _process(delta: float) -> void:
	"""Update playhead during playback with smooth interpolation."""
	if not is_playing or project == null:
		return
	
	# Interpolate toward audio engine's authoritative playhead for smooth UI
	if audio_engine_playhead > playhead_ticks:
		# Calculate expected advance rate
		var ticks_per_second = (project.tempo * project.ppq) / 60.0
		var expected_advance = ticks_per_second * delta
		
		# Interpolate with slight correction toward engine playhead
		var correction = (audio_engine_playhead - playhead_ticks) * 0.1
		var advance = expected_advance + correction
		
		playhead_ticks += int(advance)
		playhead_ticks = min(playhead_ticks, audio_engine_playhead)  # Don't overshoot
		
		playhead_moved.emit(playhead_ticks)
		_update_transport_ui()


# ============================================================================
# AUDIO ENGINE CALLBACKS
# ============================================================================

func _on_audio_engine_connected() -> void:
	"""Called when audio engine connection is established."""
	print("[Editor] Audio engine connected")

	# Auto-connect project if one is open
	if project and not project._is_connected:
		project.connect_to_engine()


func _on_playhead_received(values) -> void:
	"""Called when audio engine sends playhead update."""
	# AudioEngineOSC normalizes all values to Array, so extract first element
	var tick_value = 0
	if values is Array and values.size() > 0:
		tick_value = values[0]
	else:
		print("[Editor] WARNING: Unexpected playhead format: ", values)
		return

	audio_engine_playhead = tick_value

	# Always update UI immediately when playhead is reset to 0 (stop command)
	# or when not playing (since _process() is disabled)
	if tick_value == 0 or not is_playing:
		playhead_ticks = tick_value
		playhead_moved.emit(playhead_ticks)
		_update_transport_ui()
	# When playing (and not reset), don't emit playhead_moved here - let _process() handle smooth interpolation


func _on_playing_received(values) -> void:
	"""Called when audio engine playing state changes."""
	# AudioEngineOSC normalizes all values to Array, so extract first element
	var playing_value = values[0] if values is Array and values.size() > 0 else values
	var playing = (playing_value != 0)
	
	if is_playing != playing:
		is_playing = playing

		# Update UI
		if play_button:
			play_button.set_pressed_no_signal(playing)

		# Emit signals
		if playing:
			playback_started.emit()
			set_process(true)
			print("[Editor] Playback started (from engine)")
		else:
			playback_stopped.emit()
			set_process(false)
			print("[Editor] Playback stopped (from engine)")
