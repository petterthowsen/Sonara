# MarkerActions.gd
# Undoable song-marker edits shared by the marker lane: create, rename, split and delete.
# Markers never overlap: a new range cuts, splits or removes the markers it lands on.
# Marker names are unique (compared by NameStyle.key); a taken name gets a number suffix.
class_name MarkerActions extends RefCounted

const DEFAULT_NAME := "Marker"

## `Verse 2` -> groups `Verse`, `2`.
static var _number_suffix_re := RegEx.create_from_string("^(.*\\S)\\s+(\\d+)$")


## Create a marker over [start_ticks, start_ticks + duration_ticks), cutting any markers it overlaps.
## Recorded as one "Create Marker" step. Returns the new marker.
static func create_marker(
	project: Project,
	start_ticks: int,
	duration_ticks: int,
	marker_name: String = "Marker"
) -> SongMarker:
	if project == null:
		return null
	var marker := project.create_marker(start_ticks, duration_ticks, unique_name(project, marker_name))
	commit_marker(project, marker)
	return marker


## Record `marker` as created: carve its range out of the other markers and add it, as one
## "Create Marker" step. `marker` may already be in the project (a preview shown while placing).
static func commit_marker(project: Project, marker: SongMarker) -> void:
	if project == null or marker == null:
		return
	var cmds := carve_commands(project, marker.start_ticks, marker.get_end_ticks(), marker)
	cmds.append(MarkerCreateCommand.new(project, marker))
	HistoryUtil.execute_many("Create Marker", cmds)


## Rename `marker` as one undo step, made unique among the other markers. Returns the applied name.
static func rename_marker(project: Project, marker: SongMarker, new_name: String) -> String:
	if marker == null:
		return ""
	var resolved := unique_name(project, new_name, marker)
	HistoryUtil.execute_property("Rename Marker", marker, "set_name", marker.name, resolved)
	return marker.name


## `desired` (trimmed, `Marker` when empty) if no other marker uses it, else the next free
## `Name N`. A taken name that already ends in a number counts up from it (`Verse 2` -> `Verse 3`).
static func unique_name(project: Project, desired: String, exclude: SongMarker = null) -> String:
	var base := desired.strip_edges()
	if base.is_empty():
		base = DEFAULT_NAME
	var existing: PackedStringArray = []
	if project:
		for other in project.markers:
			if other != exclude:
				existing.append(other.name)
	if not DeviceNaming.is_taken(existing, base):
		return base
	var n := 2
	var suffix := _number_suffix_re.search(base)
	if suffix:
		base = suffix.get_string(1)
		n = maxi(n, suffix.get_string(2).to_int() + 1)
	while DeviceNaming.is_taken(existing, "%s %d" % [base, n]):
		n += 1
	return "%s %d" % [base, n]


## Split `marker` at `tick` into two markers with the same color; the right half gets the next free
## name (`Verse` -> `Verse 2`). Returns the right half,
## or null when `tick` is not strictly inside the marker.
static func split_marker(project: Project, marker: SongMarker, tick: int) -> SongMarker:
	if not can_split_at(marker, tick) or project == null:
		return null
	var right := _piece_of(project, marker, tick, marker.get_end_ticks())
	var cmds: Array[Command] = [
		_range_command("Split Marker", marker, marker.start_ticks, tick - marker.start_ticks),
		MarkerCreateCommand.new(project, right),
	]
	HistoryUtil.execute_many("Split Marker", cmds)
	return right


## Add a fresh marker covering `marker` from `tick` to its end (the left part is kept).
## Returns the new marker, or null when `tick` is not strictly inside the marker.
static func add_marker_at_split(project: Project, marker: SongMarker, tick: int) -> SongMarker:
	if not can_split_at(marker, tick) or project == null:
		return null
	return create_marker(project, tick, marker.get_end_ticks() - tick)


## Delete `marker` as one undo step.
static func delete_marker(project: Project, marker: SongMarker) -> void:
	if project == null or marker == null:
		return
	HistoryUtil.execute(MarkerDeleteCommand.new(project, marker))


## True when `tick` lies strictly between the marker's start and end.
static func can_split_at(marker: SongMarker, tick: int) -> bool:
	return marker != null and tick > marker.start_ticks and tick < marker.get_end_ticks()


## Commands (not yet executed) that clear [start, end) of every marker except `exclude`:
## markers inside are deleted, markers crossing one edge are trimmed, and a marker spanning the
## whole range is split around it.
static func carve_commands(
	project: Project,
	start: int,
	end: int,
	exclude: SongMarker = null
) -> Array[Command]:
	var cmds: Array[Command] = []
	if project == null or end <= start:
		return cmds
	for other in project.markers:
		if other == exclude:
			continue
		var o_start := other.start_ticks
		var o_end := other.get_end_ticks()
		if o_end <= start or o_start >= end:
			continue
		var keeps_left := o_start < start
		var keeps_right := o_end > end
		if keeps_left and keeps_right:
			cmds.append(_range_command("Split Marker", other, o_start, start - o_start))
			cmds.append(MarkerCreateCommand.new(project, _piece_of(project, other, end, o_end)))
		elif keeps_left:
			cmds.append(_range_command("Trim Marker", other, o_start, start - o_start))
		elif keeps_right:
			cmds.append(_range_command("Trim Marker", other, end, o_end - end))
		else:
			cmds.append(MarkerDeleteCommand.new(project, other))
	return cmds


## New (unadded) marker over [start, end) copying `source`'s color, named after it.
static func _piece_of(project: Project, source: SongMarker, start: int, end: int) -> SongMarker:
	var piece := project.create_marker(start, end - start, unique_name(project, source.name))
	piece.duration_ticks = end - start  # create_marker enforces a one-beat minimum
	piece.color = source.color
	return piece


static func _range_command(label: String, marker: SongMarker, start: int, duration: int) -> MarkerRangeCommand:
	return MarkerRangeCommand.new(
		label, marker, 1, marker.start_ticks, marker.duration_ticks, start, duration
	)
