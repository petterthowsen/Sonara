# StageView.gd
# The Stage view (spec 051): the top-down canvas plus the room and source panels. It is a page of
# a DeviceFrame (DeviceWindowManager.open_stage()), which calls show_view() / hide_view().
# Everything goes through the models: VirtualStage setters for the room, Channel setters for
# sources, each recorded as an undo step. The view never sends OSC.
class_name StageView extends HSplitContainer

## The user changed which sources are selected in the view (canvas click).
signal selection_changed(channels: Array[Channel])

var project: Project = null
var _syncing := false
var _shown := false

@onready var canvas: StageCanvas = %Canvas
@onready var _preset: OptionButton = %PresetOption
@onready var _width: SpinBox = %Width
@onready var _depth: SpinBox = %Depth
@onready var _height: SpinBox = %Height
@onready var _listener_x: SpinBox = %ListenerX
@onready var _listener_y: SpinBox = %ListenerY
@onready var _listener_z: SpinBox = %ListenerZ
@onready var _decay: SpinBox = %Decay
@onready var _tail: SpinBox = %TailGain
@onready var _distance_delay: CheckButton = %DistanceDelay
@onready var _output: OptionButton = %OutputOption
@onready var _material_grid: GridContainer = %MaterialGrid
@onready var _summary: Label = %SourceSummary
@onready var _source_height: SpinBox = %SourceHeight
@onready var _source_size: SpinBox = %SourceSize
@onready var _source_rotation: SpinBox = %SourceRotation
@onready var _sum_mode: OptionButton = %SumOption
@onready var _has_room: CheckButton = %HasRoom

## Surface -> OptionButton of materials.
var _material_options: Dictionary = {}


func _ready() -> void:
	for id in StagePresets.PRESET_ORDER:
		_preset.add_item(StagePresets.preset_label(id))
		_preset.set_item_metadata(_preset.item_count - 1, id)
	_preset.add_item("Custom")
	_preset.set_item_metadata(_preset.item_count - 1, "")
	_preset.item_selected.connect(_on_preset_selected)
	for surface in StagePresets.SURFACES:
		var label := Label.new()
		label.text = surface.capitalize()
		_material_grid.add_child(label)
		var option := OptionButton.new()
		option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		option.fit_to_longest_item = false
		for material_id in StagePresets.material_ids():
			option.add_item(StagePresets.material_label(material_id))
			option.set_item_metadata(option.item_count - 1, material_id)
		option.item_selected.connect(_on_material_selected.bind(surface, option))
		_material_grid.add_child(option)
		_material_options[surface] = option
	_width.value_changed.connect(func(v: float) -> void: _edit_room(func() -> void: project.stage.set_width(v)))
	_depth.value_changed.connect(func(v: float) -> void: _edit_room(func() -> void: project.stage.set_depth(v)))
	_height.value_changed.connect(func(v: float) -> void: _edit_room(func() -> void: project.stage.set_height(v)))
	for spin: SpinBox in [_listener_x, _listener_y, _listener_z]:
		spin.value_changed.connect(func(_v: float) -> void: _edit_room(_apply_listener))
	_decay.value_changed.connect(func(v: float) -> void: _edit_room(func() -> void: project.stage.set_decay_s(v)))
	_tail.value_changed.connect(func(v: float) -> void: _edit_room(func() -> void: project.stage.set_tail_db(v)))
	_distance_delay.toggled.connect(func(on: bool) -> void: _edit_room(func() -> void: project.stage.set_distance_delay(on), false))
	_output.item_selected.connect(func(i: int) -> void: _edit_room(func() -> void: project.stage.set_output_mode(_output.get_item_id(i)), false))
	_source_height.value_changed.connect(_on_source_height)
	_source_size.value_changed.connect(func(v: float) -> void: _edit_source_states("Set Source Size", StageEdit.set_size, v))
	_source_rotation.value_changed.connect(func(v: float) -> void: _edit_source_states("Set Source Rotation", StageEdit.set_rotation, v))
	_sum_mode.item_selected.connect(func(i: int) -> void: _edit_sources("Set Stage Sum Mode",
			func(ch: Channel) -> void: ch.set_stage_sum_mode(_sum_mode.get_item_id(i)), false))
	_has_room.toggled.connect(func(on: bool) -> void: _edit_sources("Set Has Room",
			func(ch: Channel) -> void: ch.set_stage_has_room(on), false))
	canvas.selection_changed.connect(_on_canvas_selection)
	canvas.refreshed.connect(_refresh_source_panel)
	_refresh_room()
	_refresh_source_panel()


