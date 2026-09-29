# test_layer_note_map.gd
# Headless tests for Layer slot note maps (docs/specs/006-layer-note-mapping): the pure
# LayerNoteMap helpers, including the REQ-014 / REQ-015 examples verbatim, plus the
# DeviceInstance slot map setter, undo, and persistence (REQ-016).
#
# Project and DeviceInstance reference autoloads by bare name, so they're load()ed in run_tests().
# Run: godot --headless --path Godot -s tests/test_layer_note_map.gd -- --test
extends TestBase

const LAYER_ID := "sonara.builtin.layer"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _history_script: GDScript
var _property_command: GDScript


func suite_name() -> String:
	return "Layer note map tests"


func run_tests() -> void:
	_test_full_and_empty()
	_test_first_edit_empties_full_map()
	_test_connect_range()
	_test_disconnect()
	_test_shift()
	_test_shift_out_of_range_is_noop()
	_test_resolve_overlaps_example()
	_test_resolve_leaves_full_maps()
	_test_distribute_example()
	_test_distribute_overflow_skips()
	_test_json_round_trip()

	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_property_command = load("res://history/commands/PropertyCommand.gd")
	_test_slot_defaults()
	_test_slot_setter_undo()
	_test_slot_setter_rejects_invalid()
	_test_project_round_trip()
	_test_legacy_json_loads_full()
	_test_slot_sync_sends_map()
	_test_auto_map_from_layer()
	await _test_auto_map_watcher()


# --- helpers ---------------------------------------------------------------

## A map with only the given {input: output} pairs.
func _map(pairs: Dictionary) -> PackedByteArray:
	var map := LayerNoteMap.empty()
	for input in pairs:
		map[input] = pairs[input]
	return map


## {input: output} for every mapped input.
func _pairs(map: PackedByteArray) -> Dictionary:
	var out := {}
	for input in LayerNoteMap.inputs(map):
		out[input] = map[input]
	return out


# --- basics ----------------------------------------------------------------

func _test_full_and_empty() -> void:
	var full := LayerNoteMap.full()
	_assert(full.size() == 128 and LayerNoteMap.is_full(full), "full map is identity")
	_assert(LayerNoteMap.inputs(full).size() == 128, "full map maps every input")
	var empty := LayerNoteMap.empty()
	_assert(not LayerNoteMap.is_full(empty), "empty map isn't full")
	_assert(LayerNoteMap.inputs(empty).is_empty(), "empty map maps nothing")
	_assert(LayerNoteMap.output_of(empty, 36) == -1, "unmapped output is -1")


func _test_first_edit_empties_full_map() -> void:
	var map := LayerNoteMap.connect_note(LayerNoteMap.full(), 42, 49)
	_assert(_pairs(map) == {42: 49}, "first connect on a full map maps only that note (got %s)" % _pairs(map))


func _test_connect_range() -> void:
	var map := LayerNoteMap.connect_range(LayerNoteMap.empty(), PackedInt32Array([40, 37, 38]), 49)
	_assert(_pairs(map) == {37: 49, 38: 50, 40: 51}, "range connects in pitch order (got %s)" % _pairs(map))
	var edge := LayerNoteMap.connect_range(LayerNoteMap.empty(), PackedInt32Array([1, 2, 3]), 126)
	_assert(_pairs(edge) == {1: 126, 2: 127}, "range stops at 127 (got %s)" % _pairs(edge))


func _test_disconnect() -> void:
	var map := LayerNoteMap.disconnect_notes(_map({36: 36, 38: 40}), PackedInt32Array([36]))
	_assert(_pairs(map) == {38: 40}, "disconnect removes only the given input")
	var from_full := LayerNoteMap.disconnect_notes(LayerNoteMap.full(), PackedInt32Array([60]))
	_assert(LayerNoteMap.inputs(from_full).is_empty(), "disconnect on a full map leaves it empty")


func _test_shift() -> void:
	# REQ-011 example: Snare inputs 37–40 shifted up 12 keep their outputs.
	var map := _map({37: 38, 38: 40, 39: 41, 40: 43})
	var shifted := LayerNoteMap.shift(map, PackedInt32Array([37, 38, 39, 40]), 12)
	_assert(_pairs(shifted) == {49: 38, 50: 40, 51: 41, 52: 43}, "shift +12 (got %s)" % _pairs(shifted))
	# Overlapping move: shifting 36,37 up by 1 must not lose 37's mapping.
	var overlap := LayerNoteMap.shift(_map({36: 1, 37: 2}), PackedInt32Array([36, 37]), 1)
	_assert(_pairs(overlap) == {37: 1, 38: 2}, "overlapping shift keeps every entry (got %s)" % _pairs(overlap))


