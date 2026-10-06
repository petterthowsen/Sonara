## SamplerMultisample.gd
## The multisample state of a Sampler DeviceInstance (spec 023, ADR 0006): zones, groups and the
## focused zone. Zones are device state, not parameters, so they travel to the engine as
## whole-zone and whole-group snapshots in real units (`zone/{zid}/set`, `zone_group/{gid}/set`).
## Syncing is therefore idempotent: `sync_to_engine()` just re-sends everything.
##
## Every setter updates the model, sends OSC through the owning DeviceInstance and emits a signal.
## Undo works on snapshots: `snapshot()` / `restore()` diff by zone id and send only what changed.
class_name SamplerMultisample extends RefCounted

static var logger := Log.make("SamplerMultisample")

signal mode_changed()
## Zones were added, removed or reordered.
signal zones_changed()
## One zone's settings, load state or group changed.
signal zone_changed(zone_id: int)
signal groups_changed()
signal focus_changed(zone_id: int)

## Same constants as DeviceInstance._watch_waveform: project loads overflow Godot's UDP buffer.
const WAVEFORM_RETRY_SEC := 2.0
const WAVEFORM_MAX_RETRIES := 3
const AUDIO_EXTENSIONS := ["wav", "flac", "ogg", "mp3", "aif", "aiff"]

var active: bool = false
var zones: Array[SamplerZone] = []
var groups: Array[SamplerZoneGroup] = []
## Group 0: always exists, has no name.
var ungrouped := SamplerZoneGroup.new(SamplerZoneGroup.UNGROUPED_ID)
## 0 = no focused zone.
var focused_zone_id: int = 0
var next_zone_id: int = 1
var next_group_id: int = 1

var _device_ref: WeakRef = null


## The owning Sampler. Setters send OSC to its address; without one they only change the model.
func bind(device: DeviceInstance) -> void:
	_device_ref = weakref(device) if device != null else null


func device() -> DeviceInstance:
	return _device_ref.get_ref() as DeviceInstance if _device_ref != null else null


# --- queries ---------------------------------------------------------------

func get_zone(zone_id: int) -> SamplerZone:
	for zone in zones:
		if zone.id == zone_id:
			return zone
	return null


func focused_zone() -> SamplerZone:
	return get_zone(focused_zone_id)


## Group `group_id`, or Ungrouped for 0 and unknown ids. Null never.
func get_group(group_id: int) -> SamplerZoneGroup:
	if group_id != SamplerZoneGroup.UNGROUPED_ID:
		for group in groups:
			if group.id == group_id:
				return group
	return ungrouped


func has_group(group_id: int) -> bool:
	return group_id == SamplerZoneGroup.UNGROUPED_ID or groups.any(func(g): return g.id == group_id)


func zones_in_group(group_id: int) -> Array[SamplerZone]:
	var out: Array[SamplerZone] = []
	for zone in zones:
		if zone.group_id == group_id:
			out.append(zone)
	return out


## Zones sorted by root key (list order for equal roots), for the focus menu.
func zones_by_root() -> Array[SamplerZone]:
	var out := zones.duplicate()
	out.sort_custom(func(a: SamplerZone, b: SamplerZone) -> bool:
		return a.root < b.root if a.root != b.root else zones.find(a) < zones.find(b))
	return out


# --- mode ------------------------------------------------------------------

## Switch mode. Leaving multisample mode drops every zone and group (the engine does too).
func set_active(on: bool) -> void:
	if active == on:
		return
	active = on
	if not on:
		_clear()
	_send("multisample", [1 if on else 0])
	mode_changed.emit()
	if not on:
		zones_changed.emit()
		groups_changed.emit()
		focus_changed.emit(0)


func _clear() -> void:
	zones.clear()
	groups.clear()
	ungrouped = SamplerZoneGroup.new(SamplerZoneGroup.UNGROUPED_ID)
	focused_zone_id = 0


# --- zones -----------------------------------------------------------------

