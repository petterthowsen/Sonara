# AutomationRowOrder.gd
# The single source of truth for the arranger's flat vertical row order, called by both columns
# (TrackList on the left, Timeline on the right). Keeping one helper is what stops the two
# `_update_visual_order()` implementations from drifting once automation lanes interleave with
# track rows (REQ-013).
#
# A row is a plain Dictionary so this stays trivially testable without any scene:
#   {"track": Track, "lane": AutomationLane or null}
# `lane == null` marks the track's own row; lane rows follow their track in `automation_lanes`
# order.
class_name AutomationRowOrder extends RefCounted


## Flat top-to-bottom row order for `project`, matching the folder hierarchy that
## `Project.get_visual_track_list()` produces and inserting each track's visible lane rows
## directly beneath it.
static func build(project: Object) -> Array:
	var rows: Array = []
	if project == null:
		return rows
	for track in project.get_visual_track_list():
		rows.append({"track": track, "lane": null})
		for lane in visible_lanes(track):
			rows.append({"track": track, "lane": lane})
	return rows


## The lanes of `track` that currently occupy a row: only when the track's disclosure is open,
## and only lanes the lane menu has left checked (REQ-014).
static func visible_lanes(track: Object) -> Array:
	var result: Array = []
	if track == null or not track.automation_expanded:
		return result
	for lane in track.automation_lanes:
		if lane != null and lane.visible:
			result.append(lane)
	return result


## Apply `rows` to `container`'s children by moving each row's node into place. `node_for` maps a
## row Dictionary to the Control representing it (or null when that row has no node yet); rows
## without a node are skipped without disturbing the indices of the ones that do.
static func apply(container: Node, rows: Array, node_for: Callable) -> void:
	if container == null:
		return
	var index := 0
	for row in rows:
		var node: Node = node_for.call(row)
		if node == null or node.get_parent() != container:
			continue
		container.move_child(node, index)
		index += 1