## Bind the view to `p` (the editor's project). Tests call this directly.
func set_project(p: Project) -> void:
	if project and project.stage.changed.is_connected(_refresh_room):
		project.stage.changed.disconnect(_refresh_room)
	project = p
	if project:
		project.stage.changed.connect(_refresh_room)
	canvas.set_project(project)
	_refresh_room()
	_refresh_source_panel()


## The sources drawn in the canvas.
func get_items() -> Array[Channel]:
	return canvas.get_items()


func get_selection() -> Array[Channel]:
	return canvas.get_selection()


## Select `channels` in the view as if the user had clicked them: the editor follows (REQ-024).
func select_from_user(channels: Array[Channel]) -> void:
	canvas.set_selection_silent(channels)
	_on_canvas_selection(canvas.get_selection())


## Replace the selection without telling the editor (it came from the mixer or the arranger).
func set_selection_silent(channels: Array[Channel]) -> void:
	canvas.set_selection_silent(SelectionSync.stage_selection_for_channels(project, channels))
	_refresh_source_panel()


func _on_canvas_selection(channels: Array[Channel]) -> void:
	_refresh_source_panel()
	selection_changed.emit(channels)
	var ed := _editor()
	if ed and project:
		var mapped := SelectionSync.channels_for_stage_selection(project, channels)
		ed.apply_channel_selection(mapped["channels"], mapped["focused"])


# ============================================================================
# Frame hooks (DeviceFrame calls these on its page)
# ============================================================================

func show_view() -> void:
	if _shown:
		return
	_shown = true
	var ed := _editor()
	if ed == null:
		return
	if project == null:
		set_project(ed.project)
	ed.playhead_moved.connect(_on_playhead_moved)
	ed.playback_started.connect(_on_playback_changed)
	ed.playback_stopped.connect(_on_playback_changed)
	ed.channel_selection_synced.connect(set_selection_silent)
	set_selection_silent(ed.mixer.selection)
	_on_playback_changed()


func hide_view() -> void:
	if not _shown:
		return
	_shown = false
	var ed := _editor()
	if ed == null:
		return
	ed.playhead_moved.disconnect(_on_playhead_moved)
	ed.playback_started.disconnect(_on_playback_changed)
	ed.playback_stopped.disconnect(_on_playback_changed)
	ed.channel_selection_synced.disconnect(set_selection_silent)
	canvas.set_playhead(-1)


## The editor, or null in headless tests (where no Editor exists).
func _editor() -> Editor:
	return null if Utils.is_test_mode() else Sonara.editor


func _on_playhead_moved(ticks: int) -> void:
	var ed := _editor()
	canvas.set_playhead(ticks if ed and ed.is_playing else -1)


func _on_playback_changed() -> void:
	var ed := _editor()
	canvas.set_playhead(ed.playhead_ticks if ed and ed.is_playing else -1)


# ============================================================================
# Room panel
# ============================================================================

func _refresh_room() -> void:
	if project == null:
		return
	var room := project.stage
	_syncing = true
	_width.set_value_no_signal(room.width)
	_depth.set_value_no_signal(room.depth)
	_height.set_value_no_signal(room.height)
	_listener_x.max_value = room.width
	_listener_y.max_value = room.depth
	_listener_z.max_value = room.height
	_listener_x.set_value_no_signal(room.listener.x)
	_listener_y.set_value_no_signal(room.listener.y)
	_listener_z.set_value_no_signal(room.listener.z)
	_decay.set_value_no_signal(room.decay_s)
	_tail.set_value_no_signal(room.tail_db)
	_distance_delay.set_pressed_no_signal(room.distance_delay)
	_output.select(_output.get_item_index(int(room.output_mode)))
	for i in _preset.item_count:
		var id: String = _preset.get_item_metadata(i)
		_preset.set_item_text(i, StagePresets.preset_label(id) if id != "" else "Custom")
		if id == room.preset:
			_preset.select(i)
			_preset.set_item_text(i, room.preset_label())
	if room.preset == "" or not StagePresets.has_preset(room.preset):
		_preset.select(_preset.item_count - 1)
	for surface: String in _material_options:
		var option: OptionButton = _material_options[surface]
		for i in option.item_count:
			if option.get_item_metadata(i) == room.get_material(surface):
				option.select(i)
	_syncing = false


func _apply_listener() -> void:
	project.stage.set_listener(Vector3(_listener_x.value, _listener_y.value, _listener_z.value))


