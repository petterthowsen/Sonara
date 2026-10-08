# Editor.gd
# Main DAW Editor - manages project lifecycle and UI coordination
# Data classes (Project, Track, Channel) now handle their own audio engine sync

class_name Editor extends MarginContainer

var logger : Log = Log.make("Editor")

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
signal clips_selected(clips: Array[ClipInstance], multi_track: bool)  # Emitted when clip selection changes

signal channel_focused(channel : Channel)
signal track_focused(track : Track)
signal tracks_selected(tracks: Array[Track])

# View
signal view_changed(view: int)  # Editor.View

# ============================================================================
# NODE REFERENCES
# ============================================================================

# Top-Level Nodes in the top VBOX:

# main_bar houses main menu, audio engine status, transport controls and window buttons
@onready var main_bar: HBoxContainer = $VBoxContainer/Header/Top

# main area has arranger/mixer/editor, and left/right side docks
@onready var main: BoxContainer = $VBoxContainer/Middle
@onready var dock_host: DockHost = $VBoxContainer/Middle/LeftRightSplit

# bottom has status bar: TODO: implement useful hotkey info of hovered element
@onready var bottom: VBoxContainer = $VBoxContainer/Bottom

# file, edit etc
@onready var main_menu: MainMenu = $VBoxContainer/Header/Top/MainMenu

# engine panel shows connect/disconnect button and engine status
@onready var engine_panel: EnginePanel = $VBoxContainer/Header/Top/EnginePanel

@onready var file_dialog : FileDialog = $FileDialog

# shows DAWproject transfer reports and import/export errors
@onready var transfer_report_dialog: TransferReportDialog = $TransferReportDialog
@onready var export_audio_dialog: ExportAudioDialog = $ExportAudioDialog

@onready var play_button: Button = $VBoxContainer/Header/Top/Transport/TransportControls/Buttons/PlayButton
@onready var stop_button: Button = $VBoxContainer/Header/Top/Transport/TransportControls/Buttons/StopButton

@onready var tempo_spinbox: SpinBox = $VBoxContainer/Header/Top/Transport/TransportStatus/HBox/Options/Tempo
@onready var time_signature_edit: LineEdit = $VBoxContainer/Header/Top/Transport/TransportStatus/HBox/Options/TimeSignature
@onready var scale_picker: ScalePicker = $VBoxContainer/Header/Top/Transport/TransportStatus/HBox/Options/Scale

@onready var settings_dialog: SettingsDialog = $SettingsDialog

@onready var popup_message: PopupMessage = $PopupMessage

@onready var transport_position_label: Label = $VBoxContainer/Header/Top/Transport/TransportStatus/HBox/Status/Position
@onready var transport_time_label: Label = $VBoxContainer/Header/Top/Transport/TransportStatus/HBox/Status/Time

@onready var arrange_button: Button = $VBoxContainer/Bottom/InfoPanel/HBoxContainer/ViewButtons/Arrange
@onready var mix_button: Button = $VBoxContainer/Bottom/InfoPanel/HBoxContainer/ViewButtons/Mix
@onready var edit_button: Button = $VBoxContainer/Bottom/InfoPanel/HBoxContainer/ViewButtons/Edit

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

const STARTUP_DEVICES_TIMEOUT_MS := 8000

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

## Visual playhead position as a float, driven by _process().
## The engine reports at ~20 Hz while the UI renders at 60+ Hz, so we free-run this
## clock at tempo rate and correct its phase toward the engine gradually.
## Do not drive the playhead from the error against `audio_engine_playhead`, and do not
## clamp it to that value: doing so ties visual velocity to the update rate and makes it
## ripple (measured 10-30% velocity sd, worse at higher frame rates), which is what the
## playhead jitter was. See tests/test_playhead_interpolation.gd.
var _playhead_precise: float = 0.0
## Outstanding phase error (ticks) measured at the last engine update, bled off over time.
var _playhead_error: float = 0.0

## Ticks of disagreement with the engine beyond which we snap instead of correcting.
## Seeks, loop wraps and tempo changes land here. Expressed as a fraction of a beat.
const PLAYHEAD_SNAP_BEAT_FRACTION := 0.25
## How fast phase error is bled off, in units of "fraction of the error per second".
## Higher converges faster but passes more transport jitter through to the pixels.
const PLAYHEAD_CORRECTION_RATE := 5.0

## Test-only override for get_time_range(). Empty means "read the real arranger".
## Tests set this directly (e.g. `{"has": true, "start": 0, "has_end": true, "end": 1920}`)
## since there is no arranger outside the scene tree.
var test_time_range_override: Dictionary = {}

## Offline render jobs (export). While one runs the engine ignores the transport.
var render_service: RenderService

# Selection State (Channels and tracks)
var focused_channel : Channel
var focused_track: Track
var selected_tracks: Array[Track] = []
## True while one selection view is being updated from the other.
var _syncing_selection: bool = false

