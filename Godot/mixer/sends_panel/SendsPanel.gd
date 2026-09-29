class_name SendsPanel extends PanelContainer

var logger : Log = Log.make("SendsPanel")

## SendsPanel - Manages send controls for a channel
##
## Dynamically generates rotary knobs for each BUS channel in the project,
## allowing the user to send audio from the bound channel to those buses.
## Handles all send-related UI interactions and syncs with the Channel data model.

## One send slot: amount knob plus a caption that tracks the target bus name.
## Long bus names end in an ellipsis so they never widen the strip; hovering shows the full name.
class SendControl extends LabeledKnob:
	## Arc color for pre-fader sends, so they stand out from the default post-fader ones.
	const PRE_FADER_ARC_COLOR := Color(0.35, 0.65, 1.0)

	var target_channel_id: int = -1
	var _post_fader_arc_color: Color
	var bus_label: Label:
		get: return label


	## Build a send control for `target_id` showing `bus_name` at `amount_db`.
	## The knob works in dB, so its tooltip and double-click entry are in dB too.
	func _init(target_id: int, bus_name: String, amount_db: float, dimmed: bool) -> void:
		super()
		target_channel_id = target_id
		set_meta("target_channel_id", target_id)

		knob.knob_color = Color(0.26171875, 0.26171875, 0.26171875)
		knob.shadow_color = Color(0, 0, 0, 0.47843137)
		knob.min_rotation_deg = -140.0
		knob.max_rotation_deg = 140.0
		knob.min_value = MIN_SEND_DB
		knob.max_value = MAX_SEND_DB
		knob.value_default = MIN_SEND_DB
		knob.value_format = "%.1f"
		knob.value_text_callback = SendsPanel.format_send_db
		# Set before anyone connects so the default value does not create a send.
		knob.value = amount_db

		text = bus_name
		label.modulate.a = 0.5 if dimmed else 1.0
		_post_fader_arc_color = knob.value_arc_color


	## Update the bus name shown under the knob.
	func set_bus_name(new_name: String) -> void:
		text = new_name


	## Update knob position and label dimming from the data model.
	func set_amount_display(amount_db: float, dimmed: bool) -> void:
		if knob:
			knob.set_value_no_signal(amount_db)
		if bus_label:
			bus_label.modulate.a = 0.5 if dimmed else 1.0


	## Color the knob arc by whether the send taps the signal before the fader.
	func set_pre_fader_display(pre_fader: bool) -> void:
		knob.value_arc_color = PRE_FADER_ARC_COLOR if pre_fader else _post_fader_arc_color
		knob.queue_redraw()


## Send level range in dB. The bottom of the range is silence (-inf).
const MIN_SEND_DB := -60.0
const MAX_SEND_DB := 12.0

@onready var flow_container: FlowContainer = $FlowContainer

# Data binding
var channel: Channel = null
var project: Project = null

# Track signal connections to bus channels for cleanup
var _bus_signal_connections: Dictionary = {}  # bus_id -> Callable

## Right-click menu for one send knob.
enum SendMenuItem { PRE_FADER }
var _send_menu: PopupMenu = null
var _menu_target_channel_id: int = -1


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
		control.set_amount_display(send_config.amount, send_config.amount <= MIN_SEND_DB)
		control.set_pre_fader_display(send_config.pre_fader)
		return
	_rebuild_sends_ui()


## React to send removed from channel. Dim the existing knob instead of rebuilding.
func _on_channel_send_removed(target_channel_id: int) -> void:
	var control := _find_send_control(target_channel_id)
	if control:
		control.set_amount_display(MIN_SEND_DB, true)
		control.set_pre_fader_display(false)
		return
	_rebuild_sends_ui()


## React to send parameter changed.
func _on_channel_send_changed(target_channel_id: int, send_config: SendConfig) -> void:
	var control := _find_send_control(target_channel_id)
	if control:
		control.set_amount_display(send_config.amount, send_config.amount <= MIN_SEND_DB)
		control.set_pre_fader_display(send_config.pre_fader)


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
	var send_amount: float = send_config.amount if send_config else MIN_SEND_DB
	var control := SendControl.new(
		bus_channel.id,
		bus_channel.name,
		send_amount,
		send_amount <= MIN_SEND_DB
	)
	control.set_pre_fader_display(send_config != null and send_config.pre_fader)

	var knob := control.knob
	var bus_id := bus_channel.id
	knob.value_changed.connect(func(value: float) -> void: _on_send_knob_changed(value, bus_id, knob.last_edit_kind))
	knob.reset_requested.connect(_on_send_knob_reset.bind(bus_id))
	control.knob.gui_input.connect(_on_send_knob_gui_input.bind(bus_channel.id, control.knob))

	var send_control := control
	var name_changed_callback := func(new_name: String) -> void:
		if is_instance_valid(send_control):
			send_control.set_bus_name(new_name)
	bus_channel.name_changed.connect(name_changed_callback)
	_bus_signal_connections[bus_channel.id] = name_changed_callback

	flow_container.add_child(control)


