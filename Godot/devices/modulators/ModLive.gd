## Live modulation values pushed from the engine's per-device `modulation` data stream
## (spec 018 Phase 9).
##
## `ModAssign.attach` also registers every modulatable control here. While any view of a
## device is shown (`ModLive.view_shown` / `view_hidden`, driven by `DeviceView.show_view` /
## `hide_view`), the device's stream and every ancestor's that carries modulators is
## subscribed. A payload holds one record per routed parameter:
##
## - `offset`: the reporting wrapper's own contribution, normalized. The UI sums the offsets
##   of every wrapper in the chain and adds them to the parameter's base value.
## - `values`: per-voice effective values (0..1) of a parameter of a voice-modulating device
##   (PolySynth), which already include the base and every enclosing wrapper's offset, so
##   `offset` records for the same parameter are ignored when one is present.
##
## The stream sends a heartbeat even with no records, so routes dropped on the engine side
## drop out here too. Attached controls get `mod_live_values` (the per-voice dots) and, when
## they draw a value arc, `mod_live_value` - the newest value, which the arc follows instead
## of the set value; with no live value a knob's arc returns to its set value.
class_name ModLive extends RefCounted

## The engine data type this feed subscribes to.
const DATA_TYPE := "modulation"

static var _instance: ModLive

static func holder() -> ModLive:
	if _instance == null:
		_instance = ModLive.new()
	return _instance

## DeviceInstance id -> number of shown views watching it.
var _view_counts := {}
## DeviceInstance id -> the chain (device plus ancestors) one watch subscribes to.
var _watched := {}
## DeviceInstance id -> how many watches include that device in their chain.
var _chain_counts := {}
## osc_path -> {device, count}: the active subscriptions, shared between views.
var _paths := {}
## Control key "{device id}:{param}" -> attached controls.
var _controls := {}
## Control key -> {device, param}: how a key maps back to a base value.
var _targets := {}
## Control key -> reporting DeviceInstance id -> record ({kind, values} or {kind, offset}).
var _live := {}

var _osc: Node = null
var _data_connected := false


# ============================================================================
# CONTROL REGISTRY (ModAssign.attach feeds this)
# ============================================================================

## Register `node` for live values of parameter `param_id` of `device`. Idempotent; the
## control drops out when it leaves the tree.
static func attach(node: Control, device, param_id: int) -> void:
	if node == null or device == null or not is_instance_valid(device):
		return
	var h := holder()
	h._ensure_osc()
	var key := _key(device, param_id)
	var list: Array = h._controls.get(key, [])
	if list.has(node):
		return
	list.append(node)
	h._controls[key] = list
	h._targets[key] = {"device": device, "param": param_id}
	node.tree_exiting.connect(func() -> void: detach(node), CONNECT_ONE_SHOT)
	h._apply(key)


## Drop a control that left the tree.
static func detach(node: Control) -> void:
	var h := holder()
	for key in h._controls.keys():
		var list: Array = h._controls[key]
		if list.has(node):
			list.erase(node)


# ============================================================================
# VIEW LIFECYCLE (DeviceView.show_view / hide_view call this)
# ============================================================================

## A view of `device` was shown: watch the device's stream and its ancestors' while any view
## of it is open, so the engine isn't subscribed for hidden UI.
static func view_shown(device) -> void:
	if device == null or not is_instance_valid(device):
		return
	var h := holder()
	h._ensure_osc()
	var key := "%d" % device.get_instance_id()
	var count: int = h._view_counts.get(key, 0) + 1
	h._view_counts[key] = count
	if count == 1:
		h._watch(device)


## A view of `device` was hidden; when it was the last, unsubscribe its chain and drop its
## live values.
static func view_hidden(device) -> void:
	if device == null or not is_instance_valid(device):
		return
	var h := holder()
	var key := "%d" % device.get_instance_id()
	var count: int = h._view_counts.get(key, 0) - 1
	if count > 0:
		h._view_counts[key] = count
		return
	h._view_counts.erase(key)
	h._unwatch(device)


func _watch(device) -> void:
	var key := "%d" % device.get_instance_id()
	var chain: Array = _chain(device)
	_watched[key] = chain
	for dev in chain:
		var id: int = dev.get_instance_id()
		_chain_counts[id] = _chain_counts.get(id, 0) + 1
		if _chain_counts[id] == 1:
			if not dev.modulator_added.is_connected(_on_modulator_added):
				dev.modulator_added.connect(_on_modulator_added)
			var on_removed := Callable(self, "_on_modulator_removed").bind(dev)
			if not dev.modulator_removed.is_connected(on_removed):
				dev.modulator_removed.connect(on_removed)
		if not dev.modulators.is_empty():
			_subscribe(dev)