## Add one zone per audio file in default name order, laid out as in REQ-020 (roots from the file
## names, keys from `at_key` when it is >= 0). Returns the new zone ids.
func add_files(paths: Array, at_key: int = -1) -> Array[int]:
	var new_zones: Array[SamplerZone] = []
	var roots: Array = []
	for path in ZoneLayout.sorted_paths(paths):
		new_zones.append(SamplerZone.new(0, str(path)))
		roots.append(ZoneLayout.parse_root(str(path).get_file()))
	return place_zones(new_zones, roots, at_key)


## Add `new_zones` (fresh ids, no ranges yet) with the REQ-020 layout for `roots` (index-aligned,
## -1 = none detected), then send and load them. Turns multisample mode on. Returns the ids.
func place_zones(new_zones: Array[SamplerZone], roots: Array, at_key: int = -1) -> Array[int]:
	var ids: Array[int] = []
	if new_zones.is_empty():
		return ids
	set_active(true)
	var placed := ZoneLayout.layout(roots, at_key)
	for i in new_zones.size():
		var zone := new_zones[i]
		zone.id = next_zone_id
		next_zone_id += 1
		zone.apply_fields({
			"root": placed[i]["root"], "key": [placed[i]["key_lo"], placed[i]["key_hi"]]})
		zones.append(zone)
		ids.append(zone.id)
	zones_changed.emit()
	for zone in new_zones:
		_send_zone(zone)
		load_zone(zone)
	if focused_zone_id == 0:
		set_focus(ids[0])
	return ids


## Change fields of one zone (see SamplerZone.apply_fields). Sends the whole zone.
func set_zone_fields(zone_id: int, values: Dictionary) -> void:
	var zone := get_zone(zone_id)
	if zone == null:
		return
	if zone.apply_fields(values):
		_send_zone(zone)
		zone_changed.emit(zone_id)


## Change fields of several zones at once, `{zone_id: fields}` (batch operations and drags).
func set_zones_fields(changes: Dictionary) -> void:
	for zone_id in changes:
		set_zone_fields(int(zone_id), changes[zone_id])


## Move the zones `ids` (kept in their current relative order) to sit just before zone
## `before_id`, or to the end when it is 0 or one of `ids`. List order is what the batch
## operations distribute in.
func reorder_zones(ids: Array, before_id: int = 0) -> void:
	var moving: Array[SamplerZone] = []
	for zone in zones:
		if ids.has(zone.id):
			moving.append(zone)
	if moving.is_empty():
		return
	var rest: Array[SamplerZone] = []
	for zone in zones:
		if not moving.has(zone):
			rest.append(zone)
	var at := rest.size()
	for i in rest.size():
		if rest[i].id == before_id:
			at = i
			break
	var next: Array[SamplerZone] = []
	next.append_array(rest.slice(0, at))
	next.append_array(moving)
	next.append_array(rest.slice(at))
	if next.map(func(z: SamplerZone): return z.id) != zones.map(func(z: SamplerZone): return z.id):
		zones = next
		zones_changed.emit()


## Put `ids` in default name order (`ZoneLayout.sorted_by_name`), into the list slots they occupy.
func sort_zones_by_name(ids: Array) -> void:
	var picked: Array = zones.filter(func(z: SamplerZone): return ids.has(z.id))
	var sorted := ZoneLayout.sorted_by_name(picked)
	var slot := 0
	var next: Array[SamplerZone] = []
	for zone in zones:
		if ids.has(zone.id):
			next.append(sorted[slot])
			slot += 1
		else:
			next.append(zone)
	if next.map(func(z: SamplerZone): return z.id) != zones.map(func(z: SamplerZone): return z.id):
		zones = next
		zones_changed.emit()


func remove_zones(ids: Array) -> void:
	var removed := false
	for zone_id in ids:
		var zone := get_zone(int(zone_id))
		if zone == null:
			continue
		zones.erase(zone)
		_send("zone/%d/remove" % zone.id, [])
		removed = true
	if not removed:
		return
	zones_changed.emit()
	if get_zone(focused_zone_id) == null:
		set_focus(zones[0].id if not zones.is_empty() else 0)