# View state
## DEVICE shows the attached device frame (spec 022); only while one is attached.
enum View { ARRANGER, MIXER, EDITOR, DEVICE }
var current_view: View = View.ARRANGER
## Device frame attached to the Primary area (DeviceWindowManager owns it), or null.
var attached_frame: DeviceFrame = null
## View to return to when the attached frame is hidden or detached.
var _view_before_device: View = View.ARRANGER
## View the attached frame belongs to: it shows only there and comes back when returning to it.
var _frame_view: View = View.ARRANGER

# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready():
	render_service = RenderService.new()
	render_service.name = "RenderService"
	add_child(render_service)
	render_service.running_changed.connect(_on_render_running_changed)

	# Connect UI signals
	_connect_ui_signals()

	# Connect to audio engine OSC signals
	_connect_audio_engine_signals()

	# Set initial view
	_update_view_visibility()
	# Device frames attach to the Primary area through us
	DeviceWindowManager.attach_host = self
	
	# Disable processing until playback starts
	set_process(false)
	
	# ensure device lane is hidden
	device_lane.hide()
	seconday_panel.hide()

	# Blank project first; a startup project replaces it once the devices it uses are known
	var new_project = Project.new()
	new_project.project_name = "Untitled"
	new_project.created_date = Time.get_unix_time_from_system()
	open_project(new_project)

	if not Utils.is_test_mode() and Sonara.has_startup_project():
		_load_startup_project()


## Built-in devices arrive from the engine after launch and project loading drops devices it
## doesn't know yet, so wait for them (bounded, in case the engine isn't running).
func _load_startup_project() -> void:
	var registry: DeviceRegistry = AssetService.device_registry
	var deadline := Time.get_ticks_msec() + STARTUP_DEVICES_TIMEOUT_MS
	while not registry.builtins_complete and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if project_path.is_empty() and not is_modified and Sonara.has_startup_project():
		load_project(Sonara.get_startup_project_path())


## Show an error/message in the shared PopupMessage window. `actions` entries are
## {"text": String, "callback": Callable} and appear before Copy/Close.
func show_error(title: String, body: String, actions: Array = []) -> void:
	if popup_message:
		popup_message.show_message(title, body, actions)


func _connect_ui_signals():
	# Transport controls
	play_button.toggled.connect(_on_play_toggled)
	stop_button.pressed.connect(_on_stop_pressed)
	_setup_transport_buttons()
	
	# View buttons: one ButtonGroup so exactly one stays pressed
	var view_group := ButtonGroup.new()
	for button in [arrange_button, mix_button, edit_button]:
		button.button_group = view_group
	arrange_button.pressed.connect(set_view.bind(View.ARRANGER))
	mix_button.pressed.connect(set_view.bind(View.MIXER))
	edit_button.pressed.connect(set_view.bind(View.EDITOR))

	# Tempo/time signature
	tempo_spinbox.value_changed.connect(_on_tempo_changed)
	time_signature_edit.text_submitted.connect(_on_time_signature_changed)
	scale_picker.scale_picked.connect(set_project_scale)
	
	# Arranger selection changes
	arranger.clips_selected.connect(_on_arranger_clips_selected)

	# Clip editor (MIDI editor) track-mode track list selection
	clip_editor.track_mode_track_selected.connect(_on_clip_editor_track_mode_track_selected)

	# Mixer
	mixer.channel_focused.connect(_on_mixer_channel_focused)

	# Track <-> channel selection sync
	(arranger.track_list as TrackList).selection_changed.connect(_on_track_list_selection_changed)
	mixer.selection_changed.connect(_on_mixer_selection_changed)

	if Settings:
		Settings.setting_changed.connect(_on_setting_changed)
	

## Mirror arranger track selection onto the mixer.
func _on_track_list_selection_changed(tracks: Array[Track], active: Track) -> void:
	if _syncing_selection:
		return
	_syncing_selection = true
	var mapped := SelectionSync.channels_for_tracks(project, tracks, active)
	mixer.set_selection_silent(mapped["channels"], mapped["focused"])
	_syncing_selection = false


## Mirror mixer channel selection onto the arranger (and DeviceLane / record-arm through it).
func _on_mixer_selection_changed(channels: Array[Channel]) -> void:
	if _syncing_selection:
		return
	_syncing_selection = true
	var active_channel: Channel = channels.back() if not channels.is_empty() else null
	var mapped := SelectionSync.tracks_for_channels(project, channels, active_channel)
	(arranger.track_list as TrackList).set_selection_silent(mapped["tracks"], mapped["active"])
	if mapped["active"]:
		set_track_selection(mapped["tracks"], mapped["active"], false)
	_syncing_selection = false


func _on_mixer_channel_focused(channel : Channel):
	focus_channel(channel)


func focus_channel(channel: Channel) -> void:
	"""Public API to focus a channel and notify listeners (e.g., DeviceLane)."""
	if focused_channel != channel:
		focused_channel = channel
		channel_focused.emit(channel)


## Set arranger track selection. The last selected track is active and drives DeviceLane.
func set_track_selection(tracks: Array[Track], active: Track, apply_record_arm: bool = true) -> void:
	selected_tracks.clear()
	for t in tracks:
		if t and not selected_tracks.has(t):
			selected_tracks.append(t)
	tracks_selected.emit(selected_tracks)
	focus_track(active, apply_record_arm)


