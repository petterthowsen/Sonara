# ListMarkersTool.gd
class_name ListMarkersTool extends AiTool


func get_name() -> String:
	return "list_markers"


func get_description() -> String:
	return "List ruler markers (named song sections such as Intro, Verse) in timeline order with start/end bar.beat.tick. End is exclusive."


func execute(_args: Dictionary) -> Dictionary:
	var project = require_project()
	if project is Dictionary:
		return project
	var rows: Array = []
	for m in sorted_markers(project):
		rows.append(compact_marker(project, m))
	if rows.is_empty():
		return ok_text("No markers.", {"markers": rows})
	return ok({"markers": rows})


## Project markers ordered by start tick.
static func sorted_markers(project: Project) -> Array:
	var out: Array = project.markers.duplicate()
	out.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
	return out


## `{name, start, end, bars, color}` for one marker. `bars` may be fractional.
static func compact_marker(project: Project, m: SongMarker) -> Dictionary:
	var tpb := ClipTextTime.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)
	var bars := float(m.duration_ticks) / tpb
	return {
		"name": m.name,
		"start": _bbt(project, m.start_ticks),
		"end": _bbt(project, m.get_end_ticks()),
		"bars": int(bars) if is_equal_approx(bars, roundf(bars)) else snappedf(bars, 0.01),
		"color": "#%s" % m.color.to_html(false),
	}


## `Verse 5.1.000–13.1.000` for text results.
static func describe_marker(project: Project, m: SongMarker) -> String:
	return "\"%s\" %s–%s" % [m.name, _bbt(project, m.start_ticks), _bbt(project, m.get_end_ticks())]


static func _bbt(project: Project, ticks: int) -> String:
	return ClipTextTime.format_bbt(ticks, project.ppq, project.time_numerator, project.time_denominator)