func set_focus(zone_id: int) -> void:
	if zone_id != 0 and get_zone(zone_id) == null:
		return
	if zone_id == focused_zone_id:
		return
	focused_zone_id = zone_id
	_send("focus_zone", [zone_id])
	focus_changed.emit(zone_id)


# --- groups ----------------------------------------------------------------

## Create a group. An empty name becomes "Group N". Returns its id.
func add_group(group_name: String = "") -> int:
	var group := SamplerZoneGroup.new(next_group_id)
	next_group_id += 1
	group.name = group_name if not group_name.is_empty() else "Group %d" % group.id
	groups.append(group)
	_send("zone_group/%d/set" % group.id, group.to_osc_args())
	groups_changed.emit()
	return group.id


func rename_group(group_id: int, new_name: String) -> void:
	var group := get_group(group_id)
	if group.id == SamplerZoneGroup.UNGROUPED_ID or group.name == new_name or new_name.is_empty():
		return
	group.name = new_name
	groups_changed.emit()


## Delete a group. Its zones become Ungrouped.
func remove_group(group_id: int) -> void:
	var group := get_group(group_id)
	if group.id == SamplerZoneGroup.UNGROUPED_ID:
		return
	groups.erase(group)
	_send("zone_group/%d/remove" % group_id, [])
	for zone in zones_in_group(group_id):
		zone.group_id = SamplerZoneGroup.UNGROUPED_ID
		_send_zone(zone)
		zone_changed.emit(zone.id)
	groups_changed.emit()


## `gain`, `mute`, `solo` and `play_mode` of a group (0 = Ungrouped).
func set_group_fields(group_id: int, values: Dictionary) -> void:
	var group := get_group(group_id)
	var before := group.fields()
	group.apply_fields(values)
	if group.fields() == before:
		return
	_send("zone_group/%d/set" % group.id, group.to_osc_args())
	groups_changed.emit()


func move_to_group(ids: Array, group_id: int) -> void:
	if not has_group(group_id):
		return
	for zone_id in ids:
		set_zone_fields(int(zone_id), {"group": group_id})


# --- loading ---------------------------------------------------------------

## Load the zone's file through the AudioFileService. The waveform arrives on
## `/audiofile/waveform/ready`, which Project routes to `zone.source` by request id.
func load_zone(zone: SamplerZone, attempt: int = 0) -> void:
	var dev := device()
	zone.source.reset()
	if zone.path.is_empty():
		return
	zone.load_req_id = "zone:%s:%d:%d" % [dev.id if dev else "", zone.id, Time.get_ticks_usec()]
	var channel := dev.get_channel() if dev else null
	var project := channel.get_project() if channel else null
	if project:
		project.track_source_request(zone.source, zone.load_req_id)
	_send("zone/%d/load_file" % zone.id, [zone.path, zone.load_req_id])
	set_zone_loading_state(zone.id, "loading")
	_watch_waveform(zone, zone.path, attempt)


## The engine's `{device}/zone/{zid}/loading_state`, or a local change.
func set_zone_loading_state(zone_id: int, state: String) -> void:
	var zone := get_zone(zone_id)
	if zone == null or zone.loading_state == state:
		return
	zone.loading_state = state
	if zone.is_missing():
		logger.warn("Zone %d (%s) failed to load: %s" % [zone.id, zone.path, zone.missing_reason()])
	zone_changed.emit(zone_id)


func _watch_waveform(zone: SamplerZone, path: String, attempt: int) -> void:
	if attempt >= WAVEFORM_MAX_RETRIES or Utils.is_test_mode():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or not path.get_extension().to_lower() in AUDIO_EXTENSIONS:
		return
	await tree.create_timer(WAVEFORM_RETRY_SEC).timeout
	if get_zone(zone.id) != zone or zone.path != path or zone.is_missing():
		return
	if zone.source.is_waveform_ready():
		return
	logger.warn("No waveform for zone %d (%s) after %.0fs; retrying (%d)" % [
		zone.id, path, WAVEFORM_RETRY_SEC, attempt + 1])
	load_zone(zone, attempt + 1)


