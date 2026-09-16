# Works out which NoteMap the clip editor (and the assistant) should use for a
# channel or track.
#
# Auto maps are derived on demand rather than stored, which is what makes them
# follow pad renames, moves and colour changes for free (REQ-004). Resolving walks
# a handful of devices, so callers still cache the result and refresh on
# NoteMapWatcher.changed rather than resolving every frame.
class_name NoteMapResolver extends RefCounted


## The map a channel's clips should be labelled with. Never null: an unmapped
## channel resolves to an empty map so callers don't have to null-check.
static func effective_map(channel: Channel) -> NoteMap:
	if channel == null:
		return NoteMap.new()
	match channel.note_map_mode:
		Channel.NoteMapMode.NONE:
			return NoteMap.new()
		Channel.NoteMapMode.NAMED:
			return channel.note_map if channel.note_map else NoteMap.new()
		_:
			return auto_map(channel)


## Map derived from the channel's instrument. Today the only source is a Drum
## Machine on the root chain; an unmapped channel gives an empty map (REQ-003).
static func auto_map(channel: Channel) -> NoteMap:
	var map := NoteMap.new()
	var drum := find_drum_machine(channel)
	if drum == null:
		return map
	map.map_name = drum.get_display_name()
	var project := channel.get_project()
	for i in drum.children.size():
		var pad: DeviceInstance = drum.children[i]
		# Pads with no device aren't children at all, so a pad note only appears
		# here once something is loaded on it (REQ-002).
		if pad == null or pad.slot_note < 0:
			continue
		var color := Color.WHITE
		var ret := AuxReturnSync.get_return_channel(project, drum, i) if project else null
		if ret:
			color = ret.color
		map.set_entry(pad.slot_note, pad.get_display_name(), color)
	return map


## First Drum Machine on the channel's root device chain, or null.
static func find_drum_machine(channel: Channel) -> DeviceInstance:
	if channel == null:
		return null
	for device in channel.devices:
		if AuxReturnSync.is_drum_machine(device):
			return device
	return null


## Whether an Auto map would have a source to derive from. Drives the Drum View
## default for a channel the user has never switched by hand (REQ-028).
static func has_auto_source(channel: Channel) -> bool:
	return find_drum_machine(channel) != null


## Effective map for the channel a track plays through.
static func for_track(project: Project, track: Track) -> NoteMap:
	if project == null or track == null:
		return NoteMap.new()
	return effective_map(project.get_channel_by_id(track.default_channel_id))


## Whether a channel's clips should open in Drum View (REQ-028). An explicit
## choice wins; otherwise Drum View is the default when the map comes from a
## Drum Machine.
static func wants_drum_view(channel: Channel) -> bool:
	if channel == null:
		return false
	if channel.drum_view >= 0:
		return channel.drum_view == 1
	return channel.note_map_mode == Channel.NoteMapMode.AUTO and has_auto_source(channel)
