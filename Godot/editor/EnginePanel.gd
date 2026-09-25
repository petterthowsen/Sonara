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
## Plugins listed in the tooltip, worst first. The panel itself names only the worst one, and
## only while it drops out or runs heavy.
const WORST_PLUGINS_IN_TOOLTIP := 10
## A plugin taking this share of the block time at its peak is shown as a warning.
const PLUGIN_PEAK_WARN := 0.5
const PERFORMANCE_TOOLTIP := (
		"Load: average processing time of the last 0.5 s, as % of the block time.\n"
		+ "Peak: worst single block in that interval (100% or more = missed deadline).\n"
		+ "Xruns: audio dropouts since the engine started.\n"
		+ "Lock misses: blocks output as silence because the engine state was busy.\n"
		+ "Plugin dropouts: plugin blocks padded with silence because the plugin was late.\n"
		+ "The panel shows these counters only once they are above zero, and names a plugin\n"
		+ "only while it drops out or takes 50% or more of a block (PLUGIN_PEAK_WARN).")

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
	performance_text.tooltip_text = PERFORMANCE_TOOLTIP
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
	var parts: PackedStringArray = ["Load %.1f%% (peak %s)" % [stats.load_avg * 100.0, peak_text]]
	# Problem counters only once they have something to say; the tooltip always has them.
	for counter in [["Xruns", stats.xruns, _xrun_msec],
			["Lock misses", stats.lock_misses, _lock_miss_msec],
			["Dropouts", stats.plugin_underruns, _plugin_underrun_msec]]:
		if counter[1] > 0:
			parts.append("%s %s" % [counter[0], _counter_text(counter[1], counter[2], now)])
	var project: Project = Sonara.editor.project if Sonara.editor else null
	var ranked := rank_plugins(collect_devices(project.channels if project else []), now,
			WORST_PLUGINS_IN_TOOLTIP)
	if not ranked.is_empty() and _is_plugin_notable(ranked[0]):
		parts.append(_plugin_text(ranked[0]))
	performance_text.text = "  ".join(parts)
	var totals := "\n\nXruns %d, lock misses %d, plugin dropouts %d since the engine started." % [
		stats.xruns, stats.lock_misses, stats.plugin_underruns]
	performance_text.tooltip_text = PERFORMANCE_TOOLTIP + totals + _plugins_tooltip(ranked)


## Every device instance in `channels`, including those nested in containers.
static func collect_devices(channels: Array) -> Array[DeviceInstance]:
	var result: Array[DeviceInstance] = []
	var stack: Array = []
	for channel in channels:
		stack.append_array(channel.devices)
	while not stack.is_empty():
		var dev: DeviceInstance = stack.pop_back()
		result.append(dev)
		stack.append_array(dev.children)
	return result


## Plugins with fresh stats, worst first: most dropouts in the last second, then highest peak
## share of the block time. At most `limit`.
static func rank_plugins(devices: Array[DeviceInstance], now_msec: int, limit: int) -> Array[DeviceInstance]:
	var ranked: Array[DeviceInstance] = []
	for dev in devices:
		var s: DeviceInstance.PluginStats = dev.plugin_stats
		if s != null and s.blocks > 0 and s.is_fresh(now_msec):
			ranked.append(dev)
	ranked.sort_custom(func(a: DeviceInstance, b: DeviceInstance) -> bool:
		if a.plugin_stats.deadline_misses != b.plugin_stats.deadline_misses:
			return a.plugin_stats.deadline_misses > b.plugin_stats.deadline_misses
		return a.plugin_stats.load_peak > b.plugin_stats.load_peak)
	return ranked.slice(0, limit)


## Worth naming in the panel: dropping out, or taking a large share of the block.
static func _is_plugin_notable(dev: DeviceInstance) -> bool:
	var s: DeviceInstance.PluginStats = dev.plugin_stats
	return s.deadline_misses > 0 or s.struggling or s.load_peak >= PLUGIN_PEAK_WARN


func _plugin_text(dev: DeviceInstance) -> String:
	var s: DeviceInstance.PluginStats = dev.plugin_stats
	var text := "%s %.0f%%" % [dev.get_display_name(), s.load_peak * 100.0]
	if s.deadline_misses > 0 or s.struggling:
		return _colored(text, COLOR_ALERT)
	if s.load_peak >= PLUGIN_PEAK_WARN:
		return _colored(text, COLOR_WARN)
	return text


func _plugins_tooltip(ranked: Array[DeviceInstance]) -> String:
	if ranked.is_empty():
		return ""
	var text := "\n"
	for dev in ranked:
		text += "\n%s (channel %d)\n%s\n" % [dev.get_display_name(), dev.channel_id, dev.plugin_stats.describe()]
	return text


func _counter_text(count: int, last_increase_msec: int, now: int) -> String:
	if last_increase_msec > 0 and now - last_increase_msec < COUNTER_ALERT_MSEC:
		return _colored(str(count), COLOR_ALERT)
	return str(count)


func _colored(text: String, color: String) -> String:
	return "[color=%s]%s[/color]" % [color, text]
