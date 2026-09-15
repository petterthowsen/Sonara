# test_markers.gd
# Headless tests for MarkerActions: creating over existing markers cuts, splits or removes them,
# split keeps color and names the new half uniquely, names stay unique, a pre-shown (placed) marker
# commits without carving itself, and each action undoes as one step.
#
# Project references autoloads by bare name, so scripts are loaded with load() in run_tests().
# Run: godot --headless --path Godot -s tests/test_markers.gd -- --test
extends TestBase

const BEAT := 960

var _project_script: GDScript
var _actions: GDScript
var _history_script: GDScript


func suite_name() -> String:
	return "Marker actions tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_actions = load("res://history/MarkerActions.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_test_create_in_gap()
	_test_create_trims_edges()
	_test_create_inside_splits()
	_test_create_covers_removes()
	_test_split()
	_test_add_marker_at_split()
	_test_carve_undo()
	_test_unique_names()
	_test_rename_unique()
	_test_commit_placed_marker()


func _project() -> Object:
	var project: Object = _project_script.new()
	project.ppq = BEAT
	return project


## Add a marker directly (no carving) for test setup.
func _add(project: Object, start_beats: int, beats: int, marker_name: String) -> Object:
	var m: Object = project.create_marker(start_beats * BEAT, beats * BEAT, marker_name)
	project.add_marker(m)
	return m


## Sorted "name@start-end" (in beats) description of the project's markers.
func _layout(project: Object) -> String:
	var parts: Array[String] = []
	var sorted: Array = project.markers.duplicate()
	sorted.sort_custom(func(a, b): return a.start_ticks < b.start_ticks)
	for m in sorted:
		parts.append("%s@%d-%d" % [m.name, m.start_ticks / BEAT, m.get_end_ticks() / BEAT])
	return " ".join(parts)


func _test_create_in_gap() -> void:
	var p := _project()
	_add(p, 0, 4, "A")
	_add(p, 8, 4, "B")
	_actions.create_marker(p, 4 * BEAT, 4 * BEAT, "N")
	_assert(_layout(p) == "A@0-4 N@4-8 B@8-12", "gap create leaves neighbors: %s" % _layout(p))


func _test_create_trims_edges() -> void:
	var p := _project()
	_add(p, 0, 4, "A")
	_add(p, 6, 4, "B")
	_actions.create_marker(p, 2 * BEAT, 6 * BEAT, "N")
	_assert(_layout(p) == "A@0-2 N@2-8 B@8-10", "overlapping edges trimmed: %s" % _layout(p))


func _test_create_inside_splits() -> void:
	var p := _project()
	var a: Object = _add(p, 0, 16, "Verse")
	_actions.create_marker(p, 4 * BEAT, 4 * BEAT, "N")
	_assert(_layout(p) == "Verse@0-4 N@4-8 Verse 2@8-16", "inner create splits: %s" % _layout(p))
	var right: Object = null
	for m in p.markers:
		if m != a and m.name == "Verse 2":
			right = m
	_assert(right != null and right.color == a.color, "split piece keeps color")
	_assert(right != null and right.id != a.id, "split piece gets its own id")


func _test_create_covers_removes() -> void:
	var p := _project()
	_add(p, 2, 2, "A")
	_add(p, 4, 2, "B")
	_actions.create_marker(p, 0, 8 * BEAT, "N")
	_assert(_layout(p) == "N@0-8", "covered markers removed: %s" % _layout(p))


func _test_split() -> void:
	var p := _project()
	var a: Object = _add(p, 0, 8, "Verse")
	var right: Object = _actions.split_marker(p, a, 3 * BEAT)
	_assert(_layout(p) == "Verse@0-3 Verse 2@3-8", "split halves: %s" % _layout(p))
	_assert(right != null and right.color == a.color, "split keeps color")
	_assert(_actions.split_marker(p, a, 0) == null, "split at start is refused")
	_assert(_actions.split_marker(p, a, 3 * BEAT) == null, "split at end is refused")


func _test_add_marker_at_split() -> void:
	var p := _project()
	var a: Object = _add(p, 0, 16, "Verse")
	_add(p, 16, 8, "Chorus")
	var n: Object = _actions.add_marker_at_split(p, a, 8 * BEAT)
	_assert(n != null and n.name == "Marker", "new marker created")
	_assert(_layout(p) == "Verse@0-8 Marker@8-16 Chorus@16-24", "add-at-split fills rest: %s" % _layout(p))


## Carving goes through HistoryUtil, which only runs do() without an editor; undo the macro by hand.
func _test_carve_undo() -> void:
	var p := _project()
	_add(p, 0, 16, "Verse")
	_add(p, 16, 4, "Bridge")
	var marker: Object = p.create_marker(4 * BEAT, 14 * BEAT, "N")
	var cmds: Array = _actions.carve_commands(p, marker.start_ticks, marker.get_end_ticks())
	cmds.append(load("res://history/commands/MarkerCreateCommand.gd").new(p, marker))
	var macro: Object = load("res://history/commands/MacroCommand.gd").new("Create Marker", cmds)
	var hist: Object = _history_script.new()
	hist.execute(macro)
	_assert(_layout(p) == "Verse@0-4 N@4-18 Bridge@18-20", "carve applied: %s" % _layout(p))
	hist.undo()
	_assert(_layout(p) == "Verse@0-16 Bridge@16-20", "undo restores: %s" % _layout(p))
	hist.redo()
	_assert(_layout(p) == "Verse@0-4 N@4-18 Bridge@18-20", "redo reapplies: %s" % _layout(p))


func _test_unique_names() -> void:
	var p := _project()
	_actions.create_marker(p, 0, 4 * BEAT)
	_actions.create_marker(p, 4 * BEAT, 4 * BEAT)
	_actions.create_marker(p, 8 * BEAT, 4 * BEAT, "marker")
	_assert(_layout(p) == "Marker@0-4 Marker 2@4-8 marker 3@8-12", "create names unique: %s" % _layout(p))
	var v2: Object = _add(p, 12, 8, "Verse 2")
	_actions.split_marker(p, v2, 16 * BEAT)
	_assert(_layout(p).ends_with("Verse 2@12-16 Verse 3@16-20"), "split counts up from suffix: %s" % _layout(p))
	_assert(_actions.unique_name(p, "  ") == "Marker 4", "empty name falls back to Marker")


func _test_rename_unique() -> void:
	var p := _project()
	_add(p, 0, 4, "Verse")
	var b: Object = _add(p, 4, 4, "Chorus")
	_assert(_actions.rename_marker(p, b, "verse") == "verse 2", "rename to taken name gets suffix")
	_assert(_actions.rename_marker(p, b, "Verse 2 ") == "Verse 2", "rename to own name (other case) is kept")
	_assert(_actions.rename_marker(p, b, "Bridge") == "Bridge", "free name kept")


## Placing shows the marker in the project first; committing must carve others but not itself.
func _test_commit_placed_marker() -> void:
	var p := _project()
	_add(p, 0, 8, "Intro")
	var placed: Object = p.create_marker(4 * BEAT, 8 * BEAT, "Drop")
	p.add_marker(placed)
	_actions.commit_marker(p, placed)
	_assert(_layout(p) == "Intro@0-4 Drop@4-12", "placed marker carves neighbors: %s" % _layout(p))
	_assert(p.markers.count(placed) == 1, "placed marker added once")