## Handle send knob value changed. With several channels selected the edit applies to all of
## their sends to this bus (see ChannelMultiEdit).
func _on_send_knob_changed(value: float, target_channel_id: int, kind := ValueEditKind.Kind.DRAG) -> void:
	if not channel:
		return

	var amount_db := value
	var old_db := ChannelMultiEdit.send_db(channel, target_channel_id)

	var control := _find_send_control(target_channel_id)
	if control and control.bus_label:
		control.bus_label.modulate.a = 0.5 if amount_db <= MIN_SEND_DB else 1.0

	var send_config = channel.get_send(target_channel_id)
	if not send_config:
		channel.add_send(target_channel_id, amount_db, false)
	else:
		channel.set_send_amount(target_channel_id, amount_db)

	var peers := ChannelMultiEdit.peers_of(channel, self)
	if not peers.is_empty():
		ChannelMultiEdit.apply_send(channel, target_channel_id, old_db, amount_db, peers, kind)


## Ctrl/Cmd-click on a send knob. With a multi-selection, every selected channel's send to this
## bus resets, even when this one already was (then value_changed never fired).
func _on_send_knob_reset(target_channel_id: int) -> void:
	if not channel:
		return
	var peers := ChannelMultiEdit.peers_of(channel, self)
	if peers.is_empty():
		return
	var old_db := ChannelMultiEdit.send_db(channel, target_channel_id)
	if channel.get_send(target_channel_id):
		channel.set_send_amount(target_channel_id, MIN_SEND_DB)
	ChannelMultiEdit.apply_send(channel, target_channel_id, old_db, MIN_SEND_DB, peers, ValueEditKind.Kind.RESET)


## Right-click on a send knob opens its options menu.
func _on_send_knob_gui_input(event: InputEvent, target_channel_id: int, _knob: Control) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.is_pressed():
		_show_send_menu(target_channel_id)
		accept_event()


## Show the options for the send to `target_channel_id` at the mouse.
## Pre-Fader is disabled until the send exists (its knob has been turned up).
func _show_send_menu(target_channel_id: int) -> void:
	if not channel:
		return
	if _send_menu == null:
		_send_menu = PopupMenu.new()
		_send_menu.add_check_item("Pre-Fader", SendMenuItem.PRE_FADER)
		_send_menu.id_pressed.connect(_on_send_menu_id_pressed)
		add_child(_send_menu)

	var send_config: SendConfig = channel.get_send(target_channel_id)
	var index := _send_menu.get_item_index(SendMenuItem.PRE_FADER)
	_send_menu.set_item_checked(index, send_config != null and send_config.pre_fader)
	_send_menu.set_item_disabled(index, send_config == null)
	_send_menu.set_item_tooltip(index, "" if send_config else "Turn the send up first")

	_menu_target_channel_id = target_channel_id
	_send_menu.popup(Rect2i(Vector2i(get_screen_position() + get_local_mouse_position()), Vector2i.ZERO))


func _on_send_menu_id_pressed(id: int) -> void:
	if id != SendMenuItem.PRE_FADER or not channel:
		return
	var send_config: SendConfig = channel.get_send(_menu_target_channel_id)
	if not send_config:
		return
	var target_id := _menu_target_channel_id
	var ch := channel
	var cmd := PropertyCommand.new(
		"Send Pre-Fader", ch, "", send_config.pre_fader, not send_config.pre_fader
	)
	cmd.set_callable(func(pre_fader: bool) -> void: ch.set_send_pre_fader(target_id, pre_fader))
	HistoryUtil.execute(cmd)


## Send level text for the knob tooltip: "-inf dB" at the bottom of the range.
static func format_send_db(amount_db: float) -> String:
	if amount_db <= MIN_SEND_DB:
		return "-inf dB"
	return "%.1f dB" % amount_db


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