func _unwatch(device) -> void:
	var key := "%d" % device.get_instance_id()
	var chain: Array = _watched.get(key, [])
	_watched.erase(key)
	for dev in chain:
		if not is_instance_valid(dev):
			continue
		var id: int = dev.get_instance_id()
		var count: int = _chain_counts.get(id, 0) - 1
		if count > 0:
			_chain_counts[id] = count
		else:
			_chain_counts.erase(id)
			if dev.modulator_added.is_connected(_on_modulator_added):
				dev.modulator_added.disconnect(_on_modulator_added)
			var on_removed := Callable(self, "_on_modulator_removed").bind(dev)
			if dev.modulator_removed.is_connected(on_removed):
				dev.modulator_removed.disconnect(on_removed)
		_unsubscribe(dev)


## A modulator appeared on a watched chain device: subscribe its (now existing) stream.
func _on_modulator_added(modulator) -> void:
	var dev = modulator.owner() if modulator != null else null
	if dev == null or not is_instance_valid(dev) or not _chain_counts.has(dev.get_instance_id()):
		return
	_subscribe(dev)


## A modulator was removed from a watched chain device. When it was the last one the
## wrapper (and its stream) is gone: stop asking for it and drop everything it reported.
func _on_modulator_removed(_mod_id: int, dev) -> void:
	if dev == null or not is_instance_valid(dev) or not dev.modulators.is_empty():
		return
	_drop_path(dev)


## Forget every record `device` reported (it was unwrapped or unsubscribed) and refresh the
## affected controls.
func _clear_reporter(device) -> void:
	var reporter_id: int = device.get_instance_id()
	var affected := {}
	for key in _live.keys():
		if _live[key].has(reporter_id):
			_live[key].erase(reporter_id)
			affected[key] = true
	for key in affected:
		_apply(key)


# ============================================================================
# SUBSCRIPTIONS
# ============================================================================

func _subscribe(dev) -> void:
	if dev == null or not is_instance_valid(dev):
		return
	var path: String = dev.osc_path()
	if _paths.has(path):
		_paths[path]["count"] += 1
		return
	_paths[path] = {"device": dev, "count": 1}
	if _osc:
		_osc.subscribe_device_data(path, DATA_TYPE)


func _unsubscribe(dev) -> void:
	if dev == null or not is_instance_valid(dev):
		return
	var path: String = dev.osc_path()
	var entry: Dictionary = _paths.get(path, {})
	if entry.is_empty():
		return
	var count: int = entry.get("count", 0) - 1
	if count > 0:
		entry["count"] = count
		return
	_drop_path(dev)


## Remove the subscription for `dev` whatever its count, and forget its reports.
func _drop_path(dev) -> void:
	if not is_instance_valid(dev):
		return
	var path: String = dev.osc_path()
	if not _paths.has(path):
		return
	_paths.erase(path)
	if _osc:
		_osc.unsubscribe_device_data(path, DATA_TYPE)
	_clear_reporter(dev)


func _ensure_osc() -> void:
	if _data_connected or _osc != null:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_osc = tree.root.get_node_or_null("AudioEngineOSC")
	if _osc == null:
		return
	var cb := Callable(self, "_on_data")
	if not _osc.device_data_received.is_connected(cb):
		_osc.device_data_received.connect(cb)
	_data_connected = true


# ============================================================================
# PAYLOADS
# ============================================================================

## The `modulation` data stream arrived for one device. Records replace that reporter's
## entries wholesale, so a route removed on the engine side drops out on the next payload.
func _on_data(osc_path: String, data_type: String, blob: PackedByteArray) -> void:
	if data_type != DATA_TYPE:
		return
	var entry: Dictionary = _paths.get(osc_path, {})
	if entry.is_empty():
		return
	var device = entry.get("device")
	if device == null or not is_instance_valid(device):
		return
	var reporter_id: int = device.get_instance_id()
	var affected := {}
	for key in _live.keys():
		if _live[key].has(reporter_id):
			_live[key].erase(reporter_id)
			affected[key] = true
	for record in _decode(blob):
		var target := _resolve(device, record["path"], record["param"])
		if target == "":
			continue
		if not _live.has(target):
			_live[target] = {}
		_live[target][reporter_id] = record
		affected[target] = true
	for key in affected:
		_apply(key)


