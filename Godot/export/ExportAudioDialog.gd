## Export audio dialog: renders the project (or the arranger selection) offline to a WAV, with
## optional stems. A native window; the layout lives in ExportAudioDialog.tscn.
##
## It only gathers options and shows progress. Jobs run through RenderService.
class_name ExportAudioDialog extends Window

enum RangeMode { PROJECT, SELECTION }

const DEFAULT_TAIL_SECONDS := 4.0
const BIT_DEPTHS: Array[int] = [16, 24, 32]
const CONFIG_KEY := "export_audio"

@onready var _range_option: OptionButton = %RangeOption
@onready var _range_info: Label = %RangeInfo
@onready var _tail_spin: SpinBox = %TailSpin
@onready var _until_silent: CheckBox = %UntilSilent
@onready var _bit_depth_option: OptionButton = %BitDepthOption
@onready var _path_edit: LineEdit = %PathEdit
@onready var _browse_button: Button = %BrowseButton
@onready var _master_check: CheckBox = %MasterCheck
@onready var _stem_tree: Tree = %StemTree
@onready var _status_label: Label = %StatusLabel
@onready var _progress_bar: ProgressBar = %ProgressBar
@onready var _export_button: Button = %ExportButton
@onready var _cancel_button: Button = %CancelButton
@onready var _file_dialog: FileDialog = %FileDialog

var project: Project = null
var service: RenderService = null
## Selection range supplied by the editor when the dialog opens: {"has", "start", "has_end", "end"}.
var _selection: Dictionary = {}


