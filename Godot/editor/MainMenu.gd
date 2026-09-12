# MainMenu sets up a main menu with file and edit menus
# It handles signals and actions by itself and calls various Editor.gd methods (open project, undo etc.) 
class_name MainMenu extends MenuBar

enum  MENU { File, Edit, AI }

enum FILE { New, Open, Close, Sep1, Save, Save_As, Sep2, Quit}
enum EDIT { Undo, Redo, Sep1, Scan_Plugins, Scan_Assets, Sep2, Preferences }
enum AI_ITEMS { Toggle_Assistant, New_Conversation, Test_Connection }

enum DialogMode { OPEN, SAVE, SAVE_AS }

@onready var file: PopupMenu = $File
@onready var edit: PopupMenu = $Edit

signal item_pressed(menu_id : int, id : int)

var _current_dialog_mode: DialogMode
var _file_dialog: FileDialog
var _ai_menu: PopupMenu
var _ai_client: OpenRouterClient

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

	_ai_menu = PopupMenu.new()
	_ai_menu.name = "AI"
	add_child(_ai_menu)
	_ai_menu.add_item("Toggle Assistant", AI_ITEMS.Toggle_Assistant)
	_ai_menu.add_item("New Conversation", AI_ITEMS.New_Conversation)
	_ai_menu.add_item("Test Connection", AI_ITEMS.Test_Connection)
	
	# disable project-dependent items initially (no project open yet)
	_set_project_dependent_items_enabled(false)
	
	# setup listeners
	file.id_pressed.connect(_on_item_pressed.bind(MENU.File))
	edit.id_pressed.connect(_on_item_pressed.bind(MENU.Edit))
	_ai_menu.id_pressed.connect(_on_item_pressed.bind(MENU.AI))
	
	# connect to editor signals
	Sonara.editor.project_opened.connect(_on_project_opened)
	Sonara.editor.project_closed.connect(_on_project_closed)
	Sonara.editor.history.history_changed.connect(_update_undo_redo_menu)
	_update_undo_redo_menu()
	
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
	elif menu_id == MENU.AI:
		match item_id:
			AI_ITEMS.Toggle_Assistant:
				if Sonara.editor:
					Sonara.editor.toggle_assistant()
			AI_ITEMS.New_Conversation:
				var assistant := get_node_or_null("/root/Assistant")
				if assistant:
					assistant.new_conversation()
					if Sonara.editor and Sonara.editor.assistant_panel:
						Sonara.editor.assistant_panel.visible = true
						if Sonara.editor.browser_panel:
							Sonara.editor.browser_panel.visible = false
			AI_ITEMS.Test_Connection:
				_on_test_connection()


func _on_project_opened(_project: Project) -> void:
	_set_project_dependent_items_enabled(true)


func _on_project_closed() -> void:
	_set_project_dependent_items_enabled(false)


func _set_project_dependent_items_enabled(enabled: bool) -> void:
	# File menu items that require an open project
	file.set_item_disabled(file.get_item_index(FILE.Close), not enabled)
	file.set_item_disabled(file.get_item_index(FILE.Save), not enabled)
	file.set_item_disabled(file.get_item_index(FILE.Save_As), not enabled)
	
	# Edit menu undo/redo depend on history, not just project open
	_update_undo_redo_menu()


## Refresh Undo/Redo labels and enabled state from CommandHistory.
func _update_undo_redo_menu() -> void:
	var hist: CommandHistory = Sonara.editor.history if Sonara.editor else null
	var can_undo := hist != null and hist.can_undo()
	var can_redo := hist != null and hist.can_redo()
	var undo_idx := edit.get_item_index(EDIT.Undo)
	var redo_idx := edit.get_item_index(EDIT.Redo)
	edit.set_item_disabled(undo_idx, not can_undo)
	edit.set_item_disabled(redo_idx, not can_redo)
	if can_undo:
		edit.set_item_text(undo_idx, "Undo %s" % hist.undo_name())
	else:
		edit.set_item_text(undo_idx, "Undo")
	if can_redo:
		edit.set_item_text(redo_idx, "Redo %s" % hist.redo_name())
	else:
		edit.set_item_text(redo_idx, "Redo")


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

	# Delegate shutdown to Editor for unified behavior
	Sonara.editor.quit()


# ============================================================================
# EDIT MENU HANDLERS
# ============================================================================

func _on_undo() -> void:
	"""Undo last action."""
	if Sonara.editor:
		Sonara.editor.undo()


func _on_redo() -> void:
	"""Redo last undone action."""
	if Sonara.editor:
		Sonara.editor.redo()


func _on_scan_plugins() -> void:
	"""Trigger plugin scan via AssetService."""
	print("[MainMenu] Scanning plugins...")
	AssetService.scan_plugins()


func _on_scan_assets() -> void:
	"""Trigger asset rescan (audio, MIDI, SFZ, etc.) via AssetService."""
	print("[MainMenu] Scanning assets...")
	AssetService.scan()


func _on_preferences() -> void:
	"""Show settings dialog."""
	if Sonara.editor.settings_dialog:
		Sonara.editor.settings_dialog.popup_centered_size(Vector2(800, 500))
	else:
		push_error("[MainMenu] SettingsDialog not found on Editor")


## Send a one-shot "pong" chat to verify the OpenRouter key and model.
func _on_test_connection() -> void:
	_ensure_ai_client()
	_ai_client.configure_from_settings()
	if not _ai_client.has_api_key():
		print("[AI] Test Connection failed: OpenRouter API key is not set. Add it in Settings → AI.")
		return
	print("[AI] Test Connection: sending ping…")
	_ai_client.test_connection()


## Create the debug OpenRouter client once and wire result logs.
func _ensure_ai_client() -> void:
	if _ai_client != null:
		return
	_ai_client = OpenRouterClient.new()
	add_child(_ai_client)
	_ai_client.text_delta.connect(_on_ai_test_delta)
	_ai_client.message_finished.connect(_on_ai_test_finished)
	_ai_client.request_failed.connect(_on_ai_test_failed)
	_ai_client.request_cancelled.connect(func(): print("[AI] Test Connection cancelled"))


## Streamed assistant text for the connection smoke test.
func _on_ai_test_delta(text: String) -> void:
	print("[AI] Test Connection delta: ", text)


## Completed assistant message from Test Connection.
func _on_ai_test_finished(message: ChatTypes.ChatMessage) -> void:
	print("[AI] Test Connection: ", message.get_text())


## Failed Test Connection (401, network, missing key).
func _on_ai_test_failed(error: ChatTypes.ChatError) -> void:
	print("[AI] Test Connection failed: ", error.message)


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
