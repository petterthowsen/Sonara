# Shows Engine Status, Performance Metrics
# and a connect/disconnect button
class_name EnginePanel extends PanelContainer

@onready var performance_text: RichTextLabel = $HBox/PerformanceText
@onready var status_label: Label = $HBox/StatusLabel
@onready var connect_button: Button = $HBox/ConnectButton
@onready var engine_load_graph: Graph = $HBox/EngineLoadGraph

## Last Time.get_ticks_msec() that received /status/engine_stats (0 = never).
var _last_engine_load_msec: int = 0
var _show_connected: bool = false
var _engine_status := EngineStatus.new()
const AUDIO_STALL_MSEC := 2000
## A counter shows in red for this long after it last went up.
const COUNTER_ALERT_MSEC := 5000
const COLOR_WARN := "#e0b050"
const COLOR_ALERT := "#e05a5a"

var _last_xruns: int = -1
var _last_lock_misses: int = -1
var _last_plugin_underruns: int = -1
var _xrun_msec: int = 0
var _lock_miss_msec: int = 0
var _plugin_underrun_msec: int = 0


func _ready() -> void:
	set_process(true)
	# Connect to button signal
	connect_button.pressed.connect(_on_connect_button_pressed)
	
	# Connect to editor signals
	Sonara.editor.project_opened.connect(_on_project_opened)
	Sonara.editor.project_closed.connect(_on_project_closed)
	
	_engine_status.engine_stats_received.connect(_on_engine_stats_received)
	performance_text.tooltip_text = (
		"Load: average processing time of the last 0.5 s, as % of the block time.\n"
		+ "Peak: worst single block in that interval (100% or more = missed deadline).\n"
		+ "Xruns: audio dropouts since the engine started.\n"
		+ "Lock misses: blocks output as silence because the engine state was busy.\n"
		+ "Plugin dropouts: plugin blocks padded with silence because the plugin was late.")
	_engine_status.start()
	
	# Initialize UI state (no project active)
	_update_ui_no_project()


func _on_project_opened(project: Project) -> void:
	"""Handle project opened event."""
	# Connect to project connection state signal
	project.connection_state_changed.connect(_on_connection_state_changed)
	
	# Update UI based on current connection state
	_update_ui_from_state(project.get_connection_state())


func _on_project_closed() -> void:
	"""Handle project closed event."""
	_update_ui_no_project()


func _on_connection_state_changed(state: Project.ConnectionState) -> void:
	"""Handle connection state change."""
	_update_ui_from_state(state)


func _on_connect_button_pressed() -> void:
	"""Handle connect/disconnect button press."""
	if not Sonara.editor.project:
		return
	
	var project = Sonara.editor.project
	
	if project.is_connected_to_engine():
		# Disconnect
		project.disconnect_from_engine()
	else:
		# Connect
		project.connect_to_engine()


func _update_ui_no_project() -> void:
	"""Update UI when no project is active."""
	status_label.text = "No Project"
	connect_button.text = "Connect"
	connect_button.disabled = true
	performance_text.text = ""
	_show_connected = false
	_last_engine_load_msec = 0


func _update_ui_from_state(state: Project.ConnectionState) -> void:
	"""Update UI based on connection state."""
	match state:
		Project.ConnectionState.DISCONNECTED:
			status_label.text = "Disconnected"
			connect_button.text = "Connect"
			connect_button.disabled = false
			_show_connected = false
			_last_engine_load_msec = 0
			_last_xruns = -1
			_last_lock_misses = -1
			_last_plugin_underruns = -1
			performance_text.text = ""
			if engine_load_graph:
				engine_load_graph.clear()
		Project.ConnectionState.CONNECTING:
			status_label.text = "Connecting..."
			connect_button.text = "Cancel"
			connect_button.disabled = false
			_show_connected = false
		Project.ConnectionState.CONNECTED:
			status_label.text = "Connected"
			connect_button.text = "Disconnect"
			connect_button.disabled = false
			_show_connected = true
			_last_engine_load_msec = Time.get_ticks_msec()


func _exit_tree() -> void:
	_engine_status.stop()


## Show a stall warning when OSC is up but the audio callback has gone quiet.
func _process(_delta: float) -> void:
	if not _show_connected:
		return
	if _last_engine_load_msec == 0:
		return
	if Time.get_ticks_msec() - _last_engine_load_msec > AUDIO_STALL_MSEC:
		performance_text.text = "Audio stalled (no callback)"


func _on_engine_stats_received(stats: EngineStatus.Stats) -> void:
	var now := Time.get_ticks_msec()
	_last_engine_load_msec = now
	# A drop in a running total means the engine restarted: start over.
	if (stats.xruns < _last_xruns or stats.lock_misses < _last_lock_misses
			or stats.plugin_underruns < _last_plugin_underruns):
		_last_xruns = -1
		_last_lock_misses = -1
		_last_plugin_underruns = -1
	if _last_xruns >= 0 and stats.xruns > _last_xruns:
		_xrun_msec = now
	if _last_lock_misses >= 0 and stats.lock_misses > _last_lock_misses:
		_lock_miss_msec = now
	if _last_plugin_underruns >= 0 and stats.plugin_underruns > _last_plugin_underruns:
		_plugin_underrun_msec = now
	_last_xruns = stats.xruns
	_last_lock_misses = stats.lock_misses
	_last_plugin_underruns = stats.plugin_underruns

	if engine_load_graph:
		engine_load_graph.add_point(stats.load_avg)

	var peak_text := "%.1f%%" % (stats.load_peak * 100.0)
	if stats.load_peak >= 1.0:
		peak_text = _colored(peak_text, COLOR_ALERT)
	elif stats.load_peak >= 0.8:
		peak_text = _colored(peak_text, COLOR_WARN)
	performance_text.text = "Load %.1f%%  Peak %s  Xruns %s  Lock misses %s  Plugin dropouts %s" % [
		stats.load_avg * 100.0,
		peak_text,
		_counter_text(stats.xruns, _xrun_msec, now),
		_counter_text(stats.lock_misses, _lock_miss_msec, now),
		_counter_text(stats.plugin_underruns, _plugin_underrun_msec, now),
	]


func _counter_text(count: int, last_increase_msec: int, now: int) -> String:
	if last_increase_msec > 0 and now - last_increase_msec < COUNTER_ALERT_MSEC:
		return _colored(str(count), COLOR_ALERT)
	return str(count)


func _colored(text: String, color: String) -> String:
	return "[color=%s]%s[/color]" % [color, text]
