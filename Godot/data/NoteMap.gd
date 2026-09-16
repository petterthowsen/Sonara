# A set of labels and colours for MIDI pitches.
#
# At most one entry per pitch (0-127). A pitch with no entry is *unmapped*.
# The same serialized shape is used both for library files under
# ~/.config/sonara/note_maps/ and for the copy embedded in a channel, so one
# serializer covers both.
#
# Maps are labels only: nothing here is ever sent to the engine.
class_name NoteMap extends RefCounted

## Display name. Empty for Auto and unnamed maps.
var map_name := ""

## Free-form grouping used by the library browser, e.g. "Drums".
var category := ""

## Who authored the map.
var author := ""

## pitch (int) -> {"name": String, "color": Color}
var entries := {}


func _init(name_value := "", category_value := "", author_value := "") -> void:
	map_name = name_value
	category = category_value
	author = author_value


## Entry name for a pitch, or "" when unmapped.
func get_name(pitch: int) -> String:
	var entry: Variant = entries.get(pitch)
	return String(entry.get("name", "")) if entry is Dictionary else ""


## Entry colour for a pitch, or a fully transparent colour when unmapped, so
## callers can test `.a > 0` instead of looking the entry up twice.
func get_color(pitch: int) -> Color:
	var entry: Variant = entries.get(pitch)
	if entry is Dictionary and entry.has("color"):
		return entry["color"]
	return Color(0, 0, 0, 0)


func has_entry(pitch: int) -> bool:
	return entries.has(pitch)


## Add or replace an entry. Pitches outside 0-127 are ignored.
func set_entry(pitch: int, name_value: String, color_value: Color) -> void:
	if pitch < Midi.MIDI_MIN or pitch > Midi.MIDI_MAX:
		return
	entries[pitch] = {"name": name_value, "color": color_value}


func erase_entry(pitch: int) -> void:
	entries.erase(pitch)


func is_empty() -> bool:
	return entries.is_empty()


## Mapped pitches, ascending.
func pitches() -> PackedInt32Array:
	var out := PackedInt32Array()
	for pitch in entries.keys():
		out.append(int(pitch))
	out.sort()
	return out


## A deep copy. Assigning a library map to a channel stores a copy, so later
## channel edits never reach back into the library (REQ-026).
func duplicate_map() -> NoteMap:
	var copy := NoteMap.new(map_name, category, author)
	for pitch in entries.keys():
		var entry: Dictionary = entries[pitch]
		copy.entries[int(pitch)] = {"name": entry.get("name", ""), "color": entry.get("color", Color.WHITE)}
	return copy


func to_json() -> Dictionary:
	var out_entries := {}
	for pitch in pitches():
		var entry: Dictionary = entries[pitch]
		out_entries[str(pitch)] = {
			"name": String(entry.get("name", "")),
			"color": Color(entry.get("color", Color.WHITE)).to_html(false),
		}
	return {
		"name": map_name,
		"category": category,
		"author": author,
		"entries": out_entries,
	}


static func from_json(data: Variant) -> NoteMap:
	if not (data is Dictionary):
		return NoteMap.new()
	var map := NoteMap.new(
		String(data.get("name", "")),
		String(data.get("category", "")),
		String(data.get("author", "")),
	)
	var raw: Variant = data.get("entries", {})
	if raw is Dictionary:
		for key in raw.keys():
			# JSON object keys are always strings; a Dictionary round-tripped in
			# memory may still hold ints.
			var pitch := int(str(key))
			var entry: Variant = raw[key]
			if not (entry is Dictionary):
				continue
			map.set_entry(
				pitch,
				String(entry.get("name", "")),
				Utils.color_from_json(entry.get("color"), Color.WHITE),
			)
	return map
