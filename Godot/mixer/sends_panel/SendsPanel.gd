class_name SendsPanel extends PanelContainer

var logger : Log = Log.make("SendsPanel")

## SendsPanel - Manages send controls for a channel
##
## Dynamically generates rotary knobs for each BUS channel in the project,
## allowing the user to send audio from the bound channel to those buses.
## Handles all send-related UI interactions and syncs with the Channel data model.

## One send slot: amount knob plus a label that tracks the target bus name.
class SendControl extends VBoxContainer:
	var target_channel_id: int = -1
	var knob: RotaryKnob
	var bus_label: Label


	## Build a send control for `target_id` showing `bus_name` and `normalized` amount.
	func _init(target_id: int, bus_name: String, normalized: float, dimmed: bool) -> void:
		target_channel_id = target_id
		set_meta("target_channel_id", target_id)

		knob = RotaryKnob.new()
		knob.name = "RotaryKnob"
		knob.custom_minimum_size = Vector2(32, 32)
		knob.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		knob.knob_color = Color(0.26171875, 0.26171875, 0.26171875)
		knob.shadow_color = Color(0, 0, 0, 0.47843137)
		knob.min_rotation_deg = -140.0
		knob.max_rotation_deg = 140.0
		# Set before anyone connects so the default 0.5 does not create a send.
		knob.value = normalized
		add_child(knob)

		bus_label = Label.new()
		bus_label.name = "Label"
		bus_label.text = bus_name
		bus_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bus_label.modulate.a = 0.5 if dimmed else 1.0
		add_child(bus_label)


	## Update the bus name shown under the knob.
	func set_bus_name(new_name: String) -> void:
		if bus_label:
			bus_label.text = new_name


	## Update knob position and label dimming from the data model.
	func set_amount_display(normalized: float, dimmed: bool) -> void:
		if knob:
			knob.set_value_no_signal(normalized)
		if bus_label:
			bus_label.modulate.a = 0.5 if dimmed else 1.0


@onready var flow_container: FlowContainer = $FlowContainer

# Data binding
var channel: Channel = null
var project: Project = null

# Track signal connections to bus channels for cleanup
var _bus_signal_connections: Dictionary = {}  # bus_id -> Callable


## Strip scene placeholders, then build sends if this panel was bound early.
func _ready() -> void:
	_clear_send_controls()
	if channel and project:
		_rebuild_sends_ui()


## Drop project, channel, and bus name listeners when the panel leaves the tree.
func _exit_tree() -> void:
	if channel:
		if channel.send_added.is_connected(_on_channel_send_added):
			channel.send_added.disconnect(_on_channel_send_added)
		if channel.send_removed.is_connected(_on_channel_send_removed):
			channel.send_removed.disconnect(_on_channel_send_removed)
		if channel.send_changed.is_connected(_on_channel_send_changed):
			channel.send_changed.disconnect(_on_channel_send_changed)
	_disconnect_project_signals()
	_disconnect_bus_name_signals()


## Bind this panel to a Channel and Project.
func bind_to_channel(ch: Channel, proj: Project) -> void:
	if channel:
		if channel.send_added.is_connected(_on_channel_send_added):
			channel.send_added.disconnect(_on_channel_send_added)
		if channel.send_removed.is_connected(_on_channel_send_removed):
			channel.send_removed.disconnect(_on_channel_send_removed)
		if channel.send_changed.is_connected(_on_channel_send_changed):
			channel.send_changed.disconnect(_on_channel_send_changed)

	_disconnect_project_signals()
	_disconnect_bus_name_signals()

	channel = ch
	project = proj

	if channel:
		channel.send_added.connect(_on_channel_send_added)
		channel.send_removed.connect(_on_channel_send_removed)
		channel.send_changed.connect(_on_channel_send_changed)

	_connect_project_signals()

	if is_node_ready():
		_rebuild_sends_ui()


## React to send added to channel. Keep the existing knob so a live drag is not freed.
func _on_channel_send_added(target_channel_id: int, send_config: SendConfig) -> void:
	var control := _find_send_control(target_channel_id)
	if control:
		control.set_amount_display(_db_to_normalized(send_config.amount), send_config.amount <= -60.0)
		return
	_rebuild_sends_ui()


## React to send removed from channel. Dim the existing knob instead of rebuilding.
func _on_channel_send_removed(target_channel_id: int) -> void:
	var control := _find_send_control(target_channel_id)
	if control:
		control.set_amount_display(_db_to_normalized(-60.0), true)
		return
	_rebuild_sends_ui()


## React to send parameter changed.
func _on_channel_send_changed(target_channel_id: int, send_config: SendConfig) -> void:
	var control := _find_send_control(target_channel_id)
	if control:
		control.set_amount_display(_db_to_normalized(send_config.amount), send_config.amount <= -60.0)


## Rebuild send knobs when a bus is added to the project.
func _on_project_channel_added(ch: Channel) -> void:
	if ch and ch.is_bus:
		_rebuild_sends_ui()


