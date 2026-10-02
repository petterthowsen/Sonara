# Works out which NoteMap the clip editor (and the assistant) should use for a
# channel or track.
#
# Auto maps are derived on demand rather than stored, which is what makes them
# follow pad renames, moves and colour changes for free (REQ-004). Resolving walks
# a handful of devices, so callers still cache the result and refresh on
# NoteMapWatcher.changed rather than resolving every frame.
class_name NoteMapResolver extends RefCounted

## SFZ keys the file labels (`label_key`): neutral, they are ordinary notes.
const SFZ_KEY_COLOR := Color(0.62, 0.66, 0.72)
## SFZ keyswitch keys (`sw_last`): amber, so they read as switches rather than notes.
const SFZ_KEYSWITCH_COLOR := Color(0.93, 0.62, 0.2)
const SFZ_KEYSWITCH_FALLBACK_NAME := "Keyswitch"


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
## chain, a Drum Machine (its pads), a Layer with zoned slots (its slot note maps,
## spec 006) or an SFZ sampler with labelled keys (spec 014). An unmapped channel gives an empty map (REQ-003).
static func auto_map(channel: Channel) -> NoteMap:
	var map := NoteMap.new()
	var source := find_auto_source(channel)
	if source == null:
		return map
	if AuxReturnSync.is_layer(source):
		return layer_map(source)
	if AuxReturnSync.is_sfz(source):
		return sfz_map(source)
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


## First device on the root chain an Auto map comes from: a Drum Machine, a
## Layer with at least one zoned slot, or an SFZ sampler that has labelled keys or playable
## ranges. A Layer whose slots all play every note (plain layering) and an SFZ that told
## us nothing name nothing, so they aren't sources.
static func find_auto_source(channel: Channel) -> DeviceInstance:
	if channel == null:
		return null
	for device in channel.devices:
		if _is_row_source(device) or (AuxReturnSync.is_sfz(device) and _has_key_info(device)):
			return device
	return null


## An SFZ is a source once it has named keys or known playable ranges.
static func _has_key_info(sfz: DeviceInstance) -> bool:
	return not sfz.key_labels.is_empty() or not sfz.playable_ranges.is_empty()


## Drum Machine or zoned Layer: a source whose notes are rows (pads / slots), so Drum View
## fits it. An SFZ only labels keys of a normal piano roll.
static func _is_row_source(device: DeviceInstance) -> bool:
	return AuxReturnSync.is_drum_machine(device) or (AuxReturnSync.is_layer(device) and has_zoned_slot(device))


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


## One entry per key the SFZ names. Keyswitches take the keyswitch colour and fall back
## to "Keyswitch" when the file gives no `sw_label`.
static func sfz_map(sfz: DeviceInstance) -> NoteMap:
	var map := NoteMap.new()
	map.map_name = sfz.get_display_name()
	map.playable_ranges = sfz.playable_ranges.duplicate(true)
	for info in sfz.key_labels:
		if info.keyswitch:
			var label: String = info.label
			map.set_entry(info.key, label if not label.is_empty() else SFZ_KEYSWITCH_FALLBACK_NAME, SFZ_KEYSWITCH_COLOR)
		else:
			map.set_entry(info.key, info.label, SFZ_KEY_COLOR)
	return map


## Whether an Auto map would have a source to derive from (labelling).
static func has_auto_source(channel: Channel) -> bool:
	return find_auto_source(channel) != null


## Whether the Auto source is made of rows (Drum Machine, zoned Layer). Drives the Drum
## View default for a channel the user has never switched by hand (REQ-028); an SFZ
## source labels keys but never turns on Drum View.
static func has_row_source(channel: Channel) -> bool:
	var source := find_auto_source(channel)
	return source != null and _is_row_source(source)


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
	return channel.note_map_mode == Channel.NoteMapMode.AUTO and has_row_source(channel)
