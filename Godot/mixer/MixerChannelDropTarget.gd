# MixerChannelDropTarget.gd
# Where a mixer strip drag lands under the pointer: nest onto a group header, insert between strips
# in a fold-out, un-nest into the root pane, or reorder within a root pane. Nothing moves while
# dragging; the drop handlers and the drop indicator both resolve through here so the indicator
# always shows what releasing the mouse will do.
class_name MixerChannelDropTarget extends RefCounted

enum Kind { NONE, NEST, INSERT, UNNEST, REORDER }

## Width of the insert line core, in pixels.
const LINE_WIDTH := 3.0

var kind: Kind = Kind.NONE

## Mixer parent for NEST / INSERT.
var parent: Channel = null

## Sibling to sit after (null = first). For UNNEST / REORDER, the root strip to sit after.
var after_sibling: Channel = null

## Global rect to draw: the group header for NEST, a thin insert line otherwise.
var indicator_rect: Rect2 = Rect2()


## True when a drop here would do something.
func is_valid() -> bool:
	return kind != Kind.NONE


## True when the indicator outlines a header rather than drawing an insert line.
func is_nest() -> bool:
	return kind == Kind.NEST


## True when `ch` is a mix parent a strip can be dropped onto (Group, or already has children).
static func accepts_children(ch: Channel) -> bool:
	return ch != null and (ch.is_group_channel or not ch.child_channel_ids.is_empty())


## Resolve the target for `drag` at global `mouse` inside `mixer`.
static func resolve(mixer: Mixer, drag: MixerChannelDrag, mouse: Vector2) -> MixerChannelDropTarget:
	var target := MixerChannelDropTarget.new()
	if mixer == null or drag == null or drag.channel == null or mixer.current_project == null:
		return target
	var project := mixer.current_project
	var dragged := drag.channel

	# Buses only reorder among themselves in the right pane.
	if dragged.is_bus:
		if mixer.right_pane.get_global_rect().has_point(mouse):
			target._insert_in_box(mixer, project, drag, mixer.right_channels as ChannelsBox, mouse)
		return target

	# Only the left pane holds nestable strips; its scrolled-out content must not catch drops.
	if not mixer.left_pane.get_global_rect().has_point(mouse):
		return target

	var strip := _deepest_strip_at(mixer, mouse)
	if strip == null:
		target._insert_in_box(mixer, project, drag, mixer.left_channels as ChannelsBox, mouse)
		return target

	# Group header: nest at the end of its children.
	if strip.header and strip.header.get_global_rect().has_point(mouse):
		if target._try_nest(project, drag, strip.channel, strip.header.get_global_rect()):
			return target

	var kids := strip.children_slide as MixerChannelChildren
	if kids and kids.visible and kids.get_global_rect().has_point(mouse):
		# The fold-out's parent-colored bar is the same group's header.
		var bar := kids.parent_header
		if bar and bar.get_global_rect().has_point(mouse):
			if target._try_nest(project, drag, strip.channel, bar.get_global_rect()):
				return target
		target._insert_in_box(mixer, project, drag, kids.channels_box, mouse)
		return target

	# Anywhere else on a strip: insert beside it.
	target._insert_in_box(mixer, project, drag, strip.get_parent() as ChannelsBox, mouse)
	return target


## Apply this target through history. Returns true when something changed.
func commit(mixer: Mixer, drag: MixerChannelDrag) -> bool:
	if mixer == null or drag == null or drag.channel == null:
		return false
	var project := mixer.current_project
	var moved := false
	var after := after_sibling
	# Each strip lands after the previous one, keeping the dragged strips in on-screen order.
	for ch in drag.channels:
		match kind:
			Kind.NEST, Kind.INSERT:
				moved = MixerChannelDrag.commit(project, ch, parent, after) or moved
			Kind.UNNEST:
				if ch.parent_channel_id >= 0:
					if MixerChannelDrag.commit(project, ch, null):
						mixer.place_root_strip(ch, after)
						moved = true
				else:
					moved = mixer.place_root_strip(ch, after) or moved
			Kind.REORDER:
				moved = mixer.place_root_strip(ch, after) or moved
		after = ch
	return moved


