## One lane of the value pane: a header column (name, scale, menu, close) and a stem area.
## Built from ValueLane.tscn.
class_name ValueLane extends VBoxContainer

signal close_requested(lane: ValueLane)
## The lane's height changed (the resize grip), so the pane persists it.
signal height_changed
signal note_touched(note: MidiNoteData)

const MIN_HEIGHT := 40.0
const MAX_HEIGHT := 400.0

const MENU_SET := 0
const MENU_RANDOMIZE := 1
const MENU_SCALE := 2

@onready var row: HBoxContainer = $Row
@onready var header: PanelContainer = $Row/LaneHeader
@onready var name_label: Label = $Row/LaneHeader/VBox/NameLabel
@onready var max_label: Label = $Row/LaneHeader/VBox/MaxLabel
@onready var min_label: Label = $Row/LaneHeader/VBox/MinLabel
@onready var menu_button: MenuButton = $Row/LaneHeader/VBox/HBox/MenuButton
@onready var close_button: Button = $Row/LaneHeader/VBox/HBox/CloseButton
@onready var stem_area: ValueLaneStemArea = $Row/StemArea
@onready var resize_grip: Control = $ResizeGrip
@onready var transform_dialog: NoteValueTransformDialog = $TransformDialog

var descriptor: NoteValueDescriptor = null
var midi_editor: MidiEditor = null
var _grip_dragging := false
var _grip_press_y := 0.0
var _grip_press_height := 0.0


func _ready() -> void:
	close_button.pressed.connect(func(): close_requested.emit(self))
	var popup := menu_button.get_popup()
	popup.clear()
	popup.add_item("Set…", MENU_SET)
	popup.add_item("Randomize…", MENU_RANDOMIZE)
	popup.add_item("Scale…", MENU_SCALE)
	popup.id_pressed.connect(_on_menu_id)
	stem_area.context_requested.connect(_on_context_requested)
	stem_area.note_touched.connect(func(n): note_touched.emit(n))
	transform_dialog.applied.connect(_on_transform_applied)
	resize_grip.gui_input.connect(_on_grip_input)
	var settings := get_node_or_null("/root/Settings")
	if settings:
		settings.setting_changed.connect(_on_setting_changed)
	_refresh_header()


## Show `d`'s values of the notes `editor` displays.
func setup(d: NoteValueDescriptor, editor: MidiEditor) -> void:
	descriptor = d
	midi_editor = editor
	stem_area.descriptor = d
	stem_area.bind(editor)
	if is_node_ready():
		_refresh_header()


func set_header_width(w: float) -> void:
	header.custom_minimum_size.x = w


func lane_height() -> float:
	return row.custom_minimum_size.y


func set_lane_height(h: float) -> void:
	row.custom_minimum_size.y = clampf(h, MIN_HEIGHT, MAX_HEIGHT)


func _refresh_header() -> void:
	if descriptor == null:
		return
	var mode := NoteValueDescriptors.display_mode()
	name_label.text = descriptor.display_name
	max_label.text = descriptor.format_extreme(descriptor.max_value, mode)
	min_label.text = descriptor.format_extreme(descriptor.min_value, mode)


func _on_setting_changed(key: String, _value) -> void:
	if key == NoteValueDescriptor.DISPLAY_SETTING:
		_refresh_header()


func _on_context_requested(global_pos: Vector2) -> void:
	var popup := menu_button.get_popup()
	popup.position = Vector2i(global_pos)
	popup.popup()


func _on_menu_id(id: int) -> void:
	transform_dialog.open_for(id as NoteValueTransformDialog.Kind, descriptor)


## The notes a transform acts on: the selection, or every editable note when none is selected.
func transform_targets() -> Array[MidiNoteData]:
	var selected := midi_editor.selected_note_data()
	if not selected.is_empty():
		return selected
	var out: Array[MidiNoteData] = []
	for stem in midi_editor.value_stems():
		if stem["note_data"] not in out:
			out.append(stem["note_data"])
	return out


func _on_transform_applied(kind: NoteValueTransformDialog.Kind, amount: float) -> void:
	var targets := transform_targets()
	if targets.is_empty():
		return
	var current: Array[float] = []
	for nd in targets:
		current.append(descriptor.get_value(nd))
	var result: Array[float]
	match kind:
		NoteValueTransformDialog.Kind.SET:
			result = NoteValueTransforms.set_all(current, amount, descriptor)
		NoteValueTransformDialog.Kind.RANDOMIZE:
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			result = NoteValueTransforms.randomize(current, amount, rng, descriptor)
		_:
			result = NoteValueTransforms.scale_around_mean(current, amount, descriptor)
	stem_area.apply_values(targets, result)


func _on_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_grip_dragging = event.pressed
		_grip_press_y = event.global_position.y
		_grip_press_height = lane_height()
		if not event.pressed:
			height_changed.emit()
		accept_event()
	elif event is InputEventMouseMotion and _grip_dragging:
		set_lane_height(_grip_press_height + event.global_position.y - _grip_press_y)
		accept_event()
