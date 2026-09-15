# Shows Engine Status, Performance Metrics
# and a connect/disconnect button
class_name EnginePanel extends PanelContainer

@onready var performance_text: RichTextLabel = $HBox/PerformanceText
@onready var status_label: Label = $HBox/StatusLabel
@onready var connect_button: Button = $HBox/ConnectButton
@onready var engine_load_graph: Graph = $HBox/EngineLoadGraph

## Last Time.get_ticks_msec() that received /status/engine_load (0 = never).
var _last_engine_load_msec: int = 0
var _show_connected: bool = false
var _engine_status := EngineStatus.new()
const AUDIO_STALL_MSEC := 2000


func _ready() -> void:
	set_process(true)
	# Connect to button signal
	connect_button.pressed.connect(_on_connect_button_pressed)
	
	# Connect to editor signals
	Sonara.editor.project_opened.connect(_on_project_opened)
	Sonara.editor.project_closed.connect(_on_project_closed)
	
	_engine_status.engine_load_received.connect(_on_engine_load_received)
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


func _on_engine_load_received(load_value: float) -> void:
	"""Handle engine load metric from audio engine."""
	_last_engine_load_msec = Time.get_ticks_msec()
	if engine_load_graph:
		engine_load_graph.add_point(load_value)
		performance_text.text = "Engine Load: %.2f%%" % (load_value * 100.0)