## Focus the active track, bind DeviceLane to its channel, and optionally follow record-arm.
func focus_track(track: Track, apply_record_arm: bool = true) -> void:
	var changed := focused_track != track
	if changed:
		focused_track = track
		track_focused.emit(track)
	if apply_record_arm:
		_apply_record_arm_follows_active()
	if track == null or project == null:
		return
	if track.default_channel_id < 0:
		return
	var ch := project.get_channel_by_id(track.default_channel_id)
	if ch:
		focus_channel(ch)


## Record-arm only the active track when the follow-active setting is on.
func _apply_record_arm_follows_active() -> void:
	if Settings == null:
		return
	if not Settings.get_value("arranger/record_arm_follows_active_track"):
		return
	if project == null or focused_track == null:
		return
	if not focused_track.has_clips():
		return
	for t in project.tracks:
		if not t.has_clips():
			continue
		t.set_armed(t == focused_track)


## React to live setting changes, applying record-arm follow immediately when enabled.
func _on_setting_changed(key: String, _value) -> void:
	if key == "arranger/record_arm_follows_active_track":
		_apply_record_arm_follows_active()


func _connect_audio_engine_signals():
	"""Connect to audio engine OSC signals."""
	if AudioEngineOSC:
		# Listen for transport updates
		AudioEngineOSC.listen("/status/playhead", _on_playhead_received)
		AudioEngineOSC.listen("/status/playing", _on_playing_received)
		AudioEngineOSC.engine_connected.connect(_on_audio_engine_connected)
		logger.info("[Editor] Connected to audio engine OSC signals")
	# The engine couldn't use the saved audio settings (device missing, rate unsupported).
	AudioConfig.notice_raised.connect(_on_audio_notice)


func _on_audio_notice(text: String) -> void:
	show_error("Audio output", text + "\n\nChange it in Settings › Audio › Output.")

func _unhandled_input(event: InputEvent) -> void:
	"""Handle input actions."""
	if Hotkeys.pressed(event, "edit_undo"):
		undo()
		accept_event()
		return
	if Hotkeys.pressed(event, "edit_redo"):
		redo()
		accept_event()
		return

	if _handle_transport_hotkey(event):
		accept_event()
		return
	if Hotkeys.pressed(event, "switch_extra_view"):
		switch_extra_view()
		accept_event()
	elif Hotkeys.pressed(event, "switch_view"):
		switch_view()
		accept_event()

	if Hotkeys.pressed(event, "toggle_device_lane"):
		toggle_device_lane()
		accept_event()
	elif Hotkeys.pressed(event, "toggle_assistant"):
		toggle_assistant()
		accept_event()
	elif Hotkeys.pressed(event, "toggle_device_frame"):
		toggle_device_frame()
		accept_event()


# ============================================================================
# PROJECT MANAGEMENT
# ============================================================================
func open_project(p: Project, path: String = "") -> void:
	"""Open a project and connect it to audio engine. `path` is the file it was loaded from."""
	if project != null:
		close_project()

	project = p
	project_path = path
	is_modified = false
	history.clear()

	if not project.tempo_map.changed.is_connected(_update_transport_ui):
		project.tempo_map.changed.connect(_update_transport_ui)
	if not project.time_signature_map.changed.is_connected(_update_transport_ui):
		project.time_signature_map.changed.connect(_update_transport_ui)
	if not project.loop_changed.is_connected(_on_loop_changed):
		project.loop_changed.connect(_on_loop_changed)
	if not project.loop_follow_changed.is_connected(_on_loop_follow_changed):
		project.loop_follow_changed.connect(_on_loop_follow_changed)

	# Update UI state
	_update_transport_ui()
	_update_loop_button()

	# Emit project opened/activated signals for UI
	project_opened.emit(project)
	project_activated.emit(project)

	# Connect to audio engine after ensuring AudioEngineOSC is ready
	if AudioEngineOSC:
		_connect_project_to_engine.call_deferred()

	logger.info("[Editor] Project opened: ", project.project_name)


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
		logger.warn("[Editor] Closing modified project without saving")

	# Device frames and plugin windows belong to the project's devices
	DeviceWindowManager.close_all()

	# Disconnect from audio engine
	project.disconnect_from_engine()
	if project.tempo_map.changed.is_connected(_update_transport_ui):
		project.tempo_map.changed.disconnect(_update_transport_ui)
	if project.time_signature_map.changed.is_connected(_update_transport_ui):
		project.time_signature_map.changed.disconnect(_update_transport_ui)
	if project.loop_changed.is_connected(_on_loop_changed):
		project.loop_changed.disconnect(_on_loop_changed)
	if project.loop_follow_changed.is_connected(_on_loop_follow_changed):
		project.loop_follow_changed.disconnect(_on_loop_follow_changed)

	project = null
	project_path = ""
	is_modified = false
	playhead_ticks = 0
	_reset_playhead_interpolation(0)
	is_playing = false
	history.clear()
	focused_track = null
	selected_tracks.clear()

	project_closed.emit()
	logger.info("[Editor] Project closed")