func _on_preset_selected(index: int) -> void:
	var id: String = _preset.get_item_metadata(index)
	if _syncing or project == null or id == "":
		_refresh_room()
		return
	_edit_room(func() -> void: project.stage.apply_preset(id), false)


func _on_material_selected(index: int, surface: String, option: OptionButton) -> void:
	if _syncing or project == null:
		return
	var id: String = option.get_item_metadata(index)
	_edit_room(func() -> void: project.stage.set_material(surface, id), false)


## Run `change` on the stage and record it as an undo step. Sources the room pulled back inside
## (Project clamps them when the room shrinks) are part of the same step.
func _edit_room(change: Callable, mergeable := true) -> void:
	if _syncing or project == null:
		return
	var room := project.stage
	var old_room := room.get_state()
	var old_sources := _source_states()
	change.call()
	var cmds: Array[Command] = []
	var room_cmd := PropertyCommand.new("Edit Room", room, "set_state", old_room, room.get_state())
	room_cmd.set_mergeable(mergeable)
	if room.get_state() != old_room:
		cmds.append(room_cmd)
	for ch: Channel in old_sources:
		var now := ch.get_stage_state()
		if now != old_sources[ch]:
			cmds.append(PropertyCommand.new("Edit Room", ch, "set_stage_state", old_sources[ch], now))
	# Several commands become a macro, which can't merge: only a lone room edit merges.
	HistoryUtil.record_many("Edit Room", cmds)


func _source_states() -> Dictionary:
	var out := {}
	for ch in project.stage_sources():
		out[ch] = ch.get_stage_state()
	return out


# ============================================================================
# Source panel
# ============================================================================

func _refresh_source_panel() -> void:
	var selected := canvas.get_selection() if canvas else ([] as Array[Channel])
	_syncing = true
	var any := not selected.is_empty()
	_source_height.editable = any
	_source_size.editable = any
	_source_rotation.editable = any
	_sum_mode.disabled = not any
	_has_room.disabled = not any
	if any:
		var first := selected[0]
		_summary.text = first.name if selected.size() == 1 else "%d sources" % selected.size()
		_source_height.max_value = project.stage.height if project else 25.0
		_source_height.set_value_no_signal(first.stage_z)
		_source_size.max_value = maxf(project.stage.width, project.stage.depth) * 1.5 if project else 50.0
		_source_size.set_value_no_signal(first.stage_size)
		_source_rotation.set_value_no_signal(first.stage_rotation)
		_sum_mode.select(_sum_mode.get_item_index(int(first.stage_sum_mode)))
		_has_room.set_pressed_no_signal(first.stage_has_room)
	else:
		_summary.text = "No source selected"
	_syncing = false


func _on_source_height(value: float) -> void:
	if _syncing or project == null:
		return
	var selected := canvas.get_selection()
	var olds: Array = []
	for ch in selected:
		olds.append(ch.get_stage_state())
	var news := StageEdit.set_height(project.stage, olds, value)
	var cmds: Array[Command] = []
	for i in selected.size():
		selected[i].set_stage_state(news[i])
		if news[i] != olds[i]:
			var cmd := PropertyCommand.new("Set Source Height", selected[i], "set_stage_state", olds[i], news[i])
			cmd.set_mergeable(true)
			cmds.append(cmd)
	HistoryUtil.record_many("Set Source Height", cmds)


## Apply a StageEdit function (room, states, value) to the selected sources as one undo step.
func _edit_source_states(label: String, edit: Callable, value: float) -> void:
	if _syncing or project == null:
		return
	var selected := canvas.get_selection()
	var olds: Array = []
	for ch in selected:
		olds.append(ch.get_stage_state())
	var news: Array = edit.call(project.stage, olds, value)
	var cmds: Array[Command] = []
	for i in selected.size():
		selected[i].set_stage_state(news[i])
		if news[i] != olds[i]:
			var cmd := PropertyCommand.new(label, selected[i], "set_stage_state", olds[i], news[i])
			cmd.set_mergeable(true)
			cmds.append(cmd)
	HistoryUtil.record_many(label, cmds)


func _edit_sources(label: String, change: Callable, mergeable: bool) -> void:
	if _syncing or project == null:
		return
	var cmds: Array[Command] = []
	for ch in canvas.get_selection():
		var old := ch.get_stage_state()
		change.call(ch)
		var now := ch.get_stage_state()
		if now != old:
			var cmd := PropertyCommand.new(label, ch, "set_stage_state", old, now)
			cmd.set_mergeable(mergeable)
			cmds.append(cmd)
	HistoryUtil.record_many(label, cmds)
