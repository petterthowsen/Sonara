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
## directly beneath it. Children of a collapsed folder are left out, except while that folder's
## fold animation is still sliding them.
static func build(project: Object) -> Array:
	var rows: Array = []
	if project == null:
		return rows
	for track in project.get_visual_track_list():
		if _folded_away(project, track):
			continue
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


## Rows animating below this height are hidden instead: a TrackItem can't shrink past its content,
## so both columns cut over at the same height to stay aligned.
const FOLD_MIN_ROW_HEIGHT := 40.0


## Normal height of `row`'s node: the lane height for a lane row, else the track height.
static func base_height(row: Dictionary) -> float:
	var lane: Object = row.get("lane")
	return float(lane.height) if lane != null else float(row["track"].height)


## Height per row in `rows`, sliding the children of every running TrackFoldAnimation: the
## subtree's rows are revealed top-down, and a row shows only once it has FOLD_MIN_ROW_HEIGHT.
## Returns base_height() for rows no animation touches.
static func fold_heights(project: Object, rows: Array) -> Array[float]:
	var heights: Array[float] = []
	for row in rows:
		heights.append(base_height(row))
	if project == null:
		return heights
	for anim in TrackFoldAnimation.running():
		var folder: Object = anim.track
		var start := -1
		for i in rows.size():
			if rows[i]["track"] == folder and rows[i].get("lane") == null:
				start = i
				break
		if start < 0:
			continue
		# The folder's own lane rows stay put; its descendants form the sliding block.
		var block: Array[int] = []
		for i in range(start + 1, rows.size()):
			var t: Object = rows[i]["track"]
			if t == folder:
				continue
			if not project.track_is_in_subtree(t.id, folder):
				break
			block.append(i)
		var total := 0.0
		for i in block:
			total += base_height(rows[i])
		var extent: float = total * anim.reveal
		var offset := 0.0
		for i in block:
			var full := base_height(rows[i])
			var shown := clampf(extent - offset, 0.0, full)
			if shown < full and shown < FOLD_MIN_ROW_HEIGHT:
				shown = 0.0
			heights[i] = minf(heights[i], shown)
			offset += full
	return heights


## Size and show/hide `rows`' nodes from fold_heights(). A row cut short clips its contents until
## it is back to full height.
static func apply_heights(project: Object, rows: Array, node_for: Callable) -> void:
	var heights := fold_heights(project, rows)
	for i in rows.size():
		var node := node_for.call(rows[i]) as Control
		if node == null:
			continue
		var full := base_height(rows[i])
		var shown := heights[i]
		node.visible = shown > 0.0
		var cut := shown > 0.0 and shown < full
		node.custom_minimum_size.y = shown if cut else full
		if cut:
			if not node.has_meta(&"fold_clip"):
				node.set_meta(&"fold_clip", node.clip_contents)
			node.clip_contents = true
			node.size.y = shown
		elif node.has_meta(&"fold_clip"):
			node.clip_contents = node.get_meta(&"fold_clip")
			node.remove_meta(&"fold_clip")


## True when a collapsed ancestor hides `track` and isn't still sliding its children away.
static func _folded_away(project: Object, track: Object) -> bool:
	var parent: Object = project.get_track_by_id(track.parent_track_id) if track.parent_track_id >= 0 else null
	while parent:
		if not parent.is_folder_expanded and TrackFoldAnimation.for_track(parent) == null:
			return true
		parent = project.get_track_by_id(parent.parent_track_id) if parent.parent_track_id >= 0 else null
	return false