## Stores the open project as the startup project and keeps it open from there.
func save_startup_project() -> bool:
	Sonara._ensure_config_dir()
	return await save_project(Sonara.get_startup_project_path(), true)

func save_project(path: String = "", allow_startup: bool = false) -> bool:
	"""Save the current project to a file. The startup project is only written by save_startup_project()."""
	if project == null:
		push_error("[Editor] Cannot save: No project open")
		return false
	
	# Use provided path or existing path
	var save_path = path if path != "" else project_path
	
	if Sonara.is_startup_project_path(save_path) and not allow_startup:
		show_error("Startup project is protected",
			"This is the startup project and can't be overwritten. Use Save As to save a copy, or Save as Startup Project to replace it.")
		return false
	
	if save_path == "":
		push_error("[Editor] Cannot save: No file path specified")
		return false
	
	# CLAP plugins hold state the engine has to fetch first
	await project.refresh_plugin_states()
	if project == null:
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

	if not Sonara.is_startup_project_path(save_path):
		Sonara.add_recent_project(save_path)
	project_saved.emit(save_path)
	logger.info("[Editor] Project saved: ", save_path)
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
	
	open_project(loaded_project, path)
	if not Sonara.is_startup_project_path(path):
		Sonara.add_recent_project(path)
	logger.info("[Editor] Project loaded: ", path)
	return true

## Exports the open project to a `.dawproject`. Shows the transfer report when it isn't empty and
## an error dialog on failure.
func export_dawproject(path: String) -> bool:
	if project == null:
		return false
	var result: Dictionary = await DawProjectExporter.new().export_project(project, path)
	if not result.ok:
		logger.error("[Editor] DAWproject export failed: ", result.error)
		transfer_report_dialog.show_error("Export failed", result.error)
		return false
	logger.info("[Editor] DAWproject exported: ", path)
	if not result.report.is_empty():
		transfer_report_dialog.show_report("Export report", result.report)
	return true


## Imports a `.dawproject` as a new unsaved project. On failure the open project is left alone
## and an error dialog is shown, except when `audio_dir_failed` is set: the caller then asks for
## another folder and calls again with `audio_dir`. Returns the importer's result dictionary.
func import_dawproject(path: String, audio_dir: String = "") -> Dictionary:
	var result: Dictionary = DawProjectImporter.new().import_file(path, audio_dir)
	if not result.ok:
		if not result.audio_dir_failed:
			logger.error("[Editor] DAWproject import failed: ", result.error)
			transfer_report_dialog.show_error("Import failed", result.error)
		return result
	var imported := Project.from_json(result.project_json)
	if imported == null:
		result.ok = false
		result.error = "The imported project could not be created"
		transfer_report_dialog.show_error("Import failed", result.error)
		return result
	open_project(imported, "")
	logger.info("[Editor] DAWproject imported: ", path)
	if not result.report.is_empty():
		transfer_report_dialog.show_report("Import report", result.report)
	return result

# Note: Track and Channel management now done via Project methods
# UI components should call project.create_track(), channel.set_volume(), etc.

# ============================================================================
# TRANSPORT CONTROL
# ============================================================================

func is_rendering() -> bool:
	return render_service != null and render_service.is_running


## Opens the export audio dialog for the open project.
func show_export_audio_dialog() -> void:
	if project == null:
		return
	export_audio_dialog.open_for(project, render_service, get_time_range())


## The engine silences live output and ignores the transport during a render, so grey the controls.
func _on_render_running_changed(running: bool) -> void:
	play_button.disabled = running
	stop_button.disabled = running


func play() -> void:
	"""Start playback from current playhead position."""
	if is_playing or is_rendering():
		return

	# Send play command to audio engine (it will update our state)
	AudioEngineOSC.send("/transport/play", [])
	logger.info("[Editor] Play command sent to audio engine")


func pause() -> void:
	"""Pause playback (stops playing but keeps playhead position)."""
	if is_rendering():
		return
	# Send pause command to audio engine (it will update our state)
	AudioEngineOSC.send("/transport/pause", [])
	logger.info("[Editor] Pause command sent to audio engine")


## Move the playhead to the project's start position and play.
func play_from_start_position() -> void:
	if is_rendering():
		return
	set_playhead(project.start_position_ticks if project else 0)
	if is_playing:
		return
	play()


## Pause (if playing) and move the playhead to the start position.
func pause_to_start_position() -> void:
	if is_rendering():
		return
	if is_playing:
		pause()
	set_playhead(project.start_position_ticks if project else 0)


## Pause (if playing), reset the start position to bar 0 and move the playhead there.
func pause_to_origin() -> void:
	if is_rendering():
		return
	if is_playing:
		pause()
	if project:
		project.set_start_position(0)
	set_playhead(0)


