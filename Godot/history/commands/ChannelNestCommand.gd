# Undoable mixer nest / un-nest (channel tree + locked route; paired track follows).
class_name ChannelNestCommand extends Command

## Project that owns the channels.
var project: Project = null

## Channel being nested or un-nested.
var child: Channel = null

## New mixer parent; null un-nests to the left-pane root.
var new_parent: Channel = null

## Sibling to sit after under the new parent (null = first child).
var after_sibling: Channel = null

var _did_snapshot: bool = false
var _old_parent_id: int = -1
var _old_after_id: int = -1
var _old_output_id: int = 1


## Nest `p_child` under `p_parent`, or un-nest when parent is null.
func _init(
	p_project: Project = null,
	p_child: Channel = null,
	p_parent: Channel = null,
	p_after_sibling: Channel = null
) -> void:
	project = p_project
	child = p_child
	new_parent = p_parent
	after_sibling = p_after_sibling
	name = "Nest Channel" if p_parent else "Unnest Channel"


## Apply the nest or un-nest.
func do() -> void:
	if project == null or child == null:
		return
	if not _did_snapshot:
		_snapshot()
		_did_snapshot = true
	if new_parent:
		project.nest_channel(child, new_parent, after_sibling)
	else:
		project.unnest_channel(child)


## Restore the previous parent, sibling order, and output route.
func undo() -> void:
	if project == null or child == null:
		return
	var old_parent := project.get_channel_by_id(_old_parent_id)
	var old_after := project.get_channel_by_id(_old_after_id)
	if old_parent:
		project.nest_channel(child, old_parent, old_after)
	else:
		project.unnest_channel(child)
		if child.output_channel_id != _old_output_id:
			child.set_route(_old_output_id)


## Record parent, previous sibling, and output before the first do().
func _snapshot() -> void:
	_old_parent_id = child.parent_channel_id
	_old_output_id = child.output_channel_id
	_old_after_id = -1
	if _old_parent_id < 0:
		return
	var parent := project.get_channel_by_id(_old_parent_id)
	if parent == null:
		return
	var ids: Array[int] = parent.child_channel_ids
	var idx := ids.find(child.id)
	if idx > 0:
		_old_after_id = ids[idx - 1]