func _test_shift_out_of_range_is_noop() -> void:
	var map := _map({126: 1, 127: 2})
	var shifted := LayerNoteMap.shift(map, PackedInt32Array([126, 127]), 1)
	_assert(shifted == map, "shift past 127 leaves the map unchanged")


# --- automatic assignment --------------------------------------------------

func _test_resolve_overlaps_example() -> void:
	var kick := _map({36: 36})
	var snare := _map({36: 38, 37: 40})
	var cymbals := _map({49: 49, 51: 51})
	var res := LayerNoteMap.resolve_overlaps([kick, snare, cymbals])
	var maps: Array = res["maps"]
	_assert(_pairs(maps[0]) == {36: 36}, "kick keeps 36")
	_assert(_pairs(maps[1]) == {37: 38, 38: 40}, "snare shifts +1 to 37–38 (got %s)" % _pairs(maps[1]))
	_assert(_pairs(maps[2]) == {49: 49, 51: 51}, "cymbals untouched")
	_assert(res["skipped"].is_empty(), "nothing skipped")


func _test_resolve_leaves_full_maps() -> void:
	var res := LayerNoteMap.resolve_overlaps([LayerNoteMap.full(), _map({36: 36}), _map({36: 50})])
	var maps: Array = res["maps"]
	_assert(LayerNoteMap.is_full(maps[0]), "full map left alone")
	_assert(_pairs(maps[1]) == {36: 36}, "first zoned slot kept (full maps don't count as overlap)")
	_assert(_pairs(maps[2]) == {37: 50}, "second zoned slot shifted up (got %s)" % _pairs(maps[2]))


func _test_distribute_example() -> void:
	var kick := _map({36: 36})
	var snare := _map({38: 38, 40: 40})
	var cymbals := _map({49: 49, 51: 51, 57: 57})
	var pad := LayerNoteMap.full()
	var res := LayerNoteMap.distribute([kick, snare, pad, cymbals])
	var maps: Array = res["maps"]
	_assert(_pairs(maps[0]) == {36: 36}, "kick at 36")
	_assert(_pairs(maps[1]) == {37: 38, 38: 40}, "snare at 37–38 (got %s)" % _pairs(maps[1]))
	_assert(LayerNoteMap.is_full(maps[2]), "full-map pad left alone")
	_assert(_pairs(maps[3]) == {39: 49, 40: 51, 41: 57}, "cymbals at 39–41 (got %s)" % _pairs(maps[3]))
	_assert(res["skipped"].is_empty(), "nothing skipped")


func _test_distribute_overflow_skips() -> void:
	var big := LayerNoteMap.empty()
	for i in 90:
		big[i] = i
	var small := _map({100: 100})
	var huge := LayerNoteMap.empty()
	for i in 10:
		huge[i] = i
	var res := LayerNoteMap.distribute([big, huge, small])
	# big takes 36–125; huge (10 notes) can't fit; small fits at 126.
	_assert(res["skipped"] == [1], "slot past 127 is skipped (got %s)" % [res["skipped"]])
	_assert(res["maps"][1] == huge, "skipped slot unchanged")
	_assert(_pairs(res["maps"][2]) == {126: 100}, "later slot still placed (got %s)" % _pairs(res["maps"][2]))


# --- persistence helpers ---------------------------------------------------

func _test_json_round_trip() -> void:
	_assert(LayerNoteMap.to_json(LayerNoteMap.full()) == null, "full map serializes as null")
	var map := _map({42: 49, 44: 57})
	var json = JSON.parse_string(JSON.stringify(LayerNoteMap.to_json(map)))
	_assert(LayerNoteMap.from_json(json) == map, "zoned map survives a JSON round trip")
	_assert(LayerNoteMap.is_full(LayerNoteMap.from_json(null)), "missing key loads as full")
	_assert(LayerNoteMap.is_full(LayerNoteMap.from_json([1, 2])), "malformed key loads as full")


# --- model -----------------------------------------------------------------