## The Stop action. While playing it stops at the start position. While stopped each call goes
## one step further (see TransportCycle).
func stop_cycle() -> void:
	if is_rendering():
		return
	if is_playing:
		pause()
		set_playhead(project.start_position_ticks if project else 0)
		return
	if project == null:
		set_playhead(0)
		return
	var marker_starts: Array = project.markers.map(func(m: SongMarker): return m.start_ticks)
	var step := TransportCycle.next_step(playhead_ticks, project.start_position_ticks, marker_starts)
	if step.start != project.start_position_ticks:
		project.set_start_position(step.start)
	if step.playhead != playhead_ticks:
		set_playhead(step.playhead)


## Stop button and Ctrl+Space share this.
func stop() -> void:
	stop_cycle()


## Turn looping on or off. With no loop region yet, the arranger's time-range selection
## becomes the region. Without a usable selection looping stays off.
func toggle_loop() -> void:
	if project == null:
		return
	if project.loop_enabled:
		project.set_loop_enabled(false)
		return
	if not project.has_loop_region() and not _set_loop_from_selection():
		logger.info("[Editor] Loop: select a time range first (Ctrl+drag on the ruler)")
		_update_loop_button()
		return
	project.set_loop_enabled(true)


## True when the arranger has a time range with both a start and an end.
func has_loop_selection() -> bool:
	var r := get_time_range()
	return r.has and r.has_end and r.end > r.start


## Make the selected time range the loop region and turn looping on.
func loop_selected_region() -> void:
	if project == null or not _set_loop_from_selection():
		return
	project.set_loop_enabled(true)


## Copy the selected time range into the loop region. Returns false without a usable selection.
func _set_loop_from_selection() -> bool:
	if project == null or not has_loop_selection():
		return false
	var r := get_time_range()
	project.set_loop_region(r.start, r.end)
	return true


## Called whenever the arranger's time range changes: with the follow toggle on, the loop
## region tracks the selection. Loop on/off is never touched, and no selection leaves it alone.
func sync_loop_to_selection() -> void:
	if project and project.loop_follows_selection:
		_set_loop_from_selection()


## Run the transport action matching `event`. Returns true when one handled it.
func _handle_transport_hotkey(event: InputEvent) -> bool:
	if Hotkeys.pressed(event, "transport_pause") and is_playing:
		pause()
	elif Hotkeys.pressed(event, "transport_play") and not is_playing:
		play()
	elif Hotkeys.pressed(event, "transport_play_from_start"):
		play_from_start_position()
	elif Hotkeys.pressed(event, "transport_pause_to_start"):
		pause_to_start_position()
	elif Hotkeys.pressed(event, "transport_pause_to_origin"):
		pause_to_origin()
	elif Hotkeys.pressed(event, "transport_stop_cycle"):
		stop_cycle()
	elif Hotkeys.pressed(event, "transport_loop_toggle"):
		toggle_loop()
	else:
		return false
	return true


## `{has: bool, start: int, has_end: bool, end: int}` — the arranger's active time-range
## selection, so AI tools don't reach into the arranger directly. "No range" in test mode
## or when there's no arranger yet. See `test_time_range_override` for faking this in tests.
func get_time_range() -> Dictionary:
	if not test_time_range_override.is_empty():
		return test_time_range_override
	var none := {"has": false, "start": 0, "has_end": false, "end": 0}
	if Utils.is_test_mode() or arranger == null or arranger.timeline == null:
		return none
	var csm := arranger.timeline.clip_selection_manager
	if csm == null or not csm.has_range():
		return none
	return {"has": true, "start": csm.range_start_tick, "has_end": csm.range_has_end, "end": csm.range_end_tick}


func set_playhead(ticks: int) -> void:
	"""Set playhead position."""
	if is_rendering():
		return
	# Send seek command to audio engine
	AudioEngineOSC.send("/transport/seek", [ticks])
	# Update both local and engine playhead immediately to avoid desync
	playhead_ticks = ticks
	audio_engine_playhead = ticks
	_reset_playhead_interpolation(ticks)
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

	var old_value := [project.time_numerator, project.time_denominator]
	var new_value := [numerator, denominator]
	if old_value == new_value:
		return

	_apply_time_signature_silent(new_value)

	var cmd := PropertyCommand.new("Set Time Signature", self, "", old_value, new_value)
	cmd.set_callable(func(v): _apply_time_signature_silent(v))
	record_command(cmd)


## Apply time signature without pushing history (used by undo/redo PropertyCommand).
func _apply_time_signature_silent(value: Array) -> void:
	if project == null:
		return
	var numerator: int = value[0]
	var denominator: int = value[1]

	project.time_numerator = numerator
	project.time_denominator = denominator

	# Sync to audio engine if connected
	if project.is_connected_to_engine():
		AudioEngineOSC.send("/transport/time_signature", [numerator, denominator])

	_mark_modified()
	_update_transport_ui()
	time_signature_changed.emit(numerator, denominator)


## Set the project scale (undoable). UI state only: nothing goes to the engine.
func set_project_scale(root: int, type_id: String) -> void:
	if project == null:
		return
	var old_value := [project.scale_root, project.scale_type]
	var new_value := [root, type_id]
	if old_value == new_value:
		return

	_apply_scale_silent(new_value)

	var cmd := PropertyCommand.new("Set Scale", self, "", old_value, new_value)
	cmd.set_callable(func(v): _apply_scale_silent(v))
	record_command(cmd)


