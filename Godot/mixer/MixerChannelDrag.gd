# MixerChannelDrag.gd
# Payload for Godot GUI mixer-strip reparent (nest / un-nest). Sibling reorder stays header-slide.
class_name MixerChannelDrag

## Emitted when Godot destroys the drag preview (drop, Escape, or drag cancelled).
signal drag_completed(data: MixerChannelDrag)

var source: MixerChannel = null
var destination: Control = null
var channel: Channel = null
var preview: Control = null

## True after a successful nest/un-nest so listeners can skip cancel cleanup.
var did_commit: bool = false


## Bind the preview's lifetime to this drag payload.
func _init(_source: MixerChannel, _channel: Channel, _preview: Control) -> void:
	self.source = _source
	self.channel = _channel
	self.preview = _preview
	if self.preview:
		self.preview.tree_exiting.connect(_on_tree_exiting)


## Emitted when Godot destroys the drag preview (drop, Escape, or drag cancelled).
func _on_tree_exiting() -> void:
	drag_completed.emit(self)


## Ghost label that follows the cursor during a mixer reparent drag.
static func make_preview(ch: Channel) -> Control:
	var ghost := PanelContainer.new()
	var label_node := Label.new()
	var preview_bg := Color.GRAY
	if ch:
		preview_bg = Utils.display_color(ch.color)
		label_node.text = ch.name
	else:
		label_node.text = "Channel"
	preview_bg.a = 0.85
	Utils.apply_label_font_color(label_node, Utils.contrasting_text_color(preview_bg))
	ghost.add_child(label_node)
	var style := StyleBoxFlat.new()
	style.bg_color = preview_bg
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	ghost.add_theme_stylebox_override("panel", style)
	ghost.custom_minimum_size = Vector2(120, 24)
	ghost.z_index = 1000
	return ghost


## True when `child` may be dragged as a mixer nest/un-nest source.
static func can_drag(ch: Channel) -> bool:
	if ch == null:
		return false
	return not ch.is_master and not ch.is_bus


## True when `child` can leave its mixer parent to the left-pane root.
static func can_unnest(ch: Channel) -> bool:
	return can_drag(ch) and ch.parent_channel_id >= 0 and not ch.is_aux_return()


## Sibling to sit after when dropping into `box` at global `mouse_x` (null = first).
static func after_sibling_at(box: ChannelsBox, mouse_x: float, exclude: Channel = null) -> Channel:
	var after: Channel = null
	if box == null:
		return after
	for child in box.get_children():
		if not child is MixerChannel:
			continue
		var mc := child as MixerChannel
		if mc.channel == null or mc.channel == exclude:
			continue
		if mouse_x > mc.get_global_rect().get_center().x:
			after = mc.channel
		else:
			break
	return after


## Last child of `parent`, or null when the group is empty.
static func last_child(project: Project, parent: Channel) -> Channel:
	if project == null or parent == null or parent.child_channel_ids.is_empty():
		return null
	return project.get_channel_by_id(parent.child_channel_ids[parent.child_channel_ids.size() - 1])


## Nest under `parent` (null = un-nest) through history. Mixer waits for drop; no live reparent.
static func commit(
	project: Project,
	child: Channel,
	parent: Channel,
	after_sibling: Channel = null
) -> bool:
	if project == null or child == null:
		return false
	if parent:
		if not project.can_nest_channel(child, parent, after_sibling):
			return false
		if child.parent_channel_id == parent.id and _already_after(parent, child, after_sibling):
			return false
	elif not can_unnest(child):
		return false

	if parent and not parent.is_children_expanded:
		parent.is_children_expanded = true

	var paired := project.get_channel_paired_track(child)
	if paired:
		var before := TrackReorderCommand.capture_layout(project)
		var ok := project.nest_channel(child, parent, after_sibling) if parent else project.unnest_channel(child)
		if not ok:
			return false
		var after := TrackReorderCommand.capture_layout(project)
		if not TrackReorderCommand.layouts_equal(before, after):
			HistoryUtil.record(TrackReorderCommand.new(project, before, after))
		return true

	HistoryUtil.execute(ChannelNestCommand.new(project, child, parent, after_sibling))
	return true


## True when `child` already sits after `after_sibling` under `parent`.
static func _already_after(
	parent: Channel,
	child: Channel,
	after_sibling: Channel
) -> bool:
	var ids: Array[int] = parent.child_channel_ids
	var idx := ids.find(child.id)
	if idx < 0:
		return false
	if after_sibling == null:
		return idx == 0
	if idx == 0:
		return false
	return ids[idx - 1] == after_sibling.id
