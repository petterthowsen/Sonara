## Fold-out pane beside a mixer strip: parent-colored header plus nested MixerChannels.
class_name MixerChannelChildren extends PanelContainer

signal contents_changed

@onready var parent_header: Panel = $VBoxContainer/ParentHeader
@onready var channels_box: ChannelsBox = $VBoxContainer/ChildBox

var channel: Channel = null
var project: Project = null
var _host: MixerChannel = null
var _header_fill: StyleBoxFlat = null


## Forward nest drops onto the fold-out and keep nest_parent in sync.
func _ready() -> void:
	set_drag_forwarding(Callable(), _can_drop_data, _drop_data)
	if parent_header:
		parent_header.set_drag_forwarding(Callable(), _can_drop_data, _drop_data)
	if channels_box:
		channels_box.set_drag_forwarding(Callable(), _can_drop_data, _drop_data)
		if channel:
			channels_box.nest_parent = channel


## Bind to the parent mix channel and rebuild nested strips.
func bind_to_parent(ch: Channel, proj: Project, host: MixerChannel) -> void:
	channel = ch
	project = proj
	_host = host
	if channels_box:
		channels_box.nest_parent = ch
	if ch:
		apply_header_color(ch.color)
	if host:
		apply_header_height(host.children_header_height)
	sync_children()


## Set the parent header bar height (MixerChannel.children_header_height).
func apply_header_height(height: float) -> void:
	if parent_header:
		parent_header.custom_minimum_size.y = height


## Distance from this fold-out's top to its nested strips: panel margin, header bar, separation.
func get_children_top_offset() -> float:
	var offset := parent_header.custom_minimum_size.y if parent_header else 0.0
	var style := get_theme_stylebox("panel")
	if style:
		offset += style.get_margin(SIDE_TOP)
	var column := get_node_or_null("VBoxContainer") as VBoxContainer
	if column:
		offset += column.get_theme_constant("separation")
	return offset


## Tint the fold-out header with the parent channel color.
func apply_header_color(new_color: Color) -> void:
	if parent_header == null:
		return
	var drawn := Utils.display_color(new_color)
	if _header_fill == null:
		var base := parent_header.get_theme_stylebox("panel")
		_header_fill = base.duplicate() as StyleBoxFlat if base is StyleBoxFlat else StyleBoxFlat.new()
		_header_fill.expand_margin_left = 3.0
		_header_fill.expand_margin_right = 3.0
		_header_fill.expand_margin_bottom = 2.0
		parent_header.add_theme_stylebox_override("panel", _header_fill)
	_header_fill.bg_color = drawn
	parent_header.queue_redraw()


## Spawn, reorder, or free nested MixerChannels to match `child_channel_ids`.
func sync_children() -> void:
	if channels_box == null:
		return

	var desired: Array[int] = []
	if channel:
		desired = channel.child_channel_ids.duplicate()

	var existing: Dictionary = {}
	var stale: Array[Node] = []
	for child in channels_box.get_children():
		if child is MixerChannel and child.channel and desired.has(child.channel.id):
			existing[child.channel.id] = child
		else:
			stale.append(child)
	for node in stale:
		channels_box.remove_child(node)
		node.queue_free()

	for i in desired.size():
		var child_id: int = desired[i]
		var ui: MixerChannel = existing.get(child_id) as MixerChannel
		if ui == null:
			ui = _spawn_child(child_id)
			if ui == null:
				continue
			existing[child_id] = ui
		if ui.get_parent() == channels_box and ui.get_index() != i:
			channels_box.move_child(ui, i)

	contents_changed.emit()


## Instantiate a nested MixerChannel for `child_id` and bind it to the project.
func _spawn_child(child_id: int) -> MixerChannel:
	if project == null:
		return null
	var child_ch := project.get_channel_by_id(child_id)
	if child_ch == null:
		return null

	var scene := load("res://mixer/MixerChannel.tscn") as PackedScene
	if scene == null:
		push_error("[MixerChannelChildren] Failed to load MixerChannel.tscn")
		return null

	var ui := scene.instantiate() as MixerChannel
	if ui == null:
		return null

	channels_box.add(ui)
	ui.bind_to_channel(child_ch, project)

	var mixer := _find_mixer()
	if mixer and mixer.has_method("wire_channel_item"):
		mixer.wire_channel_item(ui)

	return ui


## Accept a mixer strip drag; the Mixer resolves nest / insert from the pointer.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not data is MixerChannelDrag:
		return false
	var mixer := _find_mixer()
	return mixer != null and mixer.can_drop_channel_drag(data as MixerChannelDrag)


## Insert the dragged strip at the hovered index (resolved by the Mixer).
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not data is MixerChannelDrag:
		return
	var mixer := _find_mixer()
	if mixer:
		mixer.drop_channel_drag(data as MixerChannelDrag)


## Walk ancestors to the Mixer that owns this fold-out.
func _find_mixer() -> Node:
	var n: Node = self
	while n:
		if n.has_method("wire_channel_item"):
			return n
		n = n.get_parent()
	return null