## Apply the scale without pushing history (used by undo/redo PropertyCommand).
func _apply_scale_silent(value: Array) -> void:
	if project == null:
		return
	project.set_scale(value[0], value[1])
	_mark_modified()
	_update_transport_ui()


# ============================================================================
# VIEW MANAGEMENT
# ============================================================================

## Show `target` (ARRANGER, MIXER or EDITOR) in the Primary area. An attached device
## frame comes back when `target` is the view it belongs to, as in switch_view().
func set_view(target: View) -> void:
	var base := _view_before_device if current_view == View.DEVICE else current_view
	if target == base and (current_view != View.DEVICE or target == _frame_view):
		# Already showing it; re-sync the buttons in case the press toggled them.
		_update_view_buttons()
		return
	if attached_frame and _frame_view == target:
		_view_before_device = target
		current_view = View.DEVICE
	else:
		current_view = target
	_update_view_visibility()
	logger.info("[Editor] Switched to ", View.keys()[current_view], " view")


func switch_view() -> void:
	"""Toggle between arranger and mixer views."""
	var base := _view_before_device if current_view == View.DEVICE else current_view
	var target := View.MIXER if base == View.ARRANGER else View.ARRANGER
	if attached_frame and _frame_view == target:
		_view_before_device = target
		current_view = View.DEVICE
	else:
		current_view = target

	_update_view_visibility()
	logger.info("[Editor] Switched to ", View.keys()[current_view], " view")


func switch_extra_view() -> void:
	"""Toggle between aranger/mixer and Clip Editor"""
	if current_view == View.EDITOR:
		current_view = View.ARRANGER
	else:
		current_view = View.EDITOR
	
	_update_view_visibility()
	logger.info("[Editor] Switched to ", View.keys()[current_view], " view")


## Switch to the clip editor, which binds the current clip selection when shown.
func show_clip_editor() -> void:
	if current_view == View.EDITOR:
		return
	current_view = View.EDITOR
	_update_view_visibility()


## Put a device frame in the Primary area and show it (DeviceWindowManager.attach).
## The manager detaches any previous frame first (one attached frame, REQ-007).
func attach_frame(frame: DeviceFrame) -> void:
	attached_frame = frame
	if frame.get_parent():
		frame.get_parent().remove_child(frame)
	primary_panel.add_child(frame)
	show_attached_frame()


## Take the attached frame out of the Primary area and return to the view shown before it.
func detach_frame(frame: DeviceFrame) -> void:
	if frame != attached_frame:
		return
	attached_frame = null
	if frame.get_parent() == primary_panel:
		primary_panel.remove_child(frame)
	if current_view == View.DEVICE:
		current_view = _view_before_device
		_update_view_visibility()


## Switch the Primary area to the attached frame (REQ-006).
func show_attached_frame() -> void:
	if attached_frame == null or current_view == View.DEVICE:
		return
	_view_before_device = current_view
	_frame_view = current_view
	current_view = View.DEVICE
	_update_view_visibility()


## Show or hide the attached frame; it keeps its state while hidden (REQ-006).
func toggle_device_frame() -> void:
	if attached_frame == null:
		logger.info("[Editor] No device frame is attached")
		return
	if current_view == View.DEVICE:
		current_view = _view_before_device
		_update_view_visibility()
	else:
		show_attached_frame()


## Show or hide the AI Chat dock panel without affecting other docked panels.
func toggle_assistant() -> void:
	if dock_host == null:
		return
	dock_host.toggle_panel_visible("assistant")
	logger.info("[Editor] Assistant %s" % ("shown" if dock_host.is_panel_visible("assistant") else "hidden"))


## Ensure the AI Chat panel is visible in a side dock.
func show_assistant() -> void:
	if dock_host:
		dock_host.set_panel_visible("assistant", true)


func toggle_device_lane():
	logger.info("toggglng device lane")
	if seconday_panel.visible and device_lane.visible:
		# hide device lane
		device_lane.hide()
		seconday_panel.hide()
	else:
		# show - fail if no channel is focused
		if focused_channel == null:
			logger.warn("[Editor] Cannot open device lane: no channel is focused")
			return
		
		device_lane.show()
		
		device_lane.bind_to_channel(focused_channel)
		
		if not seconday_panel.visible:
			seconday_panel.show()


# ============================================================================
# UI CALLBACKS
# ============================================================================

const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")
const LOOP_ICON := preload("res://assets/icons/repeat.svg")

const LOOP_FOLLOW_ICON := preload("res://assets/icons/link.svg")

var loop_button: Button
var loop_follow_button: Button


