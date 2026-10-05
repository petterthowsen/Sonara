## Loads the NoteValueDescriptor resources a value lane can show.
class_name NoteValueDescriptors extends RefCounted

const DIR := "res://clip_editor/value_lanes/descriptors/"
## Display order in the "+ Lane" menu.
const KEYS: Array[String] = ["vel", "rel"]

static var _cache: Dictionary = {}


static func all() -> Array[NoteValueDescriptor]:
	var out: Array[NoteValueDescriptor] = []
	for k in KEYS:
		var d := by_key(k)
		if d != null:
			out.append(d)
	return out


static func by_key(key: String) -> NoteValueDescriptor:
	if _cache.has(key):
		return _cache[key]
	var path := DIR + _file_for(key)
	var d: NoteValueDescriptor = load(path) as NoteValueDescriptor if ResourceLoader.exists(path) else null
	_cache[key] = d
	return d


static func _file_for(key: String) -> String:
	match key:
		"vel": return "velocity.tres"
		"rel": return "release.tres"
	return key + ".tres"


## Current display mode setting ("0–127" or "Percent").
static func display_mode() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	var settings := tree.root.get_node_or_null("Settings") if tree else null
	if settings == null:
		return NoteValueDescriptor.DISPLAY_MIDI
	return str(settings.get_value(NoteValueDescriptor.DISPLAY_SETTING))
