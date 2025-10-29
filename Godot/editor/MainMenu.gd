# MainMenu sets up a main menu with file and edit menus
# It handles signals and actions by itself and calls various Editor.gd methods (open project, undo etc.) 
class_name MainMenu extends MenuBar

enum  MENU { File, Edit }

enum FILE { New, Open, Close, Sep1, Save, Save_As, Sep2, Quit}
enum EDIT { Undo, Redo, Sep1, Scan_Plugins, Scan_Assets, Sep2, Preferences }

enum DialogMode { OPEN, SAVE, SAVE_AS }

@onready var file: PopupMenu = $File
@onready var edit: PopupMenu = $Edit

signal item_pressed(menu_id : int, id : int)

var _current_dialog_mode: DialogMode
var _file_dialog: FileDialog

func _ready() -> void:
	# add file menu items
	file.add_item("New Project", FILE.New)
	file.add_item("Open", FILE.Open)
	file.add_item("Close", FILE.Close)
	file.add_separator("", FILE.Sep1)
	file.add_item("Save", FILE.Save)
	file.add_item("Save As", FILE.Save_As)
	file.add_separator("", FILE.Sep2)
	file.add_item("Quit", FILE.Quit)
	
	# add edit menu items
	edit.add_item("Undo", EDIT.Undo)
	edit.add_item("Redo", EDIT.Redo)
	edit.add_separator("", EDIT.Sep1)
	edit.add_item("Scan Plugins", EDIT.Scan_Plugins)
	edit.add_item("Scan Assets", EDIT.Scan_Assets)
	edit.add_separator("", EDIT.Sep2)
	edit.add_item("Preferences", EDIT.Preferences)
	
	# disable project-dependent items initially (no project open yet)
	_set_project_dependent_items_enabled(false)
	
	# setup listeners
	file.id_pressed.connect(_on_item_pressed.bind(MENU.File))
	edit.id_pressed.connect(_on_item_pressed.bind(MENU.Edit))
	
	# connect to editor signals
	Sonara.editor.project_opened.connect(_on_project_opened)
	Sonara.editor.project_closed.connect(_on_project_closed)
	
	# get file dialog reference and connect to it
	await Sonara.editor.ready

	_file_dialog = Sonara.editor.file_dialog
	_file_dialog.file_selected.connect(_on_file_dialog_file_selected)


func _on_item_pressed(item_id : int, menu_id : int):
	item_pressed.emit(menu_id, item_id)
	
	# Handle file menu actions
	if menu_id == MENU.File:
		match item_id:
			FILE.New:
				_on_new_project()
			FILE.Open:
				_on_open_project()
			FILE.Close:
				_on_close_project()
			FILE.Save:
				_on_save_project()
			FILE.Save_As:
				_on_save_project_as()
			FILE.Quit:
				_on_quit()
	
	# Handle edit menu actions
	elif menu_id == MENU.Edit:
		match item_id:
			EDIT.Undo:
				_on_undo()
			EDIT.Redo:
				_on_redo()
			EDIT.Scan_Plugins:
				_on_scan_plugins()
			EDIT.Scan_Assets:
				_on_scan_assets()
			EDIT.Preferences:
				_on_preferences()


func _on_project_opened(_project: Project) -> void:
	_set_project_dependent_items_enabled(true)


func _on_project_closed() -> void:
	_set_project_dependent_items_enabled(false)


func _set_project_dependent_items_enabled(enabled: bool) -> void:
	# File menu items that require an open project
	file.set_item_disabled(file.get_item_index(FILE.Close), not enabled)
	file.set_item_disabled(file.get_item_index(FILE.Save), not enabled)
	file.set_item_disabled(file.get_item_index(FILE.Save_As), not enabled)
	
	# Edit menu items that require an open project
	edit.set_item_disabled(edit.get_item_index(EDIT.Undo), not enabled)
	edit.set_item_disabled(edit.get_item_index(EDIT.Redo), not enabled)


# ============================================================================
# FILE MENU HANDLERS
# ============================================================================

func _on_new_project() -> void:
	"""Create a new project."""
	# TODO: Prompt to save if current project is modified
	var new_project = Project.new()
	new_project.project_name = "Untitled"
	new_project.created_date = Time.get_unix_time_from_system()
	Sonara.editor.open_project(new_project)
	print("[MainMenu] New project created")


func _on_open_project() -> void:
	"""Show file dialog to open a project."""
	if not _file_dialog:
		push_error("[MainMenu] FileDialog not available")
		return
	
	_current_dialog_mode = DialogMode.OPEN
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = ["*.sonara ; Sonara Project Files"]
	_file_dialog.title = "Open Project"
	_file_dialog.current_dir = Sonara.get_projects_dir()
	_file_dialog.popup_centered_ratio(0.6)


func _on_close_project() -> void:
	"""Close current project."""
	# TODO: Prompt to save if modified
	Sonara.editor.close_project()


func _on_save_project() -> void:
	"""Save current project. Show save dialog if no path."""
	if Sonara.editor.project_path.is_empty():
		_on_save_project_as()
	else:
		Sonara.editor.save_project()


func _on_save_project_as() -> void:
	"""Show file dialog to save project as."""
	if not _file_dialog:
		push_error("[MainMenu] FileDialog not available")	
		return
	
	_current_dialog_mode = DialogMode.SAVE_AS
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = ["*.sonara ; Sonara Project Files"]
	_file_dialog.title = "Save Project As"
	_file_dialog.current_dir = Sonara.get_projects_dir()
	
	# Set current file name if project has a name
	if Sonara.editor.project:
		var filename = Sonara.editor.project.project_name
		if not filename.ends_with(".sonara"):
			filename += ".sonara"
		_file_dialog.current_file = filename
	
	_file_dialog.popup_centered_ratio(0.6)


func _on_quit() -> void:
	"""Quit application."""
	# TODO: Prompt to save if modified
	if Sonara.editor.is_modified:
		print("[MainMenu] Warning: Quitting without saving")

	# Clear project from audio engine and disconnect.
	AudioEngineOSC.send("/project/clear", [])
	
	get_tree().quit()


# ============================================================================
# EDIT MENU HANDLERS
# ============================================================================

func _on_undo() -> void:
	"""Undo last action."""
	# TODO: Implement undo system
	print("[MainMenu] Undo not yet implemented")


func _on_redo() -> void:
	"""Redo last undone action."""
	# TODO: Implement redo system
	print("[MainMenu] Redo not yet implemented")


func _on_scan_plugins() -> void:
	"""Trigger plugin scan via AssetService."""
	print("[MainMenu] Scanning plugins...")
	AssetService.scan_plugins()


func _on_scan_assets() -> void:
	"""Trigger asset rescan (audio, MIDI, SFZ, etc.) via AssetService."""
	print("[MainMenu] Scanning assets...")
	AssetService.scan()


func _on_preferences() -> void:
	"""Show preferences dialog."""
	# TODO: Implement preferences dialog
	print("[MainMenu] Preferences not yet implemented")


# ============================================================================
# FILE DIALOG CALLBACKS
# ============================================================================

func _on_file_dialog_file_selected(path: String) -> void:
	"""Handle file selection from dialog."""
	match _current_dialog_mode:
		DialogMode.OPEN:
			Sonara.editor.load_project(path)
		DialogMode.SAVE_AS:
			# Ensure .sonara extension
			if not path.ends_with(".sonara"):
				path += ".sonara"
			Sonara.editor.save_project(path)