## Tooltips with the live hotkeys, the Loop toggle next to Stop, and the Play icon swap.
func _setup_transport_buttons() -> void:
	loop_button = Button.new()
	loop_button.name = "LoopButton"
	loop_button.toggle_mode = true
	loop_button.custom_minimum_size = Vector2(64, 0)
	loop_button.icon = LOOP_ICON
	loop_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loop_button.focus_mode = Control.FOCUS_NONE
	loop_button.theme_type_variation = &"LoopButton"
	stop_button.get_parent().add_child(loop_button)
	loop_button.toggled.connect(_on_loop_button_toggled)

	loop_follow_button = Button.new()
	loop_follow_button.name = "LoopFollowButton"
	loop_follow_button.toggle_mode = true
	loop_follow_button.custom_minimum_size = Vector2(40, 0)
	loop_follow_button.icon = LOOP_FOLLOW_ICON
	loop_follow_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loop_follow_button.focus_mode = Control.FOCUS_NONE
	loop_follow_button.theme_type_variation = &"LoopButton"
	stop_button.get_parent().add_child(loop_follow_button)
	loop_follow_button.toggled.connect(_on_loop_follow_toggled)
	play_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_update_play_button()
	_update_button_tooltips()
	Hotkeys.bindings_changed.connect(func(_ids): _update_button_tooltips())


func _update_button_tooltips() -> void:
	play_button.tooltip_text = "Play / pause (%s)" % _chord_text("transport_play")
	stop_button.tooltip_text = "Stop: back to the start position; press again to step to the nearest marker, then bar 0 (%s)" % _chord_text("transport_stop_cycle")
	loop_button.tooltip_text = "Loop playback (%s). With no loop region, select a time range first." % _chord_text("transport_loop_toggle")
	loop_follow_button.tooltip_text = "Loop region follows the selected time range (does not turn looping on or off)"


func _chord_text(action_id: String) -> String:
	var chords := Hotkeys.get_chords(action_id)
	return ", ".join(chords) if not chords.is_empty() else "unbound"


func _update_play_button() -> void:
	if play_button:
		play_button.icon = PAUSE_ICON if is_playing else PLAY_ICON


func _update_loop_button() -> void:
	if loop_button:
		loop_button.set_pressed_no_signal(project != null and project.loop_enabled)
	if loop_follow_button:
		loop_follow_button.set_pressed_no_signal(project != null and project.loop_follows_selection)


func _on_loop_follow_toggled(pressed: bool) -> void:
	if project:
		project.set_loop_follows_selection(pressed)
		sync_loop_to_selection()
	_update_loop_button()


func _on_loop_changed(_enabled: bool, _start: int, _end: int) -> void:
	_update_loop_button()


func _on_loop_follow_changed(_follows: bool) -> void:
	_update_loop_button()


func _on_loop_button_toggled(pressed: bool) -> void:
	if project and pressed != project.loop_enabled:
		toggle_loop()
	_update_loop_button()


func _on_play_toggled(pressed: bool) -> void:
	"""Play button toggled."""
	if pressed:
		play()
	else:
		pause()  # Use pause instead of stop to preserve playhead position

func _on_stop_pressed() -> void:
	"""Stop button pressed - the stop cycle."""
	stop_cycle()

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
	logger.info("[Editor] Clips selected: %d clips, multi_track=%s" % [clips.size(), multi_track])

	# Emit new multi-clip signal
	clips_selected.emit(clips, multi_track)

	if not clips.is_empty() and _clip_selection_selects_tracks():
		var tracks: Array[Track] = []
		for c in clips:
			if c.track and not tracks.has(c.track):
				tracks.append(c.track)
		if not tracks.is_empty():
			_select_track_externally(tracks, clips.back().track)


## Whether an arranger clip selection should also select its tracks. A range select
## (Ctrl/Cmd drag) only does so when `selection/range_select_selects_tracks` is on.
func _clip_selection_selects_tracks() -> bool:
	if arranger and arranger.timeline and arranger.timeline.clip_selection_manager:
		return arranger.timeline.clip_selection_manager.clip_selection_selects_tracks()
	return Settings.get_value("selection/track_follows_clip_selection")


## Handle a track pick in the MIDI editor's Track-Mode track list.
func _on_clip_editor_track_mode_track_selected(track: Track) -> void:
	if track == null or not Settings or not Settings.get_value("selection/track_follows_midi_editor_track_list"):
		return
	_select_track_externally([track] as Array[Track], track)


