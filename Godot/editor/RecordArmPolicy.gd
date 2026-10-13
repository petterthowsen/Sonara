# RecordArmPolicy.gd
# Decides which track record-arm lands on when a group is selected. Pure functions over the
# Project's tracks so they can be tested without an Editor.
class_name RecordArmPolicy extends RefCounted

const ARM_GROUP := "Record arm the group"
const ARM_FIRST := "Record arm the first valid child"
const ARM_LAST := "Record arm the last armed valid child"

const KEY_WITHOUT_TARGETS := "arranger/group_arm_without_targets"
const KEY_WITH_TARGETS := "arranger/group_arm_with_targets"


## Valid children of `group`: audio and instrument tracks (anything that holds clips) nested
## at any depth, in arranger order (depth first; nested groups are searched, never armed).
static func valid_children(project: Project, group: Track) -> Array[Track]:
	var out: Array[Track] = []
	_collect(project, group, out, {})
	return out


static func _collect(project: Project, group: Track, out: Array[Track], seen: Dictionary) -> void:
	if group == null or seen.has(group.id):
		return
	seen[group.id] = true
	for child in project.tracks:
		if child.parent_track_id != group.id:
			continue
		if child.has_clips():
			out.append(child)
		else:
			_collect(project, child, out, seen)


## The track to arm for a selected `group`, given the option value for its case. Falls back to
## the group itself when it has no valid child.
static func resolve(project: Project, group: Track, option: String) -> Track:
	var children := valid_children(project, group)
	if children.is_empty() or option == ARM_GROUP:
		return group
	if option == ARM_LAST:
		for c in children:
			if c.id == group.last_armed_child_id:
				return c
	return children[0]


## Whether `group` has a valid child, i.e. which of the two group options applies.
static func has_targets(project: Project, group: Track) -> bool:
	return not valid_children(project, group).is_empty()