## Decode a payload into records: `{kind, path, param, values}` (kind 1) or
## `{kind, path, param, offset}` (kind 0), little-endian as the engine writes it.
static func _decode(blob: PackedByteArray) -> Array:
	var out: Array = []
	if blob.size() < 2:
		return out
	var count := blob.decode_u16(0)
	var at := 2
	for _i in count:
		if at + 6 > blob.size():
			return out
		var kind := blob.decode_u8(at)
		var depth := blob.decode_u8(at + 1)
		at += 2
		var path: Array[int] = []
		for _j in depth:
			if at + 2 > blob.size():
				return out
			path.append(blob.decode_u16(at))
			at += 2
		if at + 5 > blob.size():
			return out
		var param := blob.decode_u32(at)
		at += 4
		var n := blob.decode_u8(at)
		at += 1
		if at + n * 4 > blob.size():
			return out
		var values := PackedFloat32Array()
		values.resize(n)
		for j in n:
			values[j] = blob.decode_float(at + j * 4)
		at += n * 4
		if kind == 1:
			out.append({"kind": 1, "path": path, "param": param, "values": values})
		else:
			out.append({"kind": 0, "path": path, "param": param,
				"offset": values[0] if n > 0 else 0.0})
	return out


## Resolve a record target (a child path from the reporting device, plus a param id) to a
## control key; "" when the path no longer resolves in the model.
static func _resolve(device, child_path: Array, param_id: int) -> String:
	var walk = device
	for index in child_path:
		if walk == null or not is_instance_valid(walk) or index >= walk.children.size():
			return ""
		walk = walk.children[index]
	if walk == null or not is_instance_valid(walk):
		return ""
	return _key(walk, param_id)


# ============================================================================
# PUSHING TO CONTROLS
# ============================================================================

## Recompute a key's live value and push it to its controls. A `values` record wins over
## `offset` records for the same parameter (it already contains their contributions);
## offsets sum onto the parameter's base value.
func _apply(key: String) -> void:
	var controls: Array = _controls.get(key, [])
	if controls.is_empty():
		return
	var target: Dictionary = _targets.get(key, {})
	var live_value := -1.0
	var values := PackedFloat32Array()
	var reports: Dictionary = _live.get(key, {})
	if not reports.is_empty():
		var offset := 0.0
		var has_values_record := false
		for _reporter in reports:
			var record: Dictionary = reports[_reporter]
			if record.get("kind", 0) == 1:
				has_values_record = true
				values = record.get("values", PackedFloat32Array())
			else:
				offset += record.get("offset", 0.0)
		# Offsets only: one effective value on top of the base. A values record with no
		# sounding voice leaves `values` empty, so the arc returns to the set value.
		if not has_values_record:
			var device = target.get("device")
			var base := 0.5
			if device != null and is_instance_valid(device):
				base = device.get_parameter_normalized(int(target.get("param", 0)))
			values = PackedFloat32Array([clampf(base + offset, 0.0, 1.0)])
		if not values.is_empty():
			live_value = values[values.size() - 1]
	for node in controls.duplicate():
		if node == null or not is_instance_valid(node):
			controls.erase(node)
			continue
		if "mod_live_values" in node:
			node.mod_live_values = values
		if "mod_live_value" in node:
			node.mod_live_value = live_value


# ============================================================================
# HELPERS
# ============================================================================

## Control key for parameter `param_id` of `device`.
static func _key(device, param_id: int) -> String:
	return "%d:%d" % [device.get_instance_id(), param_id]


## `device` and every ancestor, device first.
static func _chain(device) -> Array:
	var out: Array = []
	var walk = device
	while walk != null and is_instance_valid(walk):
		out.append(walk)
		walk = walk.get_parent_device()
	return out


## Drop every watch, subscription and registered control. Tests call this between cases.
static func reset() -> void:
	if _instance == null:
		return
	var h := holder()
	for key in h._watched.keys():
		var chain: Array = h._watched[key]
		for dev in chain:
			if not is_instance_valid(dev):
				continue
			if dev.modulator_added.is_connected(h._on_modulator_added):
				dev.modulator_added.disconnect(h._on_modulator_added)
			var on_removed := Callable(h, "_on_modulator_removed").bind(dev)
			if dev.modulator_removed.is_connected(on_removed):
				dev.modulator_removed.disconnect(on_removed)
	h._view_counts.clear()
	h._watched.clear()
	h._chain_counts.clear()
	h._paths.clear()
	h._controls.clear()
	h._targets.clear()
	h._live.clear()
