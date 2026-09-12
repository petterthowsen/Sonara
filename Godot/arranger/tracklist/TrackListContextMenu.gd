# Right-click PopupMenu for empty area in Tracklist
# - + instrument track
# - + audio track
# - + folder track
# - + group track (folder with a bus)
class_name TrackListContextMenu extends PopupMenu

enum Item {
	INSTRUMENT_TRACK,
	AUDIO_TRACK,
	FOLDER_TRACK,
	GROUP_TRACK
}

func _init() -> void:
	# add items to the popup menu
	add_item("New Instrument Track", Item.INSTRUMENT_TRACK)
	add_item("New Audio Track", Item.AUDIO_TRACK)
	add_item("New Folder Track", Item.FOLDER_TRACK)
	add_item("New Group Track", Item.GROUP_TRACK)

func _ready() -> void:
	# listen to edior project sate  
	Sonara.editor.project_activated.connect(_on_project_activated)
	Sonara.editor.project_closed.connect(_on_project_closed)
	id_pressed.connect(_on_item_pressed)

func _on_project_activated(_project: Project) -> void:
	# enable all items
	for i in range(get_item_count()):
		set_item_disabled(i, false)

func _on_project_closed() -> void:
	# disable all items
	for i in range(get_item_count()):
		set_item_disabled(i, true)


func _on_item_pressed(id: int) -> void:
	var project := Sonara.editor.project

	match id:
		Item.INSTRUMENT_TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "instrument"))
		Item.AUDIO_TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "audio"))
		Item.FOLDER_TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "folder", "Folder"))
		Item.GROUP_TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "group", "Group"))
