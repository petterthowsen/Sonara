# VisibilityPresets.gd
# Spec 047: the project's named visibility presets. Each is an ordered snapshot of which tracks have
# their own `hidden` flag set (not the cascaded state, so children of a hidden folder do not stick
# hidden after the folder is shown again). `active_index` is the preset last applied or saved, or -1.
# Pure data: TrackVisibility applies and records the changes, and undo goes through
# snapshot()/restore().
class_name VisibilityPresets extends RefCounted

signal changed()

## Each preset is {name: String, hidden_track_ids: Array[int]} (IDs sorted, no duplicates).
var presets: Array[Dictionary] = []

## Index of the active preset, or -1 for none ("All" or a custom state).
var active_index: int = -1


func count() -> int:
	return presets.size()


## The preset at `index` (a copy), or an empty Dictionary when out of range.
func get_preset(index: int) -> Dictionary:
	if index < 0 or index >= presets.size():
		return {}
	return presets[index].duplicate(true)


## Selector text for preset `index`: its 1-based position and name, e.g. "1: Orchestra".
func display_name(index: int) -> String:
	if index < 0 or index >= presets.size():
		return ""
	return "%d: %s" % [index + 1, presets[index]["name"]]


## Append a preset holding `hidden_ids` and return its index. Does not change the active preset.
func add(preset_name: String, hidden_ids: Array) -> int:
	presets.append({"name": preset_name, "hidden_track_ids": _clean_ids(hidden_ids)})
	changed.emit()
	return presets.size() - 1


func rename(index: int, preset_name: String) -> void:
	if index < 0 or index >= presets.size() or presets[index]["name"] == preset_name:
		return
	presets[index]["name"] = preset_name
	changed.emit()


## Remove preset `index`. `active_index` follows the same preset, or becomes -1 when it was removed.
func remove(index: int) -> void:
	if index < 0 or index >= presets.size():
		return
	presets.remove_at(index)
	if active_index == index:
		active_index = -1
	elif active_index > index:
		active_index -= 1
	changed.emit()


## Move preset `from` to position `to`. `active_index` keeps pointing at the same preset.
func move(from: int, to: int) -> void:
	if from < 0 or from >= presets.size():
		return
	to = clampi(to, 0, presets.size() - 1)
	if from == to:
		return
	var preset: Dictionary = presets[from]
	presets.remove_at(from)
	presets.insert(to, preset)
	if active_index == from:
		active_index = to
	elif from < active_index and active_index <= to:
		active_index -= 1
	elif to <= active_index and active_index < from:
		active_index += 1
	changed.emit()


func set_hidden_ids(index: int, hidden_ids: Array) -> void:
	if index < 0 or index >= presets.size():
		return
	var ids := _clean_ids(hidden_ids)
	if presets[index]["hidden_track_ids"] == ids:
		return
	presets[index]["hidden_track_ids"] = ids
	changed.emit()


## Make preset `index` the active one; anything out of range means no active preset.
func set_active(index: int) -> void:
	if index < 0 or index >= presets.size():
		index = -1
	if active_index == index:
		return
	active_index = index
	changed.emit()


## Deep copy of the whole state, for undo: {presets: Array[Dictionary], active: int}.
func snapshot() -> Dictionary:
	return {"presets": presets.duplicate(true), "active": active_index}


func restore(snap: Dictionary) -> void:
	presets.clear()
	for preset in snap.get("presets", []):
		presets.append((preset as Dictionary).duplicate(true))
	active_index = int(snap.get("active", -1))
	if active_index < 0 or active_index >= presets.size():
		active_index = -1
	changed.emit()


## Drop stored IDs that are not keys of `existing` (track ID -> anything). No signal: this only
## cleans a freshly loaded project.
func prune(existing: Dictionary) -> void:
	for preset in presets:
		preset["hidden_track_ids"] = _filter_ids(preset["hidden_track_ids"], existing)


## {active, presets: [{name, hidden_track_ids}]}. With `existing` (track ID -> anything), IDs of
## tracks that no longer exist are left out; they stay in memory so undoing a track delete brings
## the track back into its presets.
func to_json(existing: Variant = null) -> Dictionary:
	var out: Array = []
	for preset in presets:
		var ids: Array = preset["hidden_track_ids"]
		if existing is Dictionary:
			ids = _filter_ids(ids, existing)
		out.append({"name": preset["name"], "hidden_track_ids": ids.duplicate()})
	return {"active": active_index, "presets": out}


## Tolerates a missing or malformed value (empty list, no active preset).
static func from_json(data: Variant) -> VisibilityPresets:
	var result := VisibilityPresets.new()
	if not data is Dictionary:
		return result
	var entries: Variant = data.get("presets", [])
	if entries is Array:
		for entry in entries:
			if not entry is Dictionary:
				continue
			var raw_ids: Variant = entry.get("hidden_track_ids", [])
			result.presets.append({
				"name": str(entry.get("name", "")),
				"hidden_track_ids": result._clean_ids(raw_ids if raw_ids is Array else []),
			})
	var active := int(data.get("active", -1))
	result.active_index = active if active >= 0 and active < result.presets.size() else -1
	return result


## Sorted, de-duplicated integer IDs.
func _clean_ids(ids: Array) -> Array[int]:
	var out: Array[int] = []
	for id in ids:
		var value := int(id)
		if not out.has(value):
			out.append(value)
	out.sort()
	return out


func _filter_ids(ids: Array, existing: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for id in ids:
		if existing.has(int(id)):
			out.append(int(id))
	return out
