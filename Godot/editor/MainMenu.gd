class_name MainMenu extends MenuBar

enum  MENU { File, Edit }

enum FILE { New, Open, Close, Sep1, Save, Save_As, Sep2, Quit}
enum EDIT { Undo, Redo, Sep1, Preferences }

@onready var file: PopupMenu = $File
@onready var edit: PopupMenu = $Edit

signal item_pressed(menu_id : int, id : int)

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
	edit.add_item("Preferences", EDIT.Preferences)
	
	# setup listeners
	file.id_pressed.connect(_on_item_pressed.bind(MENU.File))
	edit.id_pressed.connect(_on_item_pressed.bind(MENU.Edit))
	
	# connect to editor signals
	if Sonara.editor:
		Sonara.editor.project_opened.connect(_on_project_opened)
		Sonara.editor.project_closed.connect(_on_project_closed)
	
	# disable project-dependent items initially (no project open yet)
	_set_project_dependent_items_enabled(false)


func _on_item_pressed(item_id : int, menu_id : int):
	item_pressed.emit(menu_id, item_id)


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