## Rebuild send knobs when a bus is removed from the project.
func _on_project_channel_removed(ch: Channel) -> void:
	if ch and ch.is_bus:
		_rebuild_sends_ui()


## Rebuild the sends UI based on available BUS channels.
func _rebuild_sends_ui() -> void:
	if not channel or not project or not flow_container:
		logger.warn("Cannot rebuild: channel=%s project=%s flow_container=%s" % [channel != null, project != null, flow_container != null])
		return

	_disconnect_bus_name_signals()
	_clear_send_controls()

	var bus_channels: Array[Channel] = []
	for ch in project.channels:
		if ch.channel_type == Channel.ChannelType.BUS and ch.id != channel.id:
			bus_channels.append(ch)

	logger.info("Rebuild for channel %d (%s): Found %d bus channels" % [channel.id, Channel.ChannelType.keys()[channel.channel_type], bus_channels.size()])

	for bus_ch in bus_channels:
		var send_config = channel.get_send(bus_ch.id)
		_create_send_control(bus_ch, send_config)


## Create a send control UI element for a BUS channel.
func _create_send_control(bus_channel: Channel, send_config: SendConfig) -> void:
	var send_amount: float = send_config.amount if send_config else -60.0
	var control := SendControl.new(
		bus_channel.id,
		bus_channel.name,
		_db_to_normalized(send_amount),
		send_amount <= -60.0
	)

	control.knob.value_changed.connect(_on_send_knob_changed.bind(bus_channel.id))
	control.knob.gui_input.connect(_on_send_knob_gui_input.bind(bus_channel.id, control.knob))

	var send_control := control
	var name_changed_callback := func(new_name: String) -> void:
		if is_instance_valid(send_control):
			send_control.set_bus_name(new_name)
	bus_channel.name_changed.connect(name_changed_callback)
	_bus_signal_connections[bus_channel.id] = name_changed_callback

	flow_container.add_child(control)


## Handle send knob value changed.
func _on_send_knob_changed(value: float, target_channel_id: int) -> void:
	if not channel:
		return

	var amount_db := _normalized_to_db(value)

	var control := _find_send_control(target_channel_id)
	if control and control.bus_label:
		control.bus_label.modulate.a = 0.5 if amount_db <= -60.0 else 1.0

	var send_config = channel.get_send(target_channel_id)
	if not send_config:
		channel.add_send(target_channel_id, amount_db, false)
	else:
		channel.set_send_amount(target_channel_id, amount_db)


## Handle right-click on send knob to show options menu.
func _on_send_knob_gui_input(event: InputEvent, target_channel_id: int, _knob: Control) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.is_pressed():
		# TODO: Show context menu with options:
		# - Remove send
		# - Pre/post fader toggle
		# - Mute send
		var send_config = channel.get_send(target_channel_id)
		if send_config:
			logger.info("Right-clicked send to channel %d (%.1f dB)" % [target_channel_id, send_config.amount])


## Convert dB value (-60 to +12) to normalized 0-1 range.
func _db_to_normalized(db: float) -> float:
	return (db + 60.0) / 72.0


## Convert normalized 0-1 range to dB value (-60 to +12).
func _normalized_to_db(value: float) -> float:
	return value * 72.0 - 60.0


## Find the live send control for a bus.
func _find_send_control(target_channel_id: int) -> SendControl:
	if not flow_container:
		return null
	for child in flow_container.get_children():
		if not is_instance_valid(child) or not child.has_method("set_bus_name"):
			continue
		if child.has_meta("target_channel_id") and int(child.get_meta("target_channel_id")) == target_channel_id:
			return child
	return null


## Immediately remove designer placeholders and previous send controls.
func _clear_send_controls() -> void:
	if not flow_container:
		return
	for child in flow_container.get_children():
		flow_container.remove_child(child)
		child.free()


## Listen for buses appearing or disappearing so send knobs stay in sync.
func _connect_project_signals() -> void:
	if not project:
		return
	if not project.channel_added.is_connected(_on_project_channel_added):
		project.channel_added.connect(_on_project_channel_added)
	if not project.channel_removed.is_connected(_on_project_channel_removed):
		project.channel_removed.connect(_on_project_channel_removed)


## Drop project-level listeners when rebinding or freeing.
func _disconnect_project_signals() -> void:
	if not project:
		return
	if project.channel_added.is_connected(_on_project_channel_added):
		project.channel_added.disconnect(_on_project_channel_added)
	if project.channel_removed.is_connected(_on_project_channel_removed):
		project.channel_removed.disconnect(_on_project_channel_removed)


## Disconnect name listeners from every bus this panel was watching.
func _disconnect_bus_name_signals() -> void:
	if not project:
		_bus_signal_connections.clear()
		return
	for bus_id in _bus_signal_connections.keys():
		var bus_ch = project.get_channel_by_id(bus_id)
		var cb: Callable = _bus_signal_connections[bus_id]
		if bus_ch and cb and bus_ch.name_changed.is_connected(cb):
			bus_ch.name_changed.disconnect(cb)
	_bus_signal_connections.clear()