## Nest `dragged` at the end of `group` when allowed; `rect` is the header to outline.
func _try_nest(project: Project, drag: MixerChannelDrag, group: Channel, rect: Rect2) -> bool:
	if drag.channels.has(group) or not accepts_children(group):
		return false
	var after := _last_child_except(project, group, drag.channels)
	for ch in drag.channels:
		if not project.can_nest_channel(ch, group, after):
			return false
	kind = Kind.NEST
	parent = group
	after_sibling = after
	indicator_rect = rect
	return true


## Insert into `box` at the pointer: a fold-out inserts under its parent, a root pane reorders
## (or un-nests a nested strip into the left pane).
func _insert_in_box(
	mixer: Mixer,
	project: Project,
	drag: MixerChannelDrag,
	box: ChannelsBox,
	mouse: Vector2
) -> void:
	if box == null:
		return
	var after := MixerChannelDrag.after_sibling_at(box, mouse.x, drag.channels)
	if box.nest_parent:
		if drag.channels.has(box.nest_parent):
			return
		for ch in drag.channels:
			if not project.can_nest_channel(ch, box.nest_parent, after):
				return
		kind = Kind.INSERT
		parent = box.nest_parent
	elif box == mixer.left_channels and drag.channels.any(func(ch: Channel) -> bool: return ch.parent_channel_id >= 0):
		for ch in drag.channels:
			if ch.parent_channel_id >= 0 and not MixerChannelDrag.can_unnest(ch):
				return
		kind = Kind.UNNEST
	elif box == mixer.left_channels or box == mixer.right_channels:
		for ch in drag.channels:
			var ui := mixer.find_mixer_channel_ui_for_channel(ch)
			if ui == null or ui.get_parent() != box:
				return
		kind = Kind.REORDER
	else:
		return
	after_sibling = after
	indicator_rect = _insert_line_rect(box, after)


## Thin vertical rect at the left edge of the strip following `after` (or the first strip).
## Uses the strips' current layout; the dragged strip stays in place until the drop.
static func _insert_line_rect(box: ChannelsBox, after: Channel) -> Rect2:
	var box_rect := box.get_global_rect()
	var x := box_rect.position.x
	var found_after := after == null
	for child in box.get_children():
		if not child is MixerChannel or child.is_queued_for_deletion():
			continue
		var mc := child as MixerChannel
		if found_after:
			x = mc.get_global_rect().position.x
			break
		x = mc.get_global_rect().end.x
		if mc.channel == after:
			found_after = true
	return Rect2(x - LINE_WIDTH * 0.5, box_rect.position.y, LINE_WIDTH, box_rect.size.y)


## Last child of `parent` other than `exclude`, or null.
static func _last_child_except(project: Project, parent: Channel, exclude: Array) -> Channel:
	for i in range(parent.child_channel_ids.size() - 1, -1, -1):
		var ch := project.get_channel_by_id(parent.child_channel_ids[i])
		if ch and not exclude.has(ch):
			return ch
	return null


## Innermost visible MixerChannel of `mixer` under `mouse` (nested strips sit inside their parent).
static func _deepest_strip_at(mixer: Mixer, mouse: Vector2) -> MixerChannel:
	var best: MixerChannel = null
	var best_depth := -1
	for node in mixer.get_tree().get_nodes_in_group("mixer_channel"):
		if not node is MixerChannel or node.is_queued_for_deletion():
			continue
		var mc := node as MixerChannel
		if mc.channel == null or not mixer.is_ancestor_of(mc) or not mc.is_visible_in_tree():
			continue
		if not mc.get_global_rect().has_point(mouse):
			continue
		var depth := mc.get_path().get_name_count()
		if depth > best_depth:
			best = mc
			best_depth = depth
	return best
