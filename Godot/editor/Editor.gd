# Editor.gd
# Main DAW Editor - manages project lifecycle and UI coordination
# Data classes (Project, Track, Channel) now handle their own audio engine sync

class_name Editor extends MarginContainer

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
signal clip_instance_selected(instance: ClipInstance)  # DEPRECATED: Use clips_selected instead
signal clips_selected(clips: Array[ClipInstance], multi_track: bool)  # Emitted when clip selection changes

signal channel_focused(channel : Channel)
signal track_focused(track : Track)

# ============================================================================
# NODE REFERENCES
# ============================================================================

# Top-Level Nodes in the top VBOX:

# main_bar houses main menu, audio engine status, transport controls and window buttons
@onready var main_bar: HBoxContainer = $VBoxContainer/Top

# main area has arraner/mixer/editor, and various side panels
@onready var main: BoxContainer = $VBoxContainer/Middle

# bottom has status bar: TODO: implement useful hotkey info of hovered element
@onready var bottom: VBoxContainer = $VBoxContainer/Bottom

# file, edit etc
@onready var main_menu: MainMenu = $VBoxContainer/Top/MainMenu

# engine panel shows connect/disconnect button and engine status
@onready var engine_panel: EnginePanel = $VBoxContainer/Top/EnginePanel

@onready var file_dialog : FileDialog = $FileDialog

@onready var play_button: Button = $VBoxContainer/Top/Transport/TransportControls/Buttons/PlayButton
@onready var stop_button: Button = $VBoxContainer/Top/Transport/TransportControls/Buttons/StopButton

@onready var tempo_spinbox: SpinBox = $VBoxContainer/Top/Transport/TransportStatus/HBox/Options/Tempo
@onready var time_signature_edit: LineEdit = $VBoxContainer/Top/Transport/TransportStatus/HBox/Options/TimeSignature

@onready var settings_dialog: SettingsDialog = $SettingsDialog

@onready var transport_position_label: Label = $VBoxContainer/Top/Transport/TransportStatus/HBox/Status/Position
@onready var transport_time_label: Label = $VBoxContainer/Top/Transport/TransportStatus/HBox/Status/Time

# Center area is a Vsplit of primary (large, top) and secondary (below, short) panels
# - Primary: Arranger/Mixer/ClipEditor (switchable)
# - Secondary: can show device lane, mini clip editor or mini mixer (switchable)
@onready var center_vsplit : VSplitContainer = $VBoxContainer/Middle/LeftRightSplit/LeftCenterSplit/MiddleCenter
@onready var primary_panel: PanelContainer = $VBoxContainer/Middle/LeftRightSplit/LeftCenterSplit/MiddleCenter/Primary
@onready var seconday_panel: PanelContainer = $VBoxContainer/Middle/LeftRightSplit/LeftCenterSplit/MiddleCenter/Secondary

# primary panels: arranger, mixer and clip editor
@onready var arranger: Arranger = $VBoxContainer/Middle/LeftRightSplit/LeftCenterSplit/MiddleCenter/Primary/Arranger
@onready var mixer: Mixer = $VBoxContainer/Middle/LeftRightSplit/LeftCenterSplit/MiddleCenter/Primary/Mixer
@onready var clip_editor: ClipEditor = $VBoxContainer/Middle/LeftRightSplit/LeftCenterSplit/MiddleCenter/Primary/ClipEditor

# secondary panels
@onready var device_lane : DeviceLane = $VBoxContainer/Middle/LeftRightSplit/LeftCenterSplit/MiddleCenter/Secondary/DeviceLane

# ============================================================================
# STATE
# ============================================================================

# Current project instance
var project: Project = null

# Project file path
var project_path: String = ""

# Modified flag
var is_modified: bool = false

# Undo/redo history for document mutations
var history: CommandHistory = CommandHistory.new()

# Transport state
var is_playing: bool = false
var playhead_ticks: int = 0
var audio_engine_playhead: int = 0  # Authoritative playhead from audio engine

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
	
	# ensure device lane is hidden
	device_lane.hide()
	seconday_panel.hide()

	# Initialize a new, blank project and open it
	var new_project = Project.new()
	new_project.project_name = "Untitled"
	new_project.created_date = Time.get_unix_time_from_system()
	open_project(new_project)
	
	# for testing, create a instrument track
	#project.create_instrument_track()

	# Optionally auto-add PolySynth when advertised by engine (skip if not available yet)
	#var channel := project.get_channel_by_id(2) #0 = null, 1 = master, 2 = first user channel
	#var polysynth := AssetService.get_device("sonara.builtin.polysynth")
	#if polysynth:
	#	var device_instance := DeviceInstance.new(polysynth, channel.id, 0, true, true)
	#	channel.add_device(device_instance)


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
	focus_channel(channel)


func focus_channel(channel: Channel) -> void:
	"""Public API to focus a channel and notify listeners (e.g., DeviceLane)."""
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
	if event.is_action_pressed("ui_undo"):
		undo()
		accept_event()
		return
	if event.is_action_pressed("ui_redo"):
		redo()
		accept_event()
		return

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
	history.clear()

	# Update UI state
	_update_transport_ui()

	# Emit project opened/activated signals for UI
	project_opened.emit(project)
	project_activated.emit(project)

	# Connect to audio engine after ensuring AudioEngineOSC is ready
	if AudioEngineOSC:
		_connect_project_to_engine.call_deferred()

	print("[Editor] Project opened: ", project.project_name)


