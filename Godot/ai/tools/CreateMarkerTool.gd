# CreateMarkerTool.gd
class_name CreateMarkerTool extends AiTool


const DEFAULT_BARS := 4


func get_name() -> String:
	return "create_marker"


func get_description() -> String:
	return "Create a named ruler marker (song section) over a time span. Markers never overlap: existing markers in the span are trimmed, split or removed. Without start, uses the selected range. Undoable."


func get_parameters() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"name": {"type": "string", "description": "Section name, e.g. Intro, Verse, Chorus"},
			"start": {"type": "string", "description": "bar.beat.tick or bar number (1-based). Default: selected range start"},
			"end": {"type": "string", "description": "Exclusive end as bar.beat.tick or bar number, e.g. start 5 end 13 = 8 bars"},
			"bars": {"type": "number", "description": "Length in bars when end is omitted (default: selected range, else %d)" % DEFAULT_BARS},
			"color": {"type": "string", "description": "Optional hex color, e.g. #e0a030 (default: random)"},
		},
		"required": ["name"],
	}


func execute(args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var marker_name := name_arg(args, "name")
	if marker_name.is_empty():
		return fail("name is required")
	var tpb := ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)
	var time_range: Dictionary = Sonara.editor.get_time_range() if Sonara and Sonara.editor else {}
	var has_range: bool = time_range.get("has", false)
	var start: int
	if args.has("start"):
		start = resolve_start_ticks(project, args)
	elif has_range:
		start = int(time_range.start)
	else:
		return fail("start is required (no range is selected)")
	var end := -1
	if args.has("end"):
		end = resolve_start_ticks(project, args, "end")
	elif args.has("bars"):
		var bars := float(args.bars)
		if bars <= 0.0:
			return fail("bars must be positive")
		end = start + int(round(bars * tpb))
	elif not args.has("start") and time_range.get("has_end", false):
		end = int(time_range.end)
	else:
		end = start + DEFAULT_BARS * tpb
	if end <= start:
		return fail("end must be after start")
	var color := Color.TRANSPARENT
	if args.has("color"):
		var hex := str(args.color).strip_edges()
		color = Color.from_string(hex, Color.TRANSPARENT)
		if color.a <= 0.0:
			return fail("Invalid hex color: %s" % hex)
	var before := _layout(project)
	var marker: SongMarker = project.create_marker(start, end - start, MarkerActions.unique_name(project, marker_name))
	marker.duration_ticks = end - start  # create_marker enforces a one-beat minimum
	if color.a > 0.0:
		marker.color = color
	MarkerActions.commit_marker(project, marker)
	# The desired name may have belonged to a marker this one just replaced.
	if marker.name != marker_name and MarkerActions.unique_name(project, marker_name, marker) == marker_name:
		marker.set_name(marker_name)
	var text := "Created marker %s" % ListMarkersTool.describe_marker(project, marker)
	if marker.name != marker_name:
		text += " (\"%s\" is taken)" % marker_name
	var after := _layout(project, marker)
	if after != before:
		text += ". Overlapping markers were trimmed, split or removed; markers now: %s" % _layout(project)
	return ok_text(text, ListMarkersTool.compact_marker(project, marker))


## Comma-joined description of every marker except `exclude`, to detect whether carving changed any.
func _layout(project: Project, exclude: SongMarker = null) -> String:
	var parts: PackedStringArray = []
	for m in ListMarkersTool.sorted_markers(project):
		if m != exclude:
			parts.append(ListMarkersTool.describe_marker(project, m))
	return ", ".join(parts)
