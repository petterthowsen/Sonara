## The strip below the note area that holds the value lanes. Which lanes are open, and their
## heights, are an editor preference (config `clip_editor/value_lanes`), not project data.
## The pane's height comes from the editor split above it: the top lane fills it (the split
## is that lane's grip), the other lanes keep their own heights.
class_name NoteValuePane extends PanelContainer

const CONFIG_KEY := "clip_editor/value_lanes"
const DEFAULT_LANE_HEIGHT := 96.0
const LANE_SCENE := preload("res://clip_editor/value_lanes/ValueLane.tscn")

## Emitted when a lane was touched by an edit gesture (the last touched note).
signal note_touched(note: MidiNoteData)

@onready var add_lane_button: MenuButton = $HBox/Header/VBox/AddLaneButton
@onready var lanes_box: VBoxContainer = $HBox/Lanes

var midi_editor: MidiEditor = null
## The editor split this pane sits at the bottom of (null when used on its own).
var _split: SplitContainer = null
var lanes: Array[ValueLane] = []
var _loading := false


func _ready() -> void:
	add_lane_button.get_popup().id_pressed.connect(_on_add_lane_id)
	add_lane_button.about_to_popup.connect(_rebuild_add_menu)
	_rebuild_add_menu()
	lanes_box.sort_children.connect(_align_lanes)
	visibility_changed.connect(_align_lanes)
	visibility_changed.connect(func(): _sync_split.call_deferred())
	# A lane below the top one grew or shrank (its grip), or one was added or removed.
	minimum_size_changed.connect(func(): _sync_split.call_deferred())

	# clear lanes in the scene
	for child in lanes_box.get_children():
		if child is ValueLane:
			lanes_box.remove_child(child)  # now, or it holds the pane's height for a frame
			child.queue_free()


## Follow `editor` and restore the persisted lanes. Called once by ClipEditor.
func bind(editor: MidiEditor) -> void:
	midi_editor = editor
	_split = get_parent() as SplitContainer
	if _split:
		_split.dragged.connect(func(_o): _capture_top_height.call_deferred())
		_split.drag_ended.connect(func():
			_capture_top_height()
			_save())
	# The note area moves when the key column (piano / drum rows) changes width.
	editor.note_area.item_rect_changed.connect(func(): _align_lanes.call_deferred())
	_load()
	_relayout()


func is_lanes_visible() -> bool:
	return visible


## Show or hide the whole pane and remember it.
func set_lanes_visible(on: bool) -> void:
	visible = on
	_sync_split.call_deferred()
	_save()


func lane_keys() -> Array[String]:
	var out: Array[String] = []
	for l in lanes:
		out.append(l.descriptor.key)
	return out


func add_lane(key: String, height := DEFAULT_LANE_HEIGHT) -> ValueLane:
	var d := NoteValueDescriptors.by_key(key)
	if d == null or key in lane_keys():
		return null
	var lane: ValueLane = LANE_SCENE.instantiate()
	lanes_box.add_child(lane)
	lane.setup(d, midi_editor)
	lane.set_lane_height(height)
	lane.close_requested.connect(remove_lane)
	lane.height_changed.connect(_save)
	lane.note_touched.connect(func(n): note_touched.emit(n))
	lanes.append(lane)
	_relayout()
	_save()
	_rebuild_add_menu()
	return lane


func remove_lane(lane: ValueLane) -> void:
	if lane not in lanes:
		return
	lanes.erase(lane)
	lane.queue_free()
	_relayout()
	_save()
	_rebuild_add_menu()


func _rebuild_add_menu() -> void:
	var popup := add_lane_button.get_popup()
	popup.clear()
	var open := lane_keys()
	var idx := 0
	for d in NoteValueDescriptors.all():
		popup.add_item(d.display_name, idx)
		popup.set_item_metadata(idx, d.key)
		popup.set_item_disabled(idx, d.key in open)
		idx += 1


func _on_add_lane_id(id: int) -> void:
	var key: String = add_lane_button.get_popup().get_item_metadata(id)
	add_lane(key)


## Size each lane's header so its stem area starts exactly where the note area does: the
## pane's own margin and "+" column come out of the key column's width.
func _align_lanes() -> void:
	if midi_editor == null or not is_visible_in_tree():
		return
	var target := midi_editor.note_area.global_position.x
	for l in lanes:
		if l.is_node_ready() and not l.is_queued_for_deletion():
			l.set_header_width(target - l.header.global_position.x)


# ============================================================================
# HEIGHT (the editor split sizes the top lane)
# ============================================================================

func _relayout() -> void:
	for i in lanes.size():
		lanes[i].set_fills(i == 0)
	_sync_split.call_deferred()


## Move the split so the top lane gets its stored height. The pane doesn't expand, so a split
## offset of -h gives it h pixels, and its minimum holds the top lane's row at its floor.
func _sync_split() -> void:
	if _split == null or lanes.is_empty() or not is_visible_in_tree():
		return
	var top: ValueLane = lanes[0]
	var want := roundi(get_combined_minimum_size().y + top.lane_height() - top.min_row_height())
	if _split.split_offset != -want:
		_split.split_offset = -want


func _capture_top_height() -> void:
	if not lanes.is_empty() and is_visible_in_tree():
		lanes[0].set_lane_height(_top_row_height())


## The top lane's row height from the pane's own size: the pane's minimum holds that row at
## its floor, so everything above the minimum is the top lane's. (Its row may not be laid out
## yet right after the split moved.)
func _top_row_height() -> float:
	return lanes[0].min_row_height() + size.y - get_combined_minimum_size().y


# ============================================================================
# PERSISTENCE
# ============================================================================

## Looked up through the tree: this class_name script can compile before autoloads resolve by name.
func _sonara() -> Node:
	return get_node("/root/Sonara")


func _load() -> void:
	_loading = true
	var cfg = _sonara().get_config(CONFIG_KEY, null)
	var keys: Array = []
	if cfg is Dictionary:
		visible = bool(cfg.get("visible", true))
		var raw = cfg.get("lanes", null)
		if raw is Array:
			for entry in raw:
				if entry is Dictionary and NoteValueDescriptors.by_key(str(entry.get("key", ""))) != null:
					keys.append(entry)
		else:
			keys = [{"key": "vel", "height": DEFAULT_LANE_HEIGHT}]
	else:
		visible = true
		keys = [{"key": "vel", "height": DEFAULT_LANE_HEIGHT}]
	for entry in keys:
		add_lane(str(entry["key"]), float(entry.get("height", DEFAULT_LANE_HEIGHT)))
	_loading = false


func _save() -> void:
	if _loading:
		return
	var out: Array = []
	for l in lanes:
		out.append({"key": l.descriptor.key, "height": l.lane_height()})
	_sonara().set_config(CONFIG_KEY, {"visible": visible, "lanes": out})