func _connect_project_to_engine() -> void:
	"""Connect the project to the audio engine after OSC is ready."""
	# Wait for AudioEngineOSC to be fully initialized
	while not AudioEngineOSC._is_ready:
		await get_tree().process_frame
	
	# Connect project to engine (Project handles clearing and initialization)
	project.connect_to_engine()

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
	history.clear()

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
	history.mark_save_point()

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

	var old_tempo := project.tempo
	var clamped = clamp(new_tempo, 20.0, 999.0)
	if is_equal_approx(old_tempo, clamped):
		return

	project.tempo = clamped

	# Sync to audio engine if connected
	if project.is_connected_to_engine():
		AudioEngineOSC.send("/transport/tempo", [project.tempo])

	# Record mergeable tempo edits (spinbox drag / typing)
	var cmd := PropertyCommand.new("Set Tempo", self, "", old_tempo, clamped)
	cmd.set_callable(func(v): _apply_tempo_silent(v)).set_mergeable(true)
	record_command(cmd)

	_update_transport_ui()
	tempo_changed.emit(project.tempo)


## Apply tempo without pushing history (used by undo/redo PropertyCommand).
func _apply_tempo_silent(new_tempo: float) -> void:
	if project == null:
		return
	project.tempo = clamp(new_tempo, 20.0, 999.0)
	if project.is_connected_to_engine():
		AudioEngineOSC.send("/transport/tempo", [project.tempo])
	_update_transport_ui()
	tempo_changed.emit(project.tempo)


func set_time_signature(numerator: int, denominator: int) -> void:
	"""Set project time signature."""
	if project == null:
		return

	project.time_numerator = numerator
	project.time_denominator = denominator

	# Sync to audio engine if connected
	if project.is_connected_to_engine():
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
		# show - fail if no channel is focused
		if focused_channel == null:
			print("[Editor] Cannot open device lane: no channel is focused")
			return
		
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
	print("[Editor] Clips selected: %d clips, multi_track=%s" % [clips.size(), multi_track])
	
	# Emit new multi-clip signal
	clips_selected.emit(clips, multi_track)
	
	# Also emit old single-clip signal for backwards compatibility (if any clips selected)
	if not clips.is_empty():
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


## Run command.do() and push onto the undo stack; marks the project dirty.
func execute_command(cmd: Command) -> void:
	if cmd == null:
		return
	history.execute(cmd)
	_sync_modified_from_history()


## Push an already-applied gesture onto the undo stack; marks the project dirty.
func record_command(cmd: Command) -> void:
	if cmd == null:
		return
	history.record(cmd)
	_sync_modified_from_history()


## Undo the last document command.
func undo() -> bool:
	if not history.can_undo():
		return false
	var ok := history.undo()
	_sync_modified_from_history()
	return ok


## Redo the last undone document command.
func redo() -> bool:
	if not history.can_redo():
		return false
	var ok := history.redo()
	_sync_modified_from_history()
	return ok


## Keep is_modified in sync with the history save point.
func _sync_modified_from_history() -> void:
	if history.is_at_save_point():
		is_modified = false
	else:
		_mark_modified()


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
		var bbt = ticks_to_bbt(playhead_ticks)
		transport_position_label.text = "%d.%d.%d.%03d" % [bbt.bar, bbt.beat, bbt.sixteenth, bbt.tick]
	
	# Update time display
	if transport_time_label and project:
		var seconds = ticks_to_seconds(playhead_ticks)
		var minutes = int(seconds / 60)
		var secs = int(seconds) % 60
		var ms = int((seconds - int(seconds)) * 1000)
		transport_time_label.text = "%02d:%02d.%03d" % [minutes, secs, ms]

func ticks_to_bbt(ticks: int) -> Dictionary:
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


func ticks_to_seconds(ticks: int) -> float:
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
	elif arranger.visible:
		arranger.call_deferred("grab_focus")
	elif mixer.visible:
		mixer.call_deferred("grab_focus")


func _process(delta: float) -> void:
	"""Update playhead during playback with smooth interpolation."""
	if not is_playing or project == null:
		return
	
	# Calculate expected advance rate based on tempo
	var ticks_per_second = (project.tempo * project.ppq) / 60.0
	var expected_advance = ticks_per_second * delta
	
	# Check for large discontinuities (seeks, loops, tempo changes, etc.)
	var diff = audio_engine_playhead - playhead_ticks
	@warning_ignore("integer_division")
	var SNAP_THRESHOLD = project.ppq / 4  # Quarter note - snap immediately for larger jumps
	
	if abs(diff) > SNAP_THRESHOLD:
		# Large jump detected - snap immediately to avoid visible lag
		playhead_ticks = audio_engine_playhead
	else:
		# Small difference - interpolate smoothly with adaptive correction
		# Correction factor scales with drift size for faster convergence
		var correction_factor = clamp(abs(diff) / float(project.ppq), 0.05, 0.3)
		var correction = diff * correction_factor
		
		playhead_ticks += int(expected_advance + correction)
		
		# Clamp to engine position (handles both forward and backward movement)
		if diff > 0:
			playhead_ticks = min(playhead_ticks, audio_engine_playhead)
		else:
			playhead_ticks = max(playhead_ticks, audio_engine_playhead)
	
	playhead_moved.emit(playhead_ticks)
	_update_transport_ui()


# ============================================================================
# AUDIO ENGINE CALLBACKS
# ============================================================================

func _on_audio_engine_connected() -> void:
	"""Called when audio engine connection is established."""
	print("[Editor] Audio engine connected (project connection state: %s)" % (
		"CONNECTED" if project and project.is_connected_to_engine() else 
		"CONNECTING" if project and project.get_connection_state() == Project.ConnectionState.CONNECTING else
		"DISCONNECTED"
	))


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


# ============================================================================
# APP LIFECYCLE
# ============================================================================

func quit() -> void:
	"""Stop playback, close project, then quit the application."""
	# Ensure playback is stopped
	if is_playing:
		stop()

	# Close any active project
	close_project()

	# Exit the application
	get_tree().quit()