# --- engine sync -----------------------------------------------------------

## Re-send the whole state: mode, groups, zones (`set` then `load_file`), focus.
func sync_to_engine() -> void:
	if not active:
		return
	_send("multisample", [1])
	_send("zone_group/0/set", ungrouped.to_osc_args())
	for group in groups:
		_send("zone_group/%d/set" % group.id, group.to_osc_args())
	for zone in zones:
		_send_zone(zone)
		load_zone(zone)
	if focused_zone_id != 0:
		_send("focus_zone", [focused_zone_id])


func _send_zone(zone: SamplerZone) -> void:
	_send("zone/%d/set" % zone.id, zone.to_osc_args())


func _send(action: String, args: Array) -> void:
	var dev := device()
	if dev != null:
		AudioEngineOSC.send(dev.osc_addr(action), args)


# --- persistence and undo --------------------------------------------------

func to_json() -> Dictionary:
	return {
		"active": active,
		"focused_zone": focused_zone_id,
		"next_zone_id": next_zone_id,
		"next_group_id": next_group_id,
		"groups": groups.map(func(g: SamplerZoneGroup): return g.to_json()),
		"ungrouped": ungrouped.to_json(),
		"zones": zones.map(func(z: SamplerZone): return z.to_json()),
	}


## Replace the state from JSON without sending anything (loading a project or preset).
## `sync_to_engine()` follows once the device exists.
func load_json(data: Dictionary) -> void:
	_clear()
	active = bool(data.get("active", false))
	ungrouped = SamplerZoneGroup.from_json(data.get("ungrouped", {}))
	for entry in data.get("groups", []):
		if entry is Dictionary:
			groups.append(SamplerZoneGroup.from_json(entry))
	for entry in data.get("zones", []):
		if entry is Dictionary:
			zones.append(SamplerZone.from_json(entry))
	var max_zone := 0
	for zone in zones:
		max_zone = maxi(max_zone, zone.id)
		if not has_group(zone.group_id):
			zone.group_id = SamplerZoneGroup.UNGROUPED_ID
	var max_group := 0
	for group in groups:
		max_group = maxi(max_group, group.id)
	next_zone_id = maxi(int(data.get("next_zone_id", 1)), max_zone + 1)
	next_group_id = maxi(int(data.get("next_group_id", 1)), max_group + 1)
	focused_zone_id = int(data.get("focused_zone", 0))
	if get_zone(focused_zone_id) == null:
		focused_zone_id = zones[0].id if not zones.is_empty() else 0


static func from_json(data: Dictionary) -> SamplerMultisample:
	var model := SamplerMultisample.new()
	model.load_json(data)
	return model


## The state for undo: plain data, identical to the saved JSON.
func snapshot() -> Dictionary:
	return to_json()


## One zone's JSON for mergeable knob edits, or {} when it doesn't exist.
func snapshot_zone(zone_id: int) -> Dictionary:
	var zone := get_zone(zone_id)
	return zone.to_json() if zone else {}


## Apply a single-zone snapshot (see `snapshot_zone`). A zone that no longer exists is ignored.
func restore_zone(snap: Dictionary) -> void:
	if snap.is_empty():
		return
	var zone := get_zone(int(snap.get("id", 0)))
	if zone == null:
		return
	var path_changed := zone.path != str(snap.get("path", zone.path))
	zone.set_path(str(snap.get("path", zone.path)))
	zone.apply_fields(snap)
	_send_zone(zone)
	if path_changed:
		load_zone(zone)
	zone_changed.emit(zone.id)