## Apply a track selection that originated outside the arranger track headers (clip selection,
## MIDI editor track list), keeping TrackList's visuals and Editor's selection state in sync
## without record-arming the track (mirrors _on_mixer_selection_changed).
func _select_track_externally(tracks: Array[Track], active: Track) -> void:
	if _syncing_selection:
		return
	_syncing_selection = true
	(arranger.track_list as TrackList).set_selection_silent(tracks, active)
	set_track_selection(tracks, active, false)
	_syncing_selection = false


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
		# With tempo automation the field shows the tempo at the playhead and is read-only
		var automated := not project.tempo_map.is_empty()
		tempo_spinbox.set_value_no_signal(
			project.tempo_map.get_bpm_at_tick(playhead_ticks, project.tempo) if automated else project.tempo)
		tempo_spinbox.editable = not automated
	
	# Update time signature
	if time_signature_edit:
		time_signature_edit.text = "%d/%d" % [project.time_numerator, project.time_denominator]
	if scale_picker:
		scale_picker.set_scale_display(project.scale_root, project.scale_type)
	
	# Update position display
	if transport_position_label and project:
		var bbt = project.time_signature_map.bbt_at_tick(playhead_ticks, project.time_numerator, project.time_denominator, project.ppq)
		transport_position_label.text = "%d.%d.%d.%03d" % [bbt.bar, bbt.beat, bbt.sixteenth, bbt.tick]
	
	# Update time display
	if transport_time_label and project:
		var seconds = ticks_to_seconds(playhead_ticks)
		var minutes = int(seconds / 60)
		var secs = int(seconds) % 60
		var ms = int((seconds - int(seconds)) * 1000)
		transport_time_label.text = "%02d:%02d.%03d" % [minutes, secs, ms]

func ticks_to_seconds(ticks: int) -> float:
	"""Convert ticks to seconds."""
	if project == null:
		return 0.0
	
	return project.tempo_map.seconds_at_tick(ticks, project.tempo, project.ppq)


## Highlight the button for the current view (the device frame counts as the view it replaced).
func _update_view_buttons() -> void:
	var base := _view_before_device if current_view == View.DEVICE else current_view
	arrange_button.set_pressed_no_signal(base == View.ARRANGER)
	mix_button.set_pressed_no_signal(base == View.MIXER)
	edit_button.set_pressed_no_signal(base == View.EDITOR)


func _update_view_visibility() -> void:
	"""Update visibility of arranger and mixer based on current view."""
	arranger.visible = (current_view == View.ARRANGER)
	mixer.visible = (current_view == View.MIXER)
	clip_editor.visible = (current_view == View.EDITOR)
	if attached_frame:
		attached_frame.visible = (current_view == View.DEVICE)
	_update_view_buttons()
	view_changed.emit(current_view)

	if clip_editor.visible:
		clip_editor.call_deferred("grab_focus")
	elif arranger.visible:
		arranger.call_deferred("grab_focus")
	elif mixer.visible:
		mixer.call_deferred("grab_focus")


func _process(delta: float) -> void:
	"""Advance the visual playhead smoothly between engine updates."""
	if not is_playing or project == null:
		return

	# Free-run at tempo rate. `_playhead_precise` is a float, so no fractional ticks are
	# lost per frame the way integer truncation used to lose them.
	var bpm := project.tempo_map.get_bpm_at_tick(_playhead_precise, project.tempo)
	var ticks_per_second := (bpm * project.ppq) / 60.0
	_playhead_precise += ticks_per_second * delta

	# Bleed off whatever phase error the last engine update reported, spread over time
	# rather than applied in one frame.
	if not is_zero_approx(_playhead_error):
		var step: float = _playhead_error * clampf(PLAYHEAD_CORRECTION_RATE * delta, 0.0, 1.0)
		_playhead_precise += step
		_playhead_error -= step

	var ticks := int(_playhead_precise)
	if ticks == playhead_ticks:
		return
	playhead_ticks = ticks
	playhead_moved.emit(playhead_ticks)
	_update_transport_ui()


## Snap the visual playhead to `ticks`, discarding any in-flight phase correction.
## Used for seeks, stops and loop wraps, where interpolating would be wrong.
func _reset_playhead_interpolation(ticks: int) -> void:
	_playhead_precise = float(ticks)
	_playhead_error = 0.0


# ============================================================================
# AUDIO ENGINE CALLBACKS
# ============================================================================

func _on_audio_engine_connected() -> void:
	"""Called when audio engine connection is established."""
	logger.info("[Editor] Audio engine connected (project connection state: %s)" % (
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
		logger.warn("[Editor] Unexpected playhead format: ", values)
		return

	audio_engine_playhead = tick_value

	# Reset to 0 (stop), or any update while stopped: _process() is disabled, so apply it
	# directly and re-seed the interpolator.
	if tick_value == 0 or not is_playing:
		_reset_playhead_interpolation(tick_value)
		playhead_ticks = tick_value
		playhead_moved.emit(playhead_ticks)
		_update_transport_ui()
		return

	# Playing: record how far the free-running clock has drifted from the engine.
	# _process() applies the correction gradually; a large disagreement (seek, loop wrap,
	# tempo change) snaps instead.
	var error := float(tick_value) - _playhead_precise
	var snap_threshold := float(project.ppq) * PLAYHEAD_SNAP_BEAT_FRACTION if project else 240.0
	if absf(error) > snap_threshold:
		_reset_playhead_interpolation(tick_value)
	else:
		_playhead_error = error


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
			_update_play_button()

		# Emit signals
		if playing:
			# Seed the interpolator from the current position before _process() takes over.
			_reset_playhead_interpolation(playhead_ticks)
			playback_started.emit()
			set_process(true)
			logger.info("[Editor] Playback started (from engine)")
		else:
			playback_stopped.emit()
			set_process(false)
			logger.info("[Editor] Playback stopped (from engine)")


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
