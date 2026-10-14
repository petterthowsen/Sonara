# Right-click PopupMenu for empty area in Tracklist.
# Offers the same track kinds as the arranger's + button (TrackCreateMenu).
class_name TrackListContextMenu extends PopupMenu

func _init() -> void:
	TrackCreateMenu.populate(self)

func _ready() -> void:
	id_pressed.connect(_on_item_pressed)
	# listen to editor project state (no editor in headless tests)
	if Sonara and Sonara.editor:
		Sonara.editor.project_activated.connect(_on_project_activated)
		Sonara.editor.project_closed.connect(_on_project_closed)

func _on_project_activated(_project: Project) -> void:
	# enable all items
	for i in range(get_item_count()):
		set_item_disabled(i, false)

func _on_project_closed() -> void:
	# disable all items
	for i in range(get_item_count()):
		set_item_disabled(i, true)


func _on_item_pressed(id: int) -> void:
	TrackCreateMenu.create(Sonara.editor.project, id)
