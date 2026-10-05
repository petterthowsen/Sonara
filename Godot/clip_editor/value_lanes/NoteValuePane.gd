## The strip below the note area that holds the value lanes. Which lanes are open, and their
## heights, are an editor preference (config `clip_editor/value_lanes`), not project data.
class_name NoteValuePane extends PanelContainer

const CONFIG_KEY := "clip_editor/value_lanes"
const DEFAULT_LANE_HEIGHT := 96.0
const LANE_SCENE := preload("res://clip_editor/value_lanes/ValueLane.tscn")

## Emitted when a lane was touched by an edit gesture (the last touched note).
signal note_touched(note: MidiNoteData)

@onready var header_spacer: Control = $VBox/Header/HBox/HeaderSpacer
@onready var add_lane_button: MenuButton = $VBox/Header/HBox/AddLaneButton
@onready var lanes_box: VBoxContainer = $VBox/Lanes

var midi_editor: MidiEditor = null
var lanes: Array[ValueLane] = []
var _loading := false


func _ready() -> void:
	add_lane_button.get_popup().id_pressed.connect(_on_add_lane_id)
	add_lane_button.about_to_popup.connect(_rebuild_add_menu)
	_rebuild_add_menu()
	
	# clear lanes in the scene
	for child in lanes_box.get_children():
		if child is ValueLane:
			child.queue_free()


## Follow `editor` and restore the persisted lanes. Called once by ClipEditor.
func bind(editor: MidiEditor) -> void:
	midi_editor = editor
	editor.key_column_width_changed.connect(_on_key_column_width_changed)
	_on_key_column_width_changed(editor.key_column_width())
	_load()


func is_lanes_visible() -> bool:
	return visible


## Show or hide the whole pane and remember it.
func set_lanes_visible(on: bool) -> void:
	visible = on
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
	lane.set_header_width(midi_editor.key_column_width() if midi_editor else 0.0)
	lane.close_requested.connect(remove_lane)
	lane.height_changed.connect(_save)
	lane.note_touched.connect(func(n): note_touched.emit(n))
	lanes.append(lane)
	_save()
	_rebuild_add_menu()
	return lane


func remove_lane(lane: ValueLane) -> void:
	if lane not in lanes:
		return
	lanes.erase(lane)
	lane.queue_free()
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


func _on_key_column_width_changed(w: float) -> void:
	header_spacer.custom_minimum_size.x = w
	for l in lanes:
		l.set_header_width(w)


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