## Make the state equal `snap`, sending only what differs: a set for changed zones and groups,
## remove for gone ones, set plus load for new or re-pathed zones.
func restore(snap: Dictionary) -> void:
	var want_active := bool(snap.get("active", false))
	if not want_active:
		var had_content := active or not zones.is_empty()
		var had_focus := focused_zone_id
		_clear()
		active = false
		next_zone_id = maxi(1, int(snap.get("next_zone_id", next_zone_id)))
		next_group_id = maxi(1, int(snap.get("next_group_id", next_group_id)))
		if had_content:
			_send("multisample", [0])
			mode_changed.emit()
			zones_changed.emit()
			groups_changed.emit()
			if had_focus != 0:
				focus_changed.emit(0)
		return

	var entering := not active
	active = true
	if entering:
		_send("multisample", [1])

	var groups_dirty := _restore_groups(snap, entering)
	var zones_dirty := _restore_zones(snap)
	next_zone_id = maxi(int(snap.get("next_zone_id", 1)), next_zone_id)
	next_group_id = maxi(int(snap.get("next_group_id", 1)), next_group_id)
	var want_focus := int(snap.get("focused_zone", 0))
	if get_zone(want_focus) == null:
		want_focus = 0
	var focus_dirty := want_focus != focused_zone_id
	focused_zone_id = want_focus
	if focus_dirty:
		_send("focus_zone", [want_focus])

	if entering:
		mode_changed.emit()
	if groups_dirty:
		groups_changed.emit()
	if zones_dirty:
		zones_changed.emit()
	if focus_dirty:
		focus_changed.emit(want_focus)


## Returns true when the group list or any group changed.
func _restore_groups(snap: Dictionary, force: bool) -> bool:
	var dirty := false
	var want_ungrouped := SamplerZoneGroup.from_json(snap.get("ungrouped", {}))
	if force or want_ungrouped.fields() != ungrouped.fields():
		ungrouped = want_ungrouped
		_send("zone_group/0/set", ungrouped.to_osc_args())
		dirty = true
	var wanted: Array[SamplerZoneGroup] = []
	for entry in snap.get("groups", []):
		if entry is Dictionary:
			wanted.append(SamplerZoneGroup.from_json(entry))
	for old in groups:
		if not wanted.any(func(g: SamplerZoneGroup): return g.id == old.id):
			_send("zone_group/%d/remove" % old.id, [])
			dirty = true
	var order_before := groups.map(func(g: SamplerZoneGroup): return g.id)
	for group in wanted:
		var existing := groups.filter(func(g: SamplerZoneGroup): return g.id == group.id)
		if existing.is_empty() or force or existing[0].fields() != group.fields():
			_send("zone_group/%d/set" % group.id, group.to_osc_args())
			dirty = true
		elif existing[0].name != group.name:
			dirty = true
	groups = wanted
	return dirty or order_before != groups.map(func(g: SamplerZoneGroup): return g.id)


## Returns true when zones were added, removed or reordered.
func _restore_zones(snap: Dictionary) -> bool:
	var by_id := {}
	for zone in zones:
		by_id[zone.id] = zone
	var wanted: Array[SamplerZone] = []
	var changed_ids: Array[int] = []
	var to_load: Array[SamplerZone] = []
	for entry in snap.get("zones", []):
		if not (entry is Dictionary):
			continue
		var zone_id := int(entry.get("id", 0))
		var existing: SamplerZone = by_id.get(zone_id)
		if existing == null:
			var fresh := SamplerZone.from_json(entry)
			wanted.append(fresh)
			_send_zone(fresh)
			to_load.append(fresh)
			continue
		by_id.erase(zone_id)
		var new_path := str(entry.get("path", existing.path))
		var path_changed := existing.path != new_path
		if path_changed:
			existing.set_path(new_path)
		var fields_changed := existing.apply_fields(entry)
		if path_changed or fields_changed:
			_send_zone(existing)
			changed_ids.append(zone_id)
		if path_changed:
			to_load.append(existing)
		wanted.append(existing)
	for gone_id in by_id:
		_send("zone/%d/remove" % int(gone_id), [])
	var order_before := zones.map(func(z: SamplerZone): return z.id)
	zones = wanted
	for zone in to_load:
		load_zone(zone)
	for zone_id in changed_ids:
		zone_changed.emit(zone_id)
	return not by_id.is_empty() or order_before != zones.map(func(z: SamplerZone): return z.id)
