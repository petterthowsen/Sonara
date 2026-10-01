# test_track_item_height_sync.gd
# Headless test for TrackItem's layout-driven height: a narrow TracksPanel makes the header's
# flow container wrap, which grows the header past Track.height. The header must push that
# height into the model so the timeline lane (which sizes from Track.height) grows with it,
# and restore the height the user set once wrapping stops.
#
# Run: godot --headless --path Godot -s tests/test_track_item_height_sync.gd -- --test
extends TestBase

const TRACK_ITEM_SCENE := "res://arranger/tracklist/TrackItem.tscn"
## Loaded lazily in run_tests(): the script references autoloads (Settings), which only resolve
## after the tree has processed a frame. Naming the global class here would fail to compile.
const TIMELINE_TRACK_SCRIPT := "res://arranger/timeline/TimelineTrack.gd"
## Wide enough that the header's controls fit on one line.
const WIDE_COLUMN := 320
## Narrow enough that the controls wrap to more lines.
const NARROW_COLUMN := 140
const BASE_HEIGHT := 48


func suite_name() -> String:
	return "TrackItem layout height sync"


func run_tests() -> void:
	await _test_wrapping_height_reaches_timeline_lane()
	await _test_explicit_resize_supersedes_layout_height()
	await _test_shrink_below_floor_keeps_lane_as_tall_as_header()


## Build a header inside a fixed-width column plus a timeline lane for the same track.
func _make_fixture() -> Dictionary:
	var project: Object = load("res://data/Project.gd").new()
	var a: Dictionary = project.create_instrument_track("A")
	a.track.height = BASE_HEIGHT

	var root := Control.new()
	root.size = Vector2(800, 600)
	get_root().add_child(root)

	var column := VBoxContainer.new()
	column.custom_minimum_size.x = WIDE_COLUMN
	root.add_child(column)

	var item: Control = (load(TRACK_ITEM_SCENE) as PackedScene).instantiate()
	column.add_child(item)

	var lane: Control = (load(TIMELINE_TRACK_SCRIPT) as GDScript).new() as Control
	root.add_child(lane)

	await process_frame
	item.bind_to_track(a.track, 0, project)
	lane.bind_to_track(a.track, 0)
	await process_frame
	await process_frame

	return {"project": project, "track": a.track, "root": root, "column": column, "item": item, "lane": lane}


func _test_wrapping_height_reaches_timeline_lane() -> void:
	var f := await _make_fixture()
	var track: Object = f.track
	var item: Control = f.item
	var lane: Control = f.lane

	_assert(track.height == BASE_HEIGHT, "starts at the track height")
	_assert(int(lane.custom_minimum_size.y) == BASE_HEIGHT, "lane starts at the track height")

	f.column.custom_minimum_size.x = NARROW_COLUMN
	await process_frame
	await process_frame

	var wrapped: int = track.height
	_assert(wrapped > BASE_HEIGHT, "narrow column grows the header (height=%d)" % wrapped)
	_assert(int(item.size.y) == wrapped, "header is laid out at the grown height (%d)" % int(item.size.y))
	_assert(int(lane.custom_minimum_size.y) == wrapped, "timeline lane follows the grown height (%d)" % int(lane.custom_minimum_size.y))

	f.column.custom_minimum_size.x = WIDE_COLUMN
	await process_frame
	await process_frame

	_assert(track.height == BASE_HEIGHT, "widening restores the user's height (height=%d)" % track.height)
	_assert(int(lane.custom_minimum_size.y) == BASE_HEIGHT, "timeline lane shrinks back with the header")

	f.root.queue_free()


func _test_explicit_resize_supersedes_layout_height() -> void:
	var f := await _make_fixture()
	var track: Object = f.track

	f.column.custom_minimum_size.x = NARROW_COLUMN
	await process_frame
	await process_frame
	_assert(track.height > BASE_HEIGHT, "header grew first")

	# An explicit height (drag, vertical zoom, undo) must not be undone by a later widen.
	track.height = 200
	await process_frame
	await process_frame

	f.column.custom_minimum_size.x = WIDE_COLUMN
	await process_frame
	await process_frame

	_assert(track.height == 200, "explicit height survives widening (height=%d)" % track.height)

	f.root.queue_free()


## A vertical zoom, undo or a small stored height can write `Track.height` below what the header's
## wrapped controls need. The container then keeps the header at its content floor while its
## realized size does not change, so the lane (which sizes from `Track.height`) would stay shorter
## than its header. The model height must be pushed back up to the header's realized height.
func _test_shrink_below_floor_keeps_lane_as_tall_as_header() -> void:
	var f := await _make_fixture()
	var track: Object = f.track
	var item: Control = f.item
	var lane: Control = f.lane

	f.column.custom_minimum_size.x = NARROW_COLUMN
	await process_frame
	await process_frame
	var floor: int = track.height
	_assert(floor > BASE_HEIGHT, "narrow column raised the floor to %d" % floor)

	track.height = 30
	await process_frame
	await process_frame

	_assert(int(item.size.y) == floor, "header stays at its floor (%d)" % int(item.size.y))
	_assert(track.height == int(item.size.y), "model height follows the header (track=%d header=%d)" % [track.height, int(item.size.y)])
	_assert(int(lane.custom_minimum_size.y) == int(item.size.y), "lane is as tall as the header (lane=%d header=%d)" % [int(lane.custom_minimum_size.y), int(item.size.y)])

	f.root.queue_free()
