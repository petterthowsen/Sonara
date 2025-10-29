class_name SendsPanel extends PanelContainer

## SendsPanel - Manages send controls for a channel
##
## Dynamically generates rotary knobs for each BUS channel in the project,
## allowing the user to send audio from the bound channel to those buses.
## Handles all send-related UI interactions and syncs with the Channel data model.

@onready var flow_container: FlowContainer = $FlowContainer

# Data binding
var channel: Channel = null
var project: Project = null

# Track signal connections to bus channels for cleanup
var _bus_signal_connections: Dictionary = {}  # bus_id -> Callable


func _ready() -> void:
	# Wait for binding
	pass


func bind_to_channel(ch: Channel, proj: Project) -> void:
	"""Bind this panel to a Channel and Project."""
	# Disconnect from old channel if any
	if channel:
		channel.send_added.disconnect(_on_channel_send_added)
		channel.send_removed.disconnect(_on_channel_send_removed)
		channel.send_changed.disconnect(_on_channel_send_changed)
	
	channel = ch
	project = proj
	
	# Connect to channel send signals
	if channel:
		channel.send_added.connect(_on_channel_send_added)
		channel.send_removed.connect(_on_channel_send_removed)
		channel.send_changed.connect(_on_channel_send_changed)
	
	# Build initial UI
	_rebuild_sends_ui()


func _on_channel_send_added(_target_channel_id: int, _send_config: SendConfig) -> void:
	"""React to send added to channel."""
	_rebuild_sends_ui()


func _on_channel_send_removed(_target_channel_id: int) -> void:
	"""React to send removed from channel."""
	_rebuild_sends_ui()


func _on_channel_send_changed(target_channel_id: int, send_config: SendConfig) -> void:
	"""React to send parameter changed."""
	# Update the specific send control (find it by target_channel_id and update knob value)
	for control in flow_container.get_children():
		if control.has_meta("target_channel_id") and control.get_meta("target_channel_id") == target_channel_id:
			var knob = control.get_node_or_null("RotaryKnob")
			if knob:
				knob.set_value_no_signal(_db_to_normalized(send_config.amount))
			
			# Update label opacity based on send amount
			var label = control.get_node_or_null("Label")
			if label:
				label.modulate.a = 0.5 if send_config.amount <= -60.0 else 1.0


func _on_bus_name_changed(bus_id: int, new_name: String) -> void:
	"""React to a bus channel name change - update the label in the send control."""
	if not flow_container:
		return
	
	# Find the send control for this bus and update its label
	for control in flow_container.get_children():
		if control.has_meta("target_channel_id") and control.get_meta("target_channel_id") == bus_id:
			var label = control.get_node_or_null("Label")
			if label:
				label.text = new_name
			break


func _rebuild_sends_ui() -> void:
	"""Rebuild the sends UI based on available BUS channels."""
	if not channel or not project or not flow_container:
		print("[SendsPanel] Cannot rebuild: channel=%s project=%s flow_container=%s" % [channel != null, project != null, flow_container != null])
		return
	
	# Disconnect from all bus channels we were listening to
	for bus_id in _bus_signal_connections.keys():
		var bus_ch = project.get_channel_by_id(bus_id)
		if bus_ch and _bus_signal_connections[bus_id]:
			bus_ch.name_changed.disconnect(_bus_signal_connections[bus_id])
	_bus_signal_connections.clear()
	
	# Clear existing send controls
	for child in flow_container.get_children():
		child.queue_free()
	
	# Create send controls for each BUS channel (excluding self)
	var bus_channels = []
	for ch in project.channels:
		if ch.channel_type == Channel.ChannelType.BUS and ch.id != channel.id:
			bus_channels.append(ch)
	
	print("[SendsPanel] Rebuild for channel %d (%s): Found %d bus channels" % [channel.id, Channel.ChannelType.keys()[channel.channel_type], bus_channels.size()])
	
	for bus_ch in bus_channels:
		var send_config = channel.get_send(bus_ch.id)
		_create_send_control(bus_ch, send_config)
		print("[SendsPanel]   - Created send control for bus %d (%s)" % [bus_ch.id, bus_ch.name])


func _create_send_control(bus_channel: Channel, send_config: SendConfig) -> void:
	"""Create a send control UI element for a BUS channel."""
	# Create container for this send
	var send_control = VBoxContainer.new()
	send_control.set_meta("target_channel_id", bus_channel.id)
	
	# Create rotary knob
	var knob = RotaryKnob.new()
	knob.custom_minimum_size = Vector2(32, 32)
	knob.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	knob.knob_color = Color(0.26171875, 0.26171875, 0.26171875)
	knob.shadow_color = Color(0, 0, 0, 0.47843137)
	knob.min_rotation_deg = -140.0
	knob.max_rotation_deg = 140.0
	
	# Set knob value from send config (or default)
	if send_config:
		knob.value = _db_to_normalized(send_config.amount)
	else:
		knob.value = _db_to_normalized(-60.0)  # Default muted
	
	# Connect knob value changed
	knob.value_changed.connect(_on_send_knob_changed.bind(bus_channel.id))
	
	# Add right-click menu for send options
	knob.gui_input.connect(_on_send_knob_gui_input.bind(bus_channel.id, knob))
	
	send_control.add_child(knob)
	
	# Create label showing bus channel name
	var label = Label.new()
	label.text = bus_channel.name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	
	# Dim the label if send amount is effectively 0 (muted)
	var send_amount = send_config.amount if send_config else -60.0
	label.modulate.a = 0.5 if send_amount <= -60.0 else 1.0
	
	send_control.add_child(label)
	
	# Connect to bus channel's name_changed signal to update the label
	var name_changed_callback = func(new_name: String) -> void:
		_on_bus_name_changed(bus_channel.id, new_name)
	bus_channel.name_changed.connect(name_changed_callback)
	_bus_signal_connections[bus_channel.id] = name_changed_callback
	
	flow_container.add_child(send_control)


func _on_send_knob_changed(value: float, target_channel_id: int) -> void:
	"""Handle send knob value changed."""
	if not channel:
		return
	
	var amount_db = _normalized_to_db(value)
	
	# Update label opacity in real-time as user adjusts the knob
	for control in flow_container.get_children():
		if control.has_meta("target_channel_id") and control.get_meta("target_channel_id") == target_channel_id:
			var label = control.get_node_or_null("Label")
			if label:
				label.modulate.a = 0.5 if amount_db <= -60.0 else 1.0
			break
	
	# If send doesn't exist, create it
	var send_config = channel.get_send(target_channel_id)
	if not send_config:
		channel.add_send(target_channel_id, amount_db, false)
	else:
		channel.set_send_amount(target_channel_id, amount_db)


func _on_send_knob_gui_input(event: InputEvent, target_channel_id: int, _knob: Control) -> void:
	"""Handle right-click on send knob to show options menu."""
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.is_pressed():
		# TODO: Show context menu with options:
		# - Remove send
		# - Pre/post fader toggle
		# - Mute send
		var send_config = channel.get_send(target_channel_id)
		if send_config:
			print("[SendsPanel] Right-clicked send to channel %d (%.1f dB)" % [target_channel_id, send_config.amount])


func _db_to_normalized(db: float) -> float:
	"""Convert dB value (-60 to +12) to normalized 0-1 range."""
	return (db + 60.0) / 72.0


func _normalized_to_db(value: float) -> float:
	"""Convert normalized 0-1 range to dB value (-60 to +12)."""
	return value * 72.0 - 60.0