func _ready() -> void:
	close_requested.connect(_on_close_requested)
	_export_button.pressed.connect(_on_export_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_browse_button.pressed.connect(_on_browse_pressed)
	_file_dialog.file_selected.connect(_on_file_selected)
	_range_option.item_selected.connect(func(_i): _update_range_info())
	_master_check.toggled.connect(func(_on): _update_buttons())
	_path_edit.text_changed.connect(func(_t): _update_buttons())
	_stem_tree.item_edited.connect(_update_buttons)
	_stem_tree.hide_root = true

	_range_option.clear()
	_range_option.add_item("Whole project", RangeMode.PROJECT)
	_range_option.add_item("Selection", RangeMode.SELECTION)
	_bit_depth_option.clear()
	_bit_depth_option.add_item("16-bit", 16)
	_bit_depth_option.add_item("24-bit", 24)
	_bit_depth_option.add_item("32-bit float", 32)
	_bit_depth_option.select(1)
	_tail_spin.value = DEFAULT_TAIL_SECONDS
	_until_silent.button_pressed = true


## Bind the dialog to a project and service, then show it. `selection` is Editor.get_time_range().
func open_for(p_project: Project, p_service: RenderService, selection: Dictionary) -> void:
	_disconnect_service()
	project = p_project
	service = p_service
	_selection = selection
	service.progress_changed.connect(_on_progress)
	service.job_finished.connect(_on_finished)
	service.job_failed.connect(_on_failed)
	service.running_changed.connect(func(_r): _update_buttons())

	var has_selection: bool = selection.get("has", false) and selection.get("has_end", false) \
			and int(selection.get("end", 0)) > int(selection.get("start", 0))
	_range_option.set_item_disabled(RangeMode.SELECTION, not has_selection)
	_range_option.select(RangeMode.SELECTION if has_selection else RangeMode.PROJECT)
	_populate_stems()
	if _path_edit.text == "":
		_path_edit.text = _default_path()
	if not service.is_running:
		_set_status("", 0.0)
	_update_range_info()
	_update_buttons()
	if not Utils.is_test_mode():
		popup_centered()


## Tick range for the chosen option: {"start": int, "end": int}. End is 0 when the project is empty.
func selected_range() -> Dictionary:
	if _range_option.get_selected_id() == RangeMode.SELECTION and _selection.get("has_end", false):
		return {"start": int(_selection.start), "end": int(_selection.end)}
	return {"start": 0, "end": project_end_ticks(project)}


## The last tick any clip instance covers.
static func project_end_ticks(p_project: Project) -> int:
	var end := 0
	if p_project == null:
		return end
	for track in p_project.tracks:
		for instance in track.clip_instances:
			end = maxi(end, instance.get_end_ticks())
	return end


## The options RenderService.start() takes, from the current form state.
func build_options() -> Dictionary:
	var range := selected_range()
	var master_path := _path_edit.text.strip_edges() if _master_check.button_pressed else ""
	var base_path := _path_edit.text.strip_edges()
	var stems: Array = []
	if base_path != "":
		for channel in _checked_channels():
			stems.append({"channel_id": channel.id, "path": stem_path(base_path, channel)})
	return {
		"start_tick": range.start,
		"end_tick": range.end,
		"tail_seconds": _tail_spin.value,
		"until_silent": _until_silent.button_pressed,
		"master_path": master_path,
		"bit_depth": _bit_depth_option.get_selected_id(),
		"stems": stems,
	}


## `<dir>/<base> - <channel name>.wav` next to the master file.
static func stem_path(master_path: String, channel: Channel) -> String:
	var safe := channel.name.validate_filename()
	if safe == "":
		safe = "channel %d" % channel.id
	return "%s/%s - %s.wav" % [master_path.get_base_dir(), master_path.get_file().get_basename(), safe]


func _checked_channels() -> Array[Channel]:
	var result: Array[Channel] = []
	var root := _stem_tree.get_root()
	if root == null:
		return result
	for item in root.get_children():
		if item.is_checked(0):
			result.append(item.get_metadata(0))
	return result


func _populate_stems() -> void:
	_stem_tree.clear()
	var root := _stem_tree.create_item()
	if project == null:
		return
	for channel in project.channels:
		if channel.id == 1:
			continue # the master is the main mix
		var item := _stem_tree.create_item(root)
		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		item.set_editable(0, true)
		item.set_text(0, channel.name)
		item.set_metadata(0, channel)
		item.set_checked(0, false)


func _default_path() -> String:
	var dir := OS.get_system_dir(OS.SYSTEM_DIR_MUSIC)
	if dir == "":
		dir = OS.get_environment("HOME")
	var name := project.project_name.validate_filename() if project else "mix"
	return "%s/%s.wav" % [dir, name if name != "" else "mix"]


func _update_range_info() -> void:
	var range := selected_range()
	if range.end <= range.start or project == null:
		_range_info.text = "Nothing to render"
		return
	var seconds: float = project.tempo_map.seconds_at_tick(range.end, project.tempo, project.ppq) \
			- project.tempo_map.seconds_at_tick(range.start, project.tempo, project.ppq)
	_range_info.text = "%d:%05.2f long" % [int(seconds) / 60, fmod(seconds, 60.0)]
	_update_buttons()


func _update_buttons() -> void:
	var running := service != null and service.is_running
	var range := selected_range() if project else {"start": 0, "end": 0}
	var has_output := _path_edit.text.strip_edges() != "" \
			and (_master_check.button_pressed or not _checked_channels().is_empty())
	_export_button.disabled = running or range.end <= range.start or not has_output
	_cancel_button.text = "Cancel render" if running else "Close"
	_range_option.disabled = running or _range_option.item_count == 0
	_tail_spin.editable = not running
	_until_silent.disabled = running
	_bit_depth_option.disabled = running
	_path_edit.editable = not running
	_browse_button.disabled = running
	_master_check.disabled = running
	_stem_tree.mouse_filter = Control.MOUSE_FILTER_IGNORE if running else Control.MOUSE_FILTER_STOP


func _set_status(text: String, fraction: float) -> void:
	_status_label.text = text
	_progress_bar.value = fraction * 100.0
	_progress_bar.visible = text != ""


func _on_export_pressed() -> void:
	if service == null:
		return
	var job_id := service.start(build_options())
	if job_id != "":
		_set_status("Rendering…", 0.0)
	_update_buttons()


func _on_cancel_pressed() -> void:
	if service != null and service.is_running:
		_cancel_button.disabled = true
		_set_status("Cancelling…", service.progress)
	else:
		hide()


func _on_close_requested() -> void:
	# A running render keeps going; closing only hides the window.
	hide()


func _on_browse_pressed() -> void:
	_file_dialog.current_path = _path_edit.text
	_file_dialog.popup_centered_ratio(0.6)


func _on_file_selected(path: String) -> void:
	if not path.to_lower().ends_with(".wav"):
		path += ".wav"
	_path_edit.text = path
	_update_buttons()


func _on_progress(_job_id: String, fraction: float) -> void:
	_set_status("Rendering… %d%%" % int(fraction * 100.0), fraction)


func _on_finished(_job_id: String, paths: PackedStringArray) -> void:
	_set_status("Done: %d file%s written" % [paths.size(), "" if paths.size() == 1 else "s"], 1.0)
	_cancel_button.disabled = false
	_update_buttons()


func _on_failed(_job_id: String, error: String) -> void:
	_set_status("Cancelled" if error == RenderService.CANCELLED else "Failed: " + error, 0.0)
	_cancel_button.disabled = false
	_update_buttons()


func _disconnect_service() -> void:
	if service == null or not is_instance_valid(service):
		return
	for pair in [[service.progress_changed, _on_progress], [service.job_finished, _on_finished],
			[service.job_failed, _on_failed]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])
