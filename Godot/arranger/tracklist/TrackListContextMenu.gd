# Right-click PopupMenu for empty area in Tracklist
# - + track (no channel; routed later from the track's own menu)
# - + instrument track
# - + audio track
# - + folder track
# - + group track (TrackType.GROUP + ChannelType.GROUP)
class_name TrackListContextMenu extends PopupMenu

enum Item {
	TRACK,
	INSTRUMENT_TRACK,
	AUDIO_TRACK,
	FOLDER_TRACK,
	GROUP_TRACK
}

func _init() -> void:
	# add items to the popup menu
	add_item("New Track", Item.TRACK)
	add_item("New Instrument Track", Item.INSTRUMENT_TRACK)
	add_item("New Audio Track", Item.AUDIO_TRACK)
	add_item("New Folder Track", Item.FOLDER_TRACK)
	add_item("New Group Track", Item.GROUP_TRACK)

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
	var project := Sonara.editor.project

	match id:
		Item.TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "track"))
		Item.INSTRUMENT_TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "instrument"))
		Item.AUDIO_TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "audio"))
		Item.FOLDER_TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "folder", "Folder"))
		Item.GROUP_TRACK:
			HistoryUtil.execute(TrackCreateCommand.new(project, "group", "Group"))
