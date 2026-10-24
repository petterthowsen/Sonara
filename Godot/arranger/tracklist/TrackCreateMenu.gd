## The "add a track" choices, shared by the arranger's + button menu and the tracklist's
## right-click menu so the two lists cannot drift apart.
class_name TrackCreateMenu extends RefCounted

## Menu item ids. They double as indexes into `ITEMS`.
enum Item { INSTRUMENT, AUDIO, EMPTY, FOLDER, GROUP }

## One entry per `Item`: menu label and the `TrackCreateCommand` kind.
const ITEMS: Array[Dictionary] = [
	{"label": "Instrument Track", "kind": "instrument"},
	{"label": "Audio Track", "kind": "audio"},
	{"label": "Empty Track", "kind": "track"},
	{"label": "Folder Track", "kind": "folder"},
	{"label": "Group Track", "kind": "group"},
]


## Add every entry to `menu`, with the `Item` value as the id.
static func populate(menu: PopupMenu) -> void:
	for id in ITEMS.size():
		menu.add_item(ITEMS[id]["label"], id)


## Create the track for menu item `id` in `project` as one undo step; returns the command
## (its `track` and `channel` are set), or null when there is no project or the id is unknown.
static func create(project: Project, id: int) -> TrackCreateCommand:
	if project == null or id < 0 or id >= ITEMS.size():
		return null
	var kind: String = ITEMS[id]["kind"]
	var cmd := TrackCreateCommand.new(project, kind, _next_name(project, id))
	HistoryUtil.execute(cmd)
	if cmd.track != null and cmd.channel != null:
		cmd.track.color = cmd.channel.color
	if cmd.track != null and Sonara and Sonara.editor and Sonara.editor.has_method("select_tracks"):
		Sonara.editor.select_tracks([cmd.track] as Array[Track], cmd.track)
	return cmd


## "Folder N" / "Group N" count their own kind, everything else is "Track N" by track count.
static func _next_name(project: Project, id: int) -> String:
	match id:
		Item.FOLDER:
			return "Folder %d" % (_count_type(project, Track.TrackType.FOLDER) + 1)
		Item.GROUP:
			return "Group %d" % (_count_type(project, Track.TrackType.GROUP) + 1)
	return "Track %d" % (project.tracks.size() + 1)


static func _count_type(project: Project, type: int) -> int:
	var count := 0
	for track in project.tracks:
		if track.type == type:
			count += 1
	return count
