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


## Map derived from the channel's instrument: the first Auto source on the root
## chain, a Drum Machine (its pads) or a Layer with zoned slots (its slot note maps,
## spec 006). An unmapped channel gives an empty map (REQ-003).
static func auto_map(channel: Channel) -> NoteMap:
	var map := NoteMap.new()
	var source := find_auto_source(channel)
	if source == null:
		return map
	if AuxReturnSync.is_layer(source):
		return layer_map(source)
	var drum := source
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


## First device on the root chain an Auto map comes from: a Drum Machine, or a
## Layer with at least one zoned slot. A Layer whose slots all play every note
## (plain layering) names nothing, so it isn't a source.
static func find_auto_source(channel: Channel) -> DeviceInstance:
	if channel == null:
		return null
	for device in channel.devices:
		if AuxReturnSync.is_drum_machine(device) or (AuxReturnSync.is_layer(device) and has_zoned_slot(device)):
			return device
	return null


## True when some slot of `layer` doesn't play every note unchanged.
static func has_zoned_slot(layer: DeviceInstance) -> bool:
	for slot in layer.children:
		if not LayerNoteMap.is_full(slot.slot_note_map):
			return true
	return false


## One entry per input note a zoned slot maps. A slot mapping a single note is named
## after the slot ("Kick"); one mapping several is named per output note
## ("Cymbals C#2"). Input notes several zoned slots map join their names
## ("Kick + Snare"). Colours are the slot colours, which a separate slot shares
## with its return channel.
static func layer_map(layer: DeviceInstance) -> NoteMap:
	var map := NoteMap.new()
	map.map_name = layer.get_display_name()
	var names := {}  # input -> PackedStringArray
	var colors := {}  # input -> first slot's colour
	for slot in layer.children:
		var slot_map: PackedByteArray = slot.slot_note_map
		if LayerNoteMap.is_full(slot_map):
			continue
		var ins := LayerNoteMap.inputs(slot_map)
		var slot_name := slot.get_display_name()
		for input in ins:
			var entry := slot_name if ins.size() == 1 else "%s %s" % [slot_name, Midi.midi_to_note_name(slot_map[input])]
			if not names.has(input):
				names[input] = PackedStringArray()
				colors[input] = layer.slot_color(layer.slot_key_for(slot))
			names[input].append(entry)
	for input in names:
		map.set_entry(input, " + ".join(names[input]), colors[input])
	return map


## Whether an Auto map would have a source to derive from. Drives the Drum View
## default for a channel the user has never switched by hand (REQ-028).
static func has_auto_source(channel: Channel) -> bool:
	return find_auto_source(channel) != null


## Effective map for the channel a track plays through.
static func for_track(project: Project, track: Track) -> NoteMap:
	if project == null or track == null:
		return NoteMap.new()
	return effective_map(project.get_channel_by_id(track.default_channel_id))


## Whether a channel's clips should open in Drum View (REQ-028). An explicit
## choice wins; otherwise Drum View is the default when the map comes from a
## Drum Machine or a zoned Layer.
static func wants_drum_view(channel: Channel) -> bool:
	if channel == null:
		return false
	if channel.drum_view >= 0:
		return channel.drum_view == 1
	return channel.note_map_mode == Channel.NoteMapMode.AUTO and has_auto_source(channel)
