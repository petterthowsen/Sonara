class_name ClipContextMenu extends PopupPanel

# Containers
@onready var v_box: VBoxContainer = $VBoxContainer
@onready var header: PanelContainer = $VBoxContainer/Header

# Data Controls
@onready var label: SmartLineEdit = $VBoxContainer/Header/HBox/Label
@onready var active_checkbox: CheckButton = $VBoxContainer/ActiveCheckbox
@onready var make_unique: Button = $VBoxContainer/MakeUnique
@onready var delete: Button = $VBoxContainer/Delete

signal delete_requested(instances: Array[ClipInstance])
signal make_unique_requested(instances: Array[ClipInstance])

var clip_instance: ClipInstance = null
var selected_instances: Array[ClipInstance] = []


## Wire buttons, size the title so the name is readable, and listen for renames.
func _ready() -> void:
	if is_instance_valid(make_unique):
		make_unique.pressed.connect(_on_make_unique_pressed)
	if is_instance_valid(delete):
		delete.pressed.connect(_on_delete_pressed)
	if is_instance_valid(label):
		label.custom_minimum_size = Vector2(148, 32)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_FILL
		if label.label:
			label.label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			label.label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			if label.label.label_settings:
				label.label.label_settings = label.label.label_settings.duplicate()
				label.label.label_settings.font_size = 16
		if not label.value_changed.is_connected(_on_name_changed):
			label.value_changed.connect(_on_name_changed)
	if is_instance_valid(header):
		header.custom_minimum_size.y = 32
	if is_instance_valid(v_box):
		v_box.custom_minimum_size.x = 160


## Bind the menu to a single clip instance.
func bind_to_clip_instance(inst: ClipInstance) -> void:
	var arr: Array[ClipInstance] = []
	if inst:
		arr = [inst]
	bind_to_instances(arr)


## Bind the menu to the current selection (title only for a single instance).
func bind_to_instances(instances: Array[ClipInstance]) -> void:
	selected_instances.clear()
	for i in instances:
		if i:
			selected_instances.append(i)

	clip_instance = selected_instances[0] if selected_instances.size() == 1 else null

	# Label visibility and content
	if label:
		label.visible = selected_instances.size() == 1
		if label.visible and clip_instance:
			if label.is_editing:
				label.cancel_editing()
			var clip_name = clip_instance.clip.name if clip_instance.clip else "Clip"
			label.set_value(clip_name)

	# Enable/disable Make Unique: enable if ANY selected instance shares its clip
	var can_make_unique = false
	if Sonara and Sonara.editor and Sonara.editor.project:
		var proj := Sonara.editor.project
		for inst in selected_instances:
			if inst and inst.clip_id and proj.get_clip_instance_count(inst.clip_id) > 1:
				can_make_unique = true
				break
	if make_unique:
		make_unique.disabled = not can_make_unique


## Commit a clip rename from the menu title.
func _on_name_changed(new_value) -> void:
	if clip_instance == null or clip_instance.clip == null:
		return
	var new_name := str(new_value).strip_edges()
	if new_name.is_empty() or new_name == clip_instance.clip.name:
		return
	HistoryUtil.execute_property("Rename Clip", clip_instance.clip, "set_name", clip_instance.clip.name, new_name)


## Delete the bound instances.
func _on_delete_pressed() -> void:
	if selected_instances.is_empty():
		return
	delete_requested.emit(selected_instances.duplicate())
	hide()


## Request Make Unique for the bound instances.
func _on_make_unique_pressed() -> void:
	if selected_instances.is_empty():
		return
	make_unique_requested.emit(selected_instances.duplicate())
	hide()