## DeviceInstance of a (registered) fake built-in device, so saved projects can load it back.
func _device(ch: Object, device_id: String, title: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
		registry._devices[device_id] = device
	return _device_instance_script.new(device, ch.id, 0)


## Instrument channel holding a Layer with slots named `names`. Returns {project, channel, layer, slots}.
func _layer(names: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var layer := _device(ch, LAYER_ID, "Layer")
	ch.add_device(layer)
	var slots: Array = []
	for n in names:
		var slot := _device(ch, "sonara.builtin.polysynth", "PolySynth")
		slot.name = n
		ch.add_device(slot, -1, layer)
		slots.append(slot)
	return {"project": project, "channel": ch, "layer": layer, "slots": slots}


func _test_slot_defaults() -> void:
	var d := _layer(["Kick"])
	var slot: Object = d.slots[0]
	_assert(LayerNoteMap.is_full(slot.slot_note_map), "REQ-003: new slot has the full map")
	_assert(not slot.slot_separate_out, "new slot has separate output off")


func _test_slot_setter_undo() -> void:
	var d := _layer(["Cymbals"])
	var slot: Object = d.slots[0]
	var hist: Object = _history_script.new()
	var zoned := LayerNoteMap.connect_note(slot.slot_note_map, 42, 49)
	hist.execute(_property_command.new("Edit Layer Mapping", slot, "set_slot_note_map", slot.slot_note_map, zoned))
	_assert(_pairs(slot.slot_note_map) == {42: 49}, "REQ-011: setter applies the map")
	hist.undo()
	_assert(LayerNoteMap.is_full(slot.slot_note_map), "REQ-011: undo restores the full map")
	hist.redo()
	_assert(_pairs(slot.slot_note_map) == {42: 49}, "REQ-011: redo reapplies the map")
	# The model keeps its own copy: mutating the array passed in changes nothing.
	zoned[42] = 1
	_assert(slot.slot_note_map[42] == 49, "setter copies the map")


func _test_slot_setter_rejects_invalid() -> void:
	var d := _layer(["Kick"])
	var slot: Object = d.slots[0]
	slot.set_slot_note_map(PackedByteArray([1, 2, 3]))
	_assert(LayerNoteMap.is_full(slot.slot_note_map), "invalid map ignored")


func _test_project_round_trip() -> void:
	var d := _layer(["Kick", "Cymbals"])
	d.slots[1].set_slot_note_map(_map({42: 49, 44: 57}))
	var data: Dictionary = d.project.to_json()
	var layer_json: Dictionary = _find_device_json(data, d.channel.id)
	var kids: Array = layer_json.get("children", [])
	_assert(kids.size() == 2, "setup: two slots saved")
	_assert(not kids[0].has("slot_note_map"), "REQ-016: a full-map slot saves no slot_note_map key")
	_assert(kids[1].has("slot_note_map"), "REQ-016: a zoned slot saves its map")

	var loaded: Object = _project_script.from_json(JSON.parse_string(JSON.stringify(data)))
	var layer: Object = loaded.get_channel_by_id(d.channel.id).devices[0]
	_assert(LayerNoteMap.is_full(layer.children[0].slot_note_map), "REQ-016: full map loads as full")
	_assert(_pairs(layer.children[1].slot_note_map) == {42: 49, 44: 57}, "REQ-016: zoned map survives save → load (got %s)" % _pairs(layer.children[1].slot_note_map))


func _test_legacy_json_loads_full() -> void:
	var d := _layer(["Kick"])
	d.slots[0].set_slot_note_map(_map({36: 36}))
	var data: Dictionary = JSON.parse_string(JSON.stringify(d.project.to_json()))
	var layer_json: Dictionary = _find_device_json(data, d.channel.id)
	for child in layer_json.children:
		child.erase("slot_note_map")
		child.erase("slot_separate_out")
	var loaded: Object = _project_script.from_json(data)
	var slot: Object = loaded.get_channel_by_id(d.channel.id).devices[0].children[0]
	_assert(LayerNoteMap.is_full(slot.slot_note_map), "REQ-016: legacy slot loads with the full map")
	_assert(not slot.slot_separate_out, "REQ-016: legacy slot loads with separate output off")


func _test_slot_sync_sends_map() -> void:
	var osc: Node = root.get_node_or_null("AudioEngineOSC")
	_assert(osc != null, "setup: AudioEngineOSC autoload present")
	if osc == null:
		return
	var d := _layer(["Kick", "Snare"])
	osc._pending_sends.clear()
	var map := _map({38: 38})
	d.slots[1].set_slot_note_map(map)
	var sent: Array = osc._pending_sends.filter(func(item) -> bool: return item.address.ends_with("/slot/1/note_map"))
	_assert(sent.size() == 1 and sent[0].args[0] == map, "setter sends slot/1/note_map with the 128-byte map")
	_assert(osc._pending_sends.size() == 1, "setter sends only its own message (got %d)" % osc._pending_sends.size())
	osc._pending_sends.clear()
	d.slots[1].sync_slot_to_engine()
	var actions: Array = osc._pending_sends.map(func(item) -> String: return item.address.get_slice("/", item.address.get_slice_count("/") - 1))
	_assert(actions == ["volume", "mute", "solo", "note_map", "separate_out"], "full sync sends every slot control (got %s)" % [actions])
	osc._pending_sends.clear()


## The saved JSON of the first root device on channel `channel_id`.
func _find_device_json(data: Dictionary, channel_id: int) -> Dictionary:
	for ch_data in data.channels:
		if int(ch_data.id) == channel_id:
			return ch_data.devices[0]
	return {}


func _test_auto_map_from_layer() -> void:
	var resolver: GDScript = load("res://data/NoteMapResolver.gd")
	var d := _layer(["Kick", "Snare", "Cymbals", "Pad"])
	var ch: Object = d.channel
	_assert(not resolver.has_auto_source(ch), "a Layer of full-map slots is not an Auto source (plain layering)")
	_assert(resolver.effective_map(ch).is_empty(), "…and names nothing")
	d.slots[0].set_slot_note_map(_map({36: 36}))
	d.slots[1].set_slot_note_map(_map({36: 38, 37: 40}))
	d.slots[2].set_slot_note_map(_map({42: 49, 44: 51}))
	_assert(resolver.has_auto_source(ch), "a Layer with zoned slots is an Auto source")
	var map: NoteMap = resolver.effective_map(ch)
	_assert(map.get_name(36) == "Kick + Snare D1", "overlap joins names (got '%s')" % map.get_name(36))
	_assert(map.get_name(37) == "Snare E1", "multi-note slot named per output note (got '%s')" % map.get_name(37))
	_assert(map.get_name(42) == "Cymbals C#2" and map.get_name(44) == "Cymbals D#2", "cymbals rows (got '%s', '%s')" % [map.get_name(42), map.get_name(44)])
	_assert(map.pitches().size() == 4, "only zoned inputs get entries, full-map Pad adds none (got %d)" % map.pitches().size())
	var kick_color: Color = d.layer.slot_color(d.layer.slot_key_for(d.slots[0]))
	_assert(map.get_color(36) == kick_color, "entry colour is the (first) slot colour")
	d.slots[1].set_slot_note_map(_map({38: 38}))
	var single: NoteMap = resolver.effective_map(ch)
	_assert(single.get_name(38) == "Snare" and single.get_name(36) == "Kick", "a single-note slot is named after the slot (got '%s')" % single.get_name(38))
	_assert(resolver.wants_drum_view(ch), "zoned Layer channels open in Drum View by default")
	ch.set_note_map_mode(ch.NoteMapMode.NONE)
	_assert(resolver.effective_map(ch).is_empty(), "None still means no map")


func _test_auto_map_watcher() -> void:
	var d := _layer(["Kick"])
	var watcher: Object = load("res://data/NoteMapWatcher.gd").new()
	var hits := [0]
	watcher.changed.connect(func() -> void: hits[0] += 1)
	watcher.bind(d.channel)
	d.slots[0].set_slot_note_map(_map({36: 36}))
	await process_frame
	_assert(hits[0] >= 1, "a mapping edit notifies the clip editor (got %d)" % hits[0])
	var before: int = hits[0]
	d.slots[0].set_name("Bass Drum")
	await process_frame
	_assert(hits[0] > before, "a slot rename notifies")
	before = hits[0]
	d.layer.set_slot_color(d.layer.slot_key_for(d.slots[0]), Color.RED)
	await process_frame
	_assert(hits[0] > before, "a slot recolour notifies")
	watcher.bind(null)
