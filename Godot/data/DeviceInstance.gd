## DeviceInstance.gd
## Represents an instance of a device on a channel (with parameter state).
## Tracks current parameter values and handles syncing with the audio engine.

class_name DeviceInstance extends RefCounted

static var logger := Log.make("DeviceInstance")

## ============================================================================
## SIGNALS
## ============================================================================

signal parameter_changed(param_id: int, value: float)
signal enabled_changed(enabled: bool)
signal active_changed(active: bool)
signal parameters_updated()  # Emitted when parameter list changes (e.g., SFZ file loaded)
signal key_labels_changed()  # SFZ key labels / keyswitches (re)loaded; see key_labels
signal loading_state_changed(state: String)  # "idle", "loading", "ready", "failed:{error}", "crashed:{reason}"
signal crashed(reason: String, stderr: String)  # Plugin host died; see reload()
signal host_changed()  # Plugin loaded into a host process; see host_mode / host_pid
signal stats_changed()  # New processing stats for a CLAP plugin (1 Hz); see plugin_stats
signal plugin_gui_closed()  # Emitted when plugin GUI window is closed
signal plugin_state_saved(ok: bool)  # Answer to save_plugin_state(); see plugin_state
signal child_added(device_instance: DeviceInstance, position: int)
signal child_removed(position: int, device_id: String)
signal child_moved(from_position: int, to_position: int)
signal slot_changed()
## A Drum Machine pad's choke group changed (0 = none, 1–8). See "DRUM CHOKE GROUPS".
signal choke_group_changed(group: int)
## A container slot opened, closed or changed color (see "CONTAINER SLOTS").
signal slots_changed()
signal name_changed(new_name: String)
signal preset_changed()  # preset_name / preset_path changed; see set_preset
## A modulation route was added, changed or removed (amount 0). See "MODULATION".
signal mod_route_changed(source: String, param_id: int, amount: float)


## ============================================================================
## PROPERTIES
## ============================================================================

## Unique instance identifier (UUID)
var id: String = ""

## Display name for this instance (sibling-unique on a host). Empty until assigned.
var name: String = ""

## Preset this device was created or loaded from, or last saved as (empty = none). Saved with the
## project; see docs/device-presets-plan.md. Change through set_preset().
var preset_name: String = ""
var preset_path: String = ""

## The device type (metadata)
var device: Device

## Channel this device is on
var channel_id: int = 0

## Whether this device is active (loaded into memory)
var active : bool = true

## Whether this device is enabled (effectively processing audio vs bypassed)
var enabled : bool = true

## Position in the parent device list (0 = first)
var position: int = 0

## Nested child devices when this instance is a container (Chain/Layer).
var children: Array[DeviceInstance] = []

## Weak parent container; unset at the channel root.
var _parent_ref: WeakRef = null

## Weak channel this instance is attached to (for sibling names and paths).
var _channel_ref: WeakRef = null

## Layer slot mix controls (used when the parent is a Layer).
var slot_volume: float = 0.5
var slot_mute: bool = false
var slot_solo: bool = false
## Layer slot note map: 128 bytes, input note -> output note (LayerNoteMap.NONE = ignored).
var slot_note_map: PackedByteArray = LayerNoteMap.full()
## Layer slot audio goes to its own return channel instead of the Layer's output.
var slot_separate_out: bool = false

## MIDI note for a Drum Machine child (-1 = unset, engine assigns).
var slot_note: int = -1

## Choke group for a Drum Machine pad (0 = none, 1–8): a note-on in a group chokes every other
## pad in it. Lives on the pad's own instance; see "DRUM CHOKE GROUPS".
var choke_group: int = 0

## Container slots: color per slot key (random on first use) and the keys shown in the device lane.
## Saved with the project; see "CONTAINER SLOTS".
var _slot_colors: Dictionary = {}  # slot key -> Color
var _open_slots: PackedStringArray = []

## Mixer channel that receives this pad's extra-out bus (-1 = none).
var return_channel_id: int = -1

## Extra-out return channels for a multi-out plugin (index = extra stereo bus).
var return_channel_ids: Array[int] = []

## Return channels removed along with this device (or pad), kept by id so re-adding the same
## instance (undo, move) restores them with their settings. Not persisted. See AuxReturnSync.
var detached_returns: Dictionary[int, Channel] = {}

## Decoded metadata and peak data when this instance is a Sampler (or other sample-loading device).
var sample_source: AudioSourceInfo = null

## Current parameter values (normalized 0.0-1.0)
var parameter_values: Dictionary[int, float] = {}

## Modulation routes (device state, not parameters): "source:param_id" -> amount (-1..1).
## Amount 0 is never stored. Seeded from the device's default patch; see "MODULATION".
var mod_routes: Dictionary = {}

## Echoes of our own mod messages still in flight: key ("source:param_id", or MOD_CLEAR_KEY)
## -> [count, first_msec]. Same idea as `_pending_echoes`.
var _pending_mod_echoes: Dictionary = {}
const MOD_CLEAR_KEY := "*clear*"

## Parameter metadata advertised by the engine for THIS instance (SFZ/CLAP
## devices whose param list depends on the loaded file/plugin instance).
## Empty for built-ins with a static param list defined on the shared
## `Device` registry object; use get_parameter()/get_parameters() etc.
## instead of reaching into `device.parameters` directly, since that object
## is shared by every instance of the same device type and must not be
## overwritten per-instance.
var parameters: Array[DeviceParameter] = []

## SFZ sampler only: keys the loaded SFZ names, sorted by key. Each entry is
## {"key": int, "keyswitch": bool, "label": String}. Not persisted: the engine
## re-sends it whenever the SFZ loads, and an empty message clears it.
var key_labels: Array = []

## SFZ sampler only: inclusive [lo, hi] key ranges its regions play, sorted and merged.
## Empty until the SFZ has loaded. Not persisted, like key_labels.
var playable_ranges: Array = []

## True once `keys/info` has arrived for the current file. load_file() resets it, so the
## assistant can tell "not here yet" from "this SFZ declares nothing".
var key_info_received := false

## Track loaded file path (for devices that support file loading, e.g., SFZ sampler)
var loaded_file_path: String = ""

## Loading state: "idle", "loading", "ready", "failed:{error}", "crashed:{reason}"
var loading_state: String = "idle"

## Seconds between state/get retries while the device is "loading" (see request_state()).
const LOADING_RECHECK_SEC := 2.0

## A loading re-check timer is running (at most one per instance).
var _loading_recheck_pending: bool = false

## Why the plugin host last crashed ("" if it has not). See `crashed` signal.
var crash_reason: String = ""

## Tail of the crashed plugin host's stderr ("" if none/empty).
var crash_stderr: String = ""

## The crashed plugin host's own log file ("" if unknown).
var crash_log_path: String = ""

## Plugin host process this (CLAP) device runs in: the hosting mode that chose it (engine name,
## see PluginHosting.MODES), the host key and its pid. Empty / 0 until the plugin has loaded.
var host_mode: String = ""
var host_key: String = ""
var host_pid: int = 0

## One second of a CLAP plugin's processing, from `<device addr>/stats`. Loads are the plugin's
## process() time as a share of real time (1.0 = 100% of the block time).
class PluginStats:
	## A plugin that stops reporting (asleep, idle, removed) is stale after this long.
	const FRESH_MSEC := 3000

	var load_avg: float = 0.0
	var load_peak: float = 0.0
	var process_avg_us: float = 0.0
	var process_max_us: float = 0.0
	## Blocks the plugin was given in the interval, and how many missed the deadline (dropouts).
	var blocks: int = 0
	var deadline_misses: int = 0
	var total_misses: int = 0
	## Missed several deadlines in a row: its audio is dropping out.
	var struggling: bool = false
	## Time.get_ticks_msec() when it arrived.
	var received_msec: int = 0

	static func from_osc(values: Array, now_msec: int) -> PluginStats:
		var stats := PluginStats.new()
		stats.load_avg = float(values[0])
		stats.load_peak = float(values[1])
		stats.process_avg_us = float(values[2])
		stats.process_max_us = float(values[3])
		stats.blocks = int(values[4])
		stats.deadline_misses = int(values[5])
		stats.total_misses = int(values[6])
		stats.struggling = int(values[7]) != 0
		stats.received_msec = now_msec
		return stats

	func is_fresh(now_msec: int) -> bool:
		return now_msec - received_msec <= FRESH_MSEC

	## Tooltip lines.
	func describe() -> String:
		var text := "DSP: %.1f%% avg, %.1f%% peak (%.0f µs avg, %.0f µs max per block)" % [
			load_avg * 100.0, load_peak * 100.0, process_avg_us, process_max_us]
		text += "\nDropouts: %d in the last second, %d since loaded" % [deadline_misses, total_misses]
		if struggling:
			text += "\nMissing its processing deadline repeatedly: its audio drops out"
		return text


## Processing stats of a CLAP plugin (null until the engine reports them).
var plugin_stats: PluginStats = null

## Pid of the last crashed host that showed a popup. A shared host crash reports once per
## device in it; one popup (with one Reload, which restores them all) is enough.
static var _last_crash_popup_pid: int = -1

## Track expected parameter count when receiving parameter info
var _expected_param_count: int = 0

## Parameter values restored from a project file, reapplied after the engine advertises params.
## SFZ/CLAP devices wipe and rebuild their parameter list on load; this keeps saved CC/param values.
var _restored_parameter_values: Dictionary[int, float] = {}

## Engine echoes still expected for values this instance sent: param_id -> [count, send msec].
## While more than one is in flight, an arriving echo is for an older value and is dropped, so a
## fast drag doesn't snap back to stale values. Entries older than PENDING_ECHO_TIMEOUT_MS are
## discarded in case an echo never arrives.
var _pending_echoes: Dictionary[int, Array] = {}
const PENDING_ECHO_TIMEOUT_MS := 500

## A CLAP plugin's own state blob (presets, samples, anything its parameters don't cover), as of
## the last project save or load. Saved into the `.sonara` file as base64. Empty if the plugin has
## no state extension, or it was never saved.
var plugin_state: PackedByteArray = PackedByteArray()

## `plugin_state` came from a project file and still has to reach the engine; it's sent once
## the plugin reports "ready".
var _plugin_state_restore_pending: bool = false

## Where plugin state blobs are handed between Godot and the engine. They go through files
## because a blob rarely fits one OSC datagram.
const PLUGIN_STATE_DIR := "user://plugin_state"

## How long a restore file is kept for the engine to read it.
const PLUGIN_STATE_FILE_TTL_SEC := 30.0

## Guards against double-registering OSC listeners (connect_to_engine can be
## called both from Channel.connect_to_engine() and Channel.add_device()).
var _is_connected: bool = false


## ============================================================================
## INITIALIZATION
## ============================================================================

func _init(p_device: Device, p_channel_id: int, p_position: int, p_active: bool = true, p_enabled: bool = true) -> void:
	id = str(randi_range(0, 2147483647)).pad_zeros(10)  # Simple UUID
	device = p_device
	channel_id = p_channel_id
	position = p_position
	active = p_active
	enabled = p_enabled

	# Initialize all parameters to default normalized values
	if device == null:
		push_error("[DeviceInstance] Created with null device (channel=%d, position=%d)" % [channel_id, position])
		return
	for param in get_parameters():
		parameter_values[param.id] = param.value_to_normalized(param.default_value)
	for route in device.default_mod_routes:
		mod_routes[_mod_key(route["source"], route["param_id"])] = float(route["amount"])


## Assign a path-safe, sibling-unique display name. Emits `name_changed` when it differs.
func set_name(new_name: String) -> void:
	var unique := unique_name_for(new_name)
	if unique == name:
		return
	name = unique
	name_changed.emit(name)


## The name `set_name(desired)` would apply (sanitized, suffixed on a sibling collision).
## Record this (not `desired`) in undo commands so redo reproduces the same name.
func unique_name_for(desired: String) -> String:
	var fallback := device.name if device and not device.name.is_empty() else "Device"
	return DeviceNaming.unique_in(_sibling_names(), desired, fallback)


## Names of siblings on the same host, excluding this instance.
func _sibling_names() -> PackedStringArray:
	var out: PackedStringArray = []
	for d in _sibling_host():
		if d != self and d is DeviceInstance:
			out.append(d.name)
	return out


## Parent children, or the channel root device list when this instance is at the root.
func _sibling_host() -> Array[DeviceInstance]:
	var parent := get_parent_device()
	if parent:
		return parent.children
	var ch := get_channel()
	if ch:
		return ch.devices
	return []


## Mixer channel this instance is on, if still alive.
func get_channel() -> Channel:
	if _channel_ref == null:
		return null
	return _channel_ref.get_ref() as Channel


## Record the owning channel (weak, to avoid RefCounted cycles).
func set_channel(channel: Channel) -> void:
	_channel_ref = weakref(channel) if channel else null


## ============================================================================
## PARAMETER MANAGEMENT
## ============================================================================

## Get parameter metadata by ID: prefers this instance's own advertised
## parameters (SFZ/CLAP) and falls back to the shared Device registry
## (built-ins with a static param list).
func get_parameter(param_id: int) -> DeviceParameter:
	if not parameters.is_empty():
		for param in parameters:
			if param.id == param_id:
				return param
		return null
	return device.get_parameter(param_id) if device else null


## Get parameter metadata by name (case-insensitive), instance-first.
func get_parameter_by_name(param_name: String) -> DeviceParameter:
	if not parameters.is_empty():
		var target = param_name.strip_edges().to_lower()
		for param in parameters:
			if String(param.name).to_lower() == target:
				return param
		return null
	return device.get_parameter_by_name(param_name) if device else null


## All parameter metadata for this instance, instance-first.
func get_parameters() -> Array[DeviceParameter]:
	if not parameters.is_empty():
		return parameters
	return device.get_parameters() if device else []


## Parameters in a UI group ("param" or "cc"), instance-first.
func get_parameters_in_group(group: String) -> Array[DeviceParameter]:
	var source := get_parameters()
	var result: Array[DeviceParameter] = []
	for param in source:
		var param_group = param.group if param.group != "" else "param"
		if param_group == group:
			result.append(param)
	return result


## True when this instance advertises at least one CC-tab parameter.
func has_cc_parameters() -> bool:
	return not get_parameters_in_group("cc").is_empty()


## Set a parameter value (normalized 0.0-1.0)
## This is called from UI controls: it updates the local value, syncs it to the engine and emits
## `parameter_changed` so every view of this device (device view, parameter list) updates. The
## engine's echo only emits again if it corrects the value (see _on_parameter_value_received).
func set_parameter_normalized(param_id: int, normalized_value: float) -> void:
	if param_id in parameter_values:
		var new_value = clamp(normalized_value, 0.0, 1.0)
		var old_value = parameter_values[param_id]

		# Only sync if value actually changed
		if abs(old_value - new_value) > 0.0001:
			parameter_values[param_id] = new_value

			var param = get_parameter(param_id)
			if param == null or param.syncable:
				_expect_echo(param_id)
				sync_parameter_to_engine(param_id)
			parameter_changed.emit(param_id, parameter_values[param_id])


func _expect_echo(param_id: int) -> void:
	var now := Time.get_ticks_msec()
	var pending: Array = _pending_echoes.get(param_id, [0, now])
	var count: int = pending[0] if now - int(pending[1]) < PENDING_ECHO_TIMEOUT_MS else 0
	_pending_echoes[param_id] = [count + 1, now]


## Consume one expected echo for `param_id`. True when newer local values are still in flight,
## meaning the arriving echo is stale and should be ignored.
func _consume_echo(param_id: int) -> bool:
	if not _pending_echoes.has(param_id):
		return false
	var pending: Array = _pending_echoes[param_id]
	if Time.get_ticks_msec() - int(pending[1]) >= PENDING_ECHO_TIMEOUT_MS:
		_pending_echoes.erase(param_id)
		return false
	var remaining: int = int(pending[0]) - 1
	if remaining <= 0:
		_pending_echoes.erase(param_id)
		return false
	pending[0] = remaining
	return true


## Get a parameter value (normalized 0.0-1.0)
func get_parameter_normalized(param_id: int) -> float:
	return parameter_values.get(param_id, 0.5)


## Get parameter ID by name (case-insensitive). Returns -1 if not found
func get_parameter_id_by_name(param_name: String) -> int:
	if device == null:
		return -1
	var p = get_parameter_by_name(param_name)
	return p.id if p else -1


## Get parameter value (normalized) by name. Returns 0.5 if not found
func get_parameter_normalized_by_name(param_name: String) -> float:
	var pid = get_parameter_id_by_name(param_name)
	return get_parameter_normalized(pid) if pid >= 0 else 0.5


## Set parameter value (normalized) by name
func set_parameter_normalized_by_name(param_name: String, normalized_value: float) -> void:
	var pid = get_parameter_id_by_name(param_name)
	if pid >= 0:
		set_parameter_normalized(pid, normalized_value)


## Get parameter value (real) by name
func get_parameter_real_by_name(param_name: String) -> float:
	if device == null:
		return 0.0
	var param = get_parameter_by_name(param_name)
	if param:
		var normalized = get_parameter_normalized(param.id)
		return param.normalized_to_value(normalized)
	return 0.0


## Set parameter value (real) by name
func set_parameter_real_by_name(param_name: String, real_value: float) -> void:
	if device == null:
		return
	var param = get_parameter_by_name(param_name)
	if param:
		var normalized = param.value_to_normalized(real_value)
		set_parameter_normalized(param.id, normalized)


## Set a parameter value (real range)
func set_parameter_real(param_id: int, real_value: float) -> void:
	var param = get_parameter(param_id)
	if param:
		var normalized = param.value_to_normalized(real_value)
		set_parameter_normalized(param_id, normalized)


## True when this instance can own nested devices.
func is_container() -> bool:
	return device != null and device.is_container


## True when `other` is this instance or a nested descendant.
func contains_device(other: DeviceInstance) -> bool:
	if other == null:
		return false
	if other == self:
		return true
	for child in children:
		if child.contains_device(other):
			return true
	return false


## ============================================================================
## MODULATION
## ============================================================================
## Routes are device state, not parameters: a source (e.g. "lfo1") moves a parameter by
## `amount` (-1..1, normalized units per unit of source). They are evaluated inside the engine
## device (per voice) and travel as `{device}/mod/set` / `mod/clear`. Like parameters, the UI
## only calls the setter; the model sends OSC and emits `mod_route_changed`.

static func _mod_key(source: String, param_id: int) -> String:
	return "%s:%d" % [source, param_id]


## Sources this device offers: [{id, name, bipolar}].
func get_mod_sources() -> Array[Dictionary]:
	return device.mod_sources if device != null else ([] as Array[Dictionary])


func has_modulation() -> bool:
	return device != null and device.has_modulation()


## Amount of the route from `source` to `param_id` (0 when there is none).
func get_mod_amount(source: String, param_id: int) -> float:
	return float(mod_routes.get(_mod_key(source, param_id), 0.0))


## Routes into `param_id`: [{source: String, amount: float}], in source-list order.
func get_routes_for_param(param_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for src in get_mod_sources():
		var amount := get_mod_amount(src["id"], param_id)
		if amount != 0.0:
			out.append({"source": src["id"], "amount": amount})
	return out


## Number of routes leaving `source`.
func get_route_count_for_source(source: String) -> int:
	var count := 0
	for key in mod_routes:
		if String(key).begins_with(source + ":"):
			count += 1
	return count


## Set (or with 0, remove) the route from `source` to `param_id`. Syncs to the engine and emits
## `mod_route_changed`; the engine's echo only emits again when it corrects the amount.
func set_mod_amount(source: String, param_id: int, amount: float) -> void:
	amount = clampf(amount, -1.0, 1.0)
	if absf(amount) < 0.001:
		amount = 0.0
	var old := get_mod_amount(source, param_id)
	if is_equal_approx(old, amount):
		return
	_store_mod_amount(source, param_id, amount)
	_expect_mod_echo(_mod_key(source, param_id))
	AudioEngineOSC.send(osc_addr("mod/set"), [source, param_id, amount])
	mod_route_changed.emit(source, param_id, amount)


## Remove every route.
func clear_mod_routes() -> void:
	if mod_routes.is_empty():
		return
	var removed := mod_routes.duplicate()
	mod_routes.clear()
	_expect_mod_echo(MOD_CLEAR_KEY)
	AudioEngineOSC.send(osc_addr("mod/clear"), [])
	_emit_removed_routes(removed)


## Undo step for one mod-amount edit; consecutive drags on the same route merge. The caller
## records it with `HistoryUtil.record()`, as parameter edits do (the model never does).
func mod_amount_command(source: String, param_id: int, old_amount: float, new_amount: float) -> PropertyCommand:
	var cmd := PropertyCommand.new(
		"Set Modulation Amount",
		self,
		"set_mod_amount",
		[source, param_id, old_amount],
		[source, param_id, new_amount]
	)
	# Same target and setter name, so consecutive drags merge (lambdas never compare equal).
	return cmd.set_unpack_array(true).set_mergeable(true)


func _store_mod_amount(source: String, param_id: int, amount: float) -> void:
	var key := _mod_key(source, param_id)
	if amount == 0.0:
		mod_routes.erase(key)
	else:
		mod_routes[key] = amount


func _emit_removed_routes(removed: Dictionary) -> void:
	for key in removed:
		var parts := String(key).rsplit(":", true, 1)
		mod_route_changed.emit(parts[0], int(parts[1]), 0.0)


func _expect_mod_echo(key: String) -> void:
	var now := Time.get_ticks_msec()
	var pending: Array = _pending_mod_echoes.get(key, [0, now])
	var count: int = pending[0] if now - int(pending[1]) < PENDING_ECHO_TIMEOUT_MS else 0
	_pending_mod_echoes[key] = [count + 1, now]


## Consume one expected echo for `key`. True while newer local edits are still in flight, so the
## arriving echo is stale (or just our own) and should be ignored.
func _consume_mod_echo(key: String) -> bool:
	if not _pending_mod_echoes.has(key):
		return false
	var pending: Array = _pending_mod_echoes[key]
	if Time.get_ticks_msec() - int(pending[1]) >= PENDING_ECHO_TIMEOUT_MS:
		_pending_mod_echoes.erase(key)
		return false
	var remaining: int = int(pending[0]) - 1
	if remaining <= 0:
		_pending_mod_echoes.erase(key)
		return false
	pending[0] = remaining
	return true


func _on_mod_set_received(values: Array) -> void:
	if values.size() < 3:
		return
	var source := String(values[0])
	var param_id := int(values[1])
	var amount := float(values[2])
	if _consume_mod_echo(_mod_key(source, param_id)):
		return
	if is_equal_approx(get_mod_amount(source, param_id), amount):
		return
	_store_mod_amount(source, param_id, amount)
	mod_route_changed.emit(source, param_id, amount)


func _on_mod_clear_received(_values: Array) -> void:
	if _consume_mod_echo(MOD_CLEAR_KEY) or mod_routes.is_empty():
		return
	var removed := mod_routes.duplicate()
	mod_routes.clear()
	_emit_removed_routes(removed)


## Make the engine's routes match ours: clear, then one set per route.
func sync_mod_routes_to_engine() -> void:
	if not has_modulation():
		return
	_expect_mod_echo(MOD_CLEAR_KEY)
	AudioEngineOSC.send(osc_addr("mod/clear"), [])
	for key in mod_routes:
		var parts := String(key).rsplit(":", true, 1)
		_expect_mod_echo(String(key))
		AudioEngineOSC.send(osc_addr("mod/set"), [parts[0], int(parts[1]), float(mod_routes[key])])


## ============================================================================
## CONTAINER SLOTS
## ============================================================================
## A slot is a chain of devices that the device lane shows beside its container. A Chain has one
## slot: its own children. Each Layer or Drum Machine child is a slot chain (see SlotChain) whose
## children are the slot's devices; only one of those slots is open at a time. Drum Machine slots
## are keyed by pad note ("pad:36"), so an empty pad has a slot too.

## Key of a Chain's single slot.
const CHAIN_SLOT := "chain"

const PAD_SLOT_PREFIX := "pad:"


## Key of the Drum Machine slot on MIDI `note`.
static func pad_slot_key(note: int) -> String:
	return PAD_SLOT_PREFIX + str(note)


## MIDI note of Drum Machine slot `key`, or -1 for another kind of key.
static func pad_slot_note(key: String) -> int:
	if not key.begins_with(PAD_SLOT_PREFIX) or not key.substr(PAD_SLOT_PREFIX.length()).is_valid_int():
		return -1
	var note := int(key.substr(PAD_SLOT_PREFIX.length()))
	return note if note >= 0 and note <= 127 else -1


func _is_drum_machine() -> bool:
	return device != null and device.device_id == "sonara.builtin.drum_machine"


## Slot keys of existing slots in display order (empty for a non-container).
func slot_keys() -> PackedStringArray:
	var keys := PackedStringArray()
	if not is_container():
		return keys
	if not device.container_focuses_one_child():
		keys.append(CHAIN_SLOT)
		return keys
	for child in children:
		keys.append(pad_slot_key(child.slot_note) if _is_drum_machine() else child.id)
	return keys


## True when `key` names a slot of this container: an existing one, or any pad of a Drum Machine.
func has_slot(key: String) -> bool:
	if _is_drum_machine():
		return pad_slot_note(key) >= 0
	return slot_keys().has(key)


## The Chain holding slot `key`'s devices: this Chain itself, a Layer's or Drum Machine's slot
## chain, or null for an empty pad.
func slot_chain(key: String) -> DeviceInstance:
	if key == CHAIN_SLOT and is_container() and not device.container_focuses_one_child():
		return self
	var note := pad_slot_note(key) if _is_drum_machine() else -1
	for child in children:
		if (note >= 0 and child.slot_note == note) or (note < 0 and child.id == key):
			return child
	return null


## Devices shown in slot `key`. A child that isn't a Chain (never wrapped) is its own slot's device.
func slot_devices(key: String) -> Array[DeviceInstance]:
	var out: Array[DeviceInstance] = []
	var chain := slot_chain(key)
	if chain == null:
		return out
	if chain == self or chain.is_container():
		out.assign(chain.children)
	else:
		out.append(chain)
	return out


## Key of the slot holding `inst` (a slot chain or any device inside it), or "".
func slot_key_for(inst: DeviceInstance) -> String:
	if inst == null or inst == self or not contains_device(inst):
		return ""
	if not device.container_focuses_one_child():
		return CHAIN_SLOT
	for child in children:
		if child.contains_device(inst):
			return pad_slot_key(child.slot_note) if _is_drum_machine() else child.id
	return ""


## Slot caption: "Chain" for a Chain's slot, the slot chain's name for a Layer or Drum Machine
## slot, or the note name of an empty pad.
func slot_title(key: String) -> String:
	if key == CHAIN_SLOT:
		return "Chain"
	var chain := slot_chain(key)
	if chain:
		return chain.get_display_name()
	var note := pad_slot_note(key)
	return Midi.midi_to_note_name(note) if note >= 0 else ""


## Color of slot `key`. A slot without one gets a random color that is kept from then on.
func slot_color(key: String) -> Color:
	if not _slot_colors.has(key):
		_slot_colors[key] = Color.from_hsv(randf(), 0.6, 0.72)
	return _slot_colors[key]


func set_slot_color(key: String, color: Color) -> void:
	_slot_colors[key] = color
	slots_changed.emit()


func is_slot_open(key: String) -> bool:
	return _open_slots.has(key) and has_slot(key)


## Open slots in display order (keys of removed children are skipped).
func open_slot_keys() -> PackedStringArray:
	var out := PackedStringArray()
	if _is_drum_machine():
		for key in _open_slots:
			if has_slot(key):
				out.append(key)
		return out
	for key in slot_keys():
		if _open_slots.has(key):
			out.append(key)
	return out


## Show or hide slot `key` in the device lane. Opening a Layer or Drum Machine slot closes the other.
func set_slot_open(key: String, open: bool) -> void:
	if open == is_slot_open(key) or not has_slot(key):
		return
	if open and device.container_focuses_one_child():
		_open_slots = PackedStringArray([key])
	elif open:
		_open_slots.append(key)
	else:
		_open_slots.remove_at(_open_slots.find(key))
	slots_changed.emit()


func toggle_slot(key: String) -> void:
	set_slot_open(key, not is_slot_open(key))


## Open the slot holding `inst` (after a device lands in this container).
func reveal_child(inst: DeviceInstance) -> void:
	set_slot_open(slot_key_for(inst), true)


## Slot colors and open slots for the project file, keeping only slots that still exist.
func _slots_to_json() -> Dictionary:
	var colors := {}
	for key in _slot_colors:
		if has_slot(key):
			colors[key] = (_slot_colors[key] as Color).to_html(false)
	return {"colors": colors, "open": Array(open_slot_keys())}


func _slots_from_json(data: Variant) -> void:
	if not data is Dictionary:
		return
	var colors: Variant = data.get("colors", {})
	if colors is Dictionary:
		for key in colors:
			_slot_colors[str(key)] = Color.from_string(str(colors[key]), Color.GRAY)
	var open: Variant = data.get("open", [])
	if open is Array:
		_open_slots = PackedStringArray(open.map(func(k): return str(k)))


## Positions of children wrapped into slot chains while loading (see `_wrap_slot_children`), so
## the channel can fix automation paths that pointed into them. Empty after load.
var migrated_slot_positions: Array[int] = []


## Projects saved before slot chains hold Layer and Drum Machine devices directly: wrap each one in
## a slot chain, and move its slot color and open state from the device's key to the slot's.
func _wrap_slot_children() -> void:
	if not SlotChain.is_slot_parent(self):
		return
	for i in children.size():
		var child := children[i]
		if SlotChain.is_chain(child):
			continue
		var old_key := child.id
		var chain := SlotChain.wrap_device(child)
		if chain == child:
			return
		chain.position = i
		chain.set_parent_device(self)
		children[i] = chain
		migrated_slot_positions.append(i)
		var new_key := pad_slot_key(chain.slot_note) if _is_drum_machine() else chain.id
		if _slot_colors.has(old_key):
			_slot_colors[new_key] = _slot_colors[old_key]
			_slot_colors.erase(old_key)
		var open_at := _open_slots.find(old_key)
		if open_at >= 0:
			_open_slots[open_at] = new_key


## Parent container, or null at the channel root.
func get_parent_device() -> DeviceInstance:
	if _parent_ref == null:
		return null
	return _parent_ref.get_ref() as DeviceInstance


## Record the parent container (weak, to avoid RefCounted cycles).
func set_parent_device(parent: DeviceInstance) -> void:
	_parent_ref = weakref(parent) if parent else null


## OSC prefix `/channel/{id}/device/{i0}/child/{i1}` with no trailing action.
func osc_path() -> String:
	var indices: Array[int] = []
	var current: DeviceInstance = self
	while current:
		indices.insert(0, current.position)
		current = current.get_parent_device()
	if indices.is_empty():
		return "/channel/%d/device/%d" % [channel_id, position]
	var path := "/channel/%d/device/%d" % [channel_id, indices[0]]
	for i in range(1, indices.size()):
		path += "/child/%d" % indices[i]
	return path


## Full OSC address for an action on this device (`enable`, `param/0`, ...).
func osc_addr(action: String) -> String:
	if action.is_empty():
		return osc_path()
	return "%s/%s" % [osc_path(), action]


## Index path from the channel root, e.g. `"0/1"`.
func path_string() -> String:
	var indices: Array[int] = []
	var current: DeviceInstance = self
	while current:
		indices.insert(0, current.position)
		current = current.get_parent_device()
	return "/".join(indices.map(func(i): return str(i)))


## Rebind OSC listeners after this instance's path changes.
func reconnect_to_engine() -> void:
	disconnect_from_engine()
	if channel_id >= 0:
		connect_to_engine()


## Get a parameter value (real range)
func get_parameter_real(param_id: int) -> float:
	var param = get_parameter(param_id)
	if param:
		var normalized = get_parameter_normalized(param_id)
		return param.normalized_to_value(normalized)
	return 0.5


## Get all parameter values as a dictionary (for UI)
func get_all_parameters_normalized() -> Dictionary[int, float]:
	return parameter_values.duplicate()


## ============================================================================
## SYNC WITH ENGINE
## ============================================================================

## Set the enabled state of this device instance (sends to engine)
func set_enabled(p_enabled : bool) -> void:
	if enabled == p_enabled:
		return
	# we only send to engine, we don't update our own state - we do this on engine callback
	AudioEngineOSC.send(osc_addr("enable"), [1 if p_enabled else 0])

## Set the active state of this device instance (sends to engine)
func set_active(p_active : bool) -> void:
	if active == p_active:
		return
	
	AudioEngineOSC.send(osc_addr("activate"), [1 if p_active else 0])


## Open the native GUI for this device (if supported)
func open_gui() -> void:
	if not device.has_gui():
		push_warning("[DeviceInstance] Device %s does not have a native GUI" % device.name)
		return
	
	if active:
		AudioEngineOSC.send(osc_addr("gui/open"), [])


## Close the native GUI for this device (if supported)
func close_gui() -> void:
	if not device.has_gui():
		return
	
	AudioEngineOSC.send(osc_addr("gui/close"), [])


## Ask the engine to respawn this device's crashed plugin host and restore its state.
## Safe to call for a non-crashed device (the engine ignores it) but intended for a
## device whose `loading_state` begins with "crashed:".
func reload() -> void:
	AudioEngineOSC.send(osc_addr("reload"), [])


## Ask the engine to re-send the loading state and (for SFZ/CLAP) the parameter list of this
## device and its children. OSC runs over UDP, which drops packets when Godot stalls (e.g. while
## building a large project), and a missed loading_state or param/info leaves a device stuck.
func request_state() -> void:
	if not _is_connected:
		return
	AudioEngineOSC.send(osc_addr("state/get"), [])
	for child in children:
		child.request_state()


## Keep asking for the state while the device is "loading", in case "ready" was dropped.
func _schedule_loading_recheck() -> void:
	if _loading_recheck_pending:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_loading_recheck_pending = true
	tree.create_timer(LOADING_RECHECK_SEC).timeout.connect(_on_loading_recheck)


func _on_loading_recheck() -> void:
	_loading_recheck_pending = false
	if not _is_connected or loading_state != "loading":
		return
	request_state()
	_schedule_loading_recheck()


func _set_loading_state(new_state: String) -> void:
	if new_state == "loading":
		_schedule_loading_recheck()
	if loading_state == new_state:
		return
	loading_state = new_state
	if loading_state == "ready":
		_restore_plugin_state()
	loading_state_changed.emit(loading_state)


## ============================================================================
## PLUGIN STATE
## ============================================================================

## Ask the engine to write this plugin's current state to a file; `plugin_state_saved` fires
## when it answered, and `plugin_state` holds the blob if it had one. Returns false (and emits
## nothing) when there's nothing to ask: not a loaded CLAP plugin, or not connected.
func save_plugin_state() -> bool:
	if not device.has_gui() or not _is_connected or loading_state != "ready":
		return false
	var file_path := _plugin_state_file_path("save")
	if file_path.is_empty():
		return false
	AudioEngineOSC.send(osc_addr("state/save"), [file_path])
	return true


func _on_plugin_state_saved_received(values: Array) -> void:
	if values.size() < 2:
		return
	var file_path := str(values[0])
	var size := int(values[1])
	var ok := size >= 0
	if size > 0:
		var blob := FileAccess.get_file_as_bytes(file_path)
		if blob.size() == size:
			plugin_state = blob
			# The engine now has what we'd restore: a later "ready" (reload) mustn't roll it back.
			_plugin_state_restore_pending = false
		else:
			logger.warn("[%s] Plugin state file %s is %d bytes, expected %d" % [get_display_name(), file_path, blob.size(), size])
			ok = false
	elif size < 0:
		logger.warn("[%s] Could not save plugin state; keeping the last saved one" % get_display_name())
	DirAccess.remove_absolute(file_path)
	plugin_state_saved.emit(ok)


## Send a project-loaded state blob to the engine once the plugin is ready.
func _restore_plugin_state() -> void:
	if not _plugin_state_restore_pending or plugin_state.is_empty() or not _is_connected:
		return
	_plugin_state_restore_pending = false
	var file_path := _plugin_state_file_path("load")
	if file_path.is_empty():
		return
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		logger.warn("[%s] Could not write plugin state file %s" % [get_display_name(), file_path])
		return
	file.store_buffer(plugin_state)
	file.close()
	AudioEngineOSC.send(osc_addr("state/load"), [file_path])
	logger.info("[%s] Restoring %d bytes of plugin state" % [get_display_name(), plugin_state.size()])
	# The engine reads the file on its command thread; give it time before cleaning up.
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		tree.create_timer(PLUGIN_STATE_FILE_TTL_SEC).timeout.connect(func(): DirAccess.remove_absolute(file_path))


## Absolute path of a state hand-over file for this instance ("" if the directory can't be made).
func _plugin_state_file_path(kind: String) -> String:
	var dir := ProjectSettings.globalize_path(PLUGIN_STATE_DIR)
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		logger.warn("Could not create plugin state directory %s" % dir)
		return ""
	return dir.path_join("%s_%s_%d.bin" % [id, kind, Time.get_ticks_usec()])


## Connect to audio engine and listen for state updates.
## Registers OSC listeners only; the file (if any) is loaded with a proper
## req_id by Channel.sync_to_engine()/_sync_device_tree_to_engine(), which
## runs whenever this instance is synced to the engine (project load,
## channel connect, or add_device while already connected).
func connect_to_engine() -> void:
	if _is_connected:
		return
	_is_connected = true

	var active_addr = osc_addr("active")
	var enabled_addr = osc_addr("enabled")
	var param_count_addr = osc_addr("param/count")
	var param_info_addr = osc_addr("param/info")
	var loading_state_addr = osc_addr("loading_state")
	var gui_closed_addr = osc_addr("gui/closed")
	var crashed_addr = osc_addr("crashed")
	var host_addr = osc_addr("host")
	var stats_addr = osc_addr("stats")
	var state_saved_addr = osc_addr("state/saved")

	AudioEngineOSC.listen(osc_addr("keys/info"), _on_key_info_received)
	AudioEngineOSC.listen(active_addr, _on_active_received)
	AudioEngineOSC.listen(enabled_addr, _on_enabled_received)
	AudioEngineOSC.listen(param_count_addr, _on_param_count_received)
	AudioEngineOSC.listen(param_info_addr, _on_param_info_received)
	AudioEngineOSC.listen(loading_state_addr, _on_loading_state_received)
	AudioEngineOSC.listen(gui_closed_addr, _on_gui_closed_received)
	AudioEngineOSC.listen(crashed_addr, _on_crashed_received)
	AudioEngineOSC.listen(host_addr, _on_host_received)
	AudioEngineOSC.listen(stats_addr, _on_stats_received)
	AudioEngineOSC.listen(state_saved_addr, _on_plugin_state_saved_received)

	# Use wildcard pattern to listen for ALL parameter changes for this device
	var param_pattern = osc_addr("param/*/value")
	AudioEngineOSC.listen(param_pattern, _on_parameter_value_received_wildcard)
	AudioEngineOSC.listen(osc_addr("mod/set"), _on_mod_set_received)
	AudioEngineOSC.listen(osc_addr("mod/clear"), _on_mod_clear_received)

	sync_slot_to_engine()
	for child in children:
		child.connect_to_engine()


## Disconnect from audio engine: stop listening.
func disconnect_from_engine() -> void:
	if not _is_connected:
		return
	_is_connected = false

	var active_addr = osc_addr("active")
	var enabled_addr = osc_addr("enabled")
	var param_count_addr = osc_addr("param/count")
	var param_info_addr = osc_addr("param/info")
	var param_pattern = osc_addr("param/*/value")
	var loading_state_addr = osc_addr("loading_state")
	var gui_closed_addr = osc_addr("gui/closed")
	var crashed_addr = osc_addr("crashed")
	var host_addr = osc_addr("host")
	var stats_addr = osc_addr("stats")
	var state_saved_addr = osc_addr("state/saved")

	AudioEngineOSC.unlisten(osc_addr("keys/info"), _on_key_info_received)
	AudioEngineOSC.unlisten(active_addr, _on_active_received)
	AudioEngineOSC.unlisten(enabled_addr, _on_enabled_received)
	AudioEngineOSC.unlisten(param_count_addr, _on_param_count_received)
	AudioEngineOSC.unlisten(param_info_addr, _on_param_info_received)
	AudioEngineOSC.unlisten(param_pattern, _on_parameter_value_received_wildcard)
	AudioEngineOSC.unlisten(osc_addr("mod/set"), _on_mod_set_received)
	AudioEngineOSC.unlisten(osc_addr("mod/clear"), _on_mod_clear_received)
	AudioEngineOSC.unlisten(loading_state_addr, _on_loading_state_received)
	AudioEngineOSC.unlisten(gui_closed_addr, _on_gui_closed_received)
	AudioEngineOSC.unlisten(crashed_addr, _on_crashed_received)
	AudioEngineOSC.unlisten(host_addr, _on_host_received)
	AudioEngineOSC.unlisten(stats_addr, _on_stats_received)
	AudioEngineOSC.unlisten(state_saved_addr, _on_plugin_state_saved_received)
	for child in children:
		child.disconnect_from_engine()


## ============================================================================
## OSC CALLBACKS (from engine)
## ============================================================================

func _on_active_received(values: Array) -> void:
	"""Handle active state update from engine (don't send back to avoid loop)."""
	if values.size() >= 1:
		var new_active = values[0] != 0
		if active != new_active:
			active = new_active
			active_changed.emit(active)


func _on_enabled_received(values: Array) -> void:
	"""Handle enabled state update from engine (don't send back to avoid loop)."""
	if values.size() >= 1:
		var new_enabled = values[0] != 0
		if enabled != new_enabled:
			enabled = new_enabled
			enabled_changed.emit(enabled)


func _on_loading_state_received(values: Array) -> void:
	"""Handle loading state update from engine."""
	if values.size() >= 1:
		var new_state = str(values[0])
		if loading_state != new_state:
			_set_loading_state(new_state)

			# Log state changes for debugging
			if loading_state.begins_with("failed:"):
				push_error("[DeviceInstance %s] Loading failed: %s" % [device.name, loading_state])
			elif loading_state == "ready":
				logger.info("[%s] Loading complete" % device.name)


func _on_gui_closed_received(_values: Array) -> void:
	"""Handle GUI closed notification from engine."""
	logger.info("[%s] Plugin GUI closed by engine" % device.name)
	plugin_gui_closed.emit()


func _on_crashed_received(values: Array) -> void:
	"""Handle a plugin-host crash: record it, surface it, and offer a Reload action."""
	crash_reason = str(values[0]) if values.size() >= 1 else "unknown"
	crash_stderr = str(values[1]) if values.size() >= 2 else ""
	var pid: int = int(values[2]) if values.size() >= 3 else 0
	crash_log_path = str(values[3]) if values.size() >= 4 else ""
	# A dead host reports nothing more; drop the last numbers rather than show them as current.
	if plugin_stats != null:
		plugin_stats = null
		stats_changed.emit()

	_set_loading_state("crashed:" + crash_reason)
	logger.warn("[%s] Plugin crashed: %s" % [device.name, crash_reason])
	crashed.emit(crash_reason, crash_stderr)

	if Utils.is_test_mode():
		return
	if pid != 0 and pid == _last_crash_popup_pid:
		return
	_last_crash_popup_pid = pid
	if Sonara and Sonara.editor:
		var display_name := get_display_name()
		var body := crash_reason + "\n\nDevice: " + display_name
		if host_mode != "" and host_mode != "individually":
			body += "\n\nThe host process was shared (%s): every plugin in it stopped. Reload restores all of them." % PluginHosting.MODE_LABELS.get(host_mode, host_mode)
		if not crash_stderr.is_empty():
			body += "\n\nHost stderr:\n" + crash_stderr
		if not crash_log_path.is_empty():
			body += "\n\nFull host log: " + crash_log_path
		Sonara.editor.show_error("Plugin crashed: %s" % display_name, body, [
			{"text": "Reload", "callback": reload},
		])


func _on_host_received(values: Array) -> void:
	"""The plugin loaded into a host process (first load, reload, or a hosting-mode move)."""
	if values.size() < 3:
		return
	host_mode = str(values[0])
	host_key = str(values[1])
	host_pid = int(values[2])
	host_changed.emit()


func _on_stats_received(values: Array) -> void:
	"""One second of the plugin's processing stats (CLAP devices, 1 Hz while processing)."""
	if values.size() < 8:
		return
	plugin_stats = PluginStats.from_osc(values, Time.get_ticks_msec())
	stats_changed.emit()


## True when the plugin missed several processing deadlines in a row in its last report.
func is_struggling() -> bool:
	return plugin_stats != null and plugin_stats.struggling and plugin_stats.is_fresh(Time.get_ticks_msec())


## One line about the plugin host process, for tooltips. "" before the plugin has loaded.
func host_description() -> String:
	if host_pid == 0:
		return ""
	return "Plugin host: %s (pid %d)" % [PluginHosting.MODE_LABELS.get(host_mode, host_mode), host_pid]


func _on_parameter_value_received_wildcard(values: Array, address: String) -> void:
	"""Handle parameter value changes via wildcard pattern.
	Parse param_id from the OSC address: /channel/X/device/Y/param/ID/value"""
	# Parse parameter ID from address: .../param/ID/value
	var parts = address.split("/")
	var param_idx := parts.find("param")
	if param_idx < 0 or param_idx + 1 >= parts.size():
		push_warning("[DeviceInstance] Invalid parameter address format: %s" % address)
		return
	var param_id = int(parts[param_idx + 1])
	_on_parameter_value_received(values, param_id)


func _on_parameter_value_received(values: Array, param_id: int) -> void:
	"""Handle parameter value changes from the engine (all changes, including echoes).
	Receives both: echoes of our UI changes AND plugin-initiated changes (GUI, preset, modulation).
	Emits only when the value differs from the local one; echoes of older values sent by this
	instance are dropped while a newer one is still in flight."""
	if values.size() < 1:
		return

	var new_value = float(values[0])

	# Update parameter if it exists
	if param_id not in parameter_values:
		push_warning("[DeviceInstance] Received update for unknown parameter %d" % param_id)
		return

	if _consume_echo(param_id):
		return

	var old_value = parameter_values[param_id]
	if abs(old_value - new_value) > 0.0001:  # Floating point tolerance
		parameter_values[param_id] = clamp(new_value, 0.0, 1.0)
		parameter_changed.emit(param_id, parameter_values[param_id])


func _on_param_count_received(args: Array) -> void:
	"""Handle parameter count message from engine (start of parameter list)."""
	if args.size() < 1:
		push_warning("[DeviceInstance %s] Invalid param count message" % device.name)
		return
	
	var count: int = args[0]
	_expected_param_count = count

	# A re-advertised list (state/get resync, plugin reload, new SFZ) keeps the current values
	# instead of resetting them to defaults; they are sent back once the list is complete.
	for param_id in parameter_values:
		if param_id not in _restored_parameter_values:
			_restored_parameter_values[param_id] = parameter_values[param_id]

	# Clear existing parameters when we receive a new count
	# This handles cases where parameters change (e.g., SFZ file loaded)
	parameters.clear()
	parameter_values.clear()
	
	logger.debug("[%s] Expecting %d parameters" % [device.name, count])


## `keys/info`: [count, count x (key, is_keyswitch, label), range_count, range_count x (lo, hi)].
## Always replaces the whole list and the ranges, so a count of 0 (a reload to an SFZ with no labels) clears it.
func _on_key_info_received(args: Array) -> void:
	var count: int = args[0] if args.size() >= 1 else 0
	var keys: Array = []
	for i in count:
		var base := 1 + i * 3
		if base + 2 >= args.size():
			break
		keys.append({"key": int(args[base]), "keyswitch": int(args[base + 1]) != 0, "label": str(args[base + 2])})
	keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.key < b.key)
	key_labels = keys
	# The ranges follow the entries: [range_count, (lo, hi)...]. An older engine sends none.
	var ranges: Array = []
	var range_at := 1 + count * 3
	if args.size() > range_at:
		for i in int(args[range_at]):
			var base := range_at + 1 + i * 2
			if base + 1 >= args.size():
				break
			ranges.append([int(args[base]), int(args[base + 1])])
	playable_ranges = ranges
	key_info_received = true
	key_labels_changed.emit()


func _on_param_info_received(args: Array) -> void:
	"""Handle parameter info message from engine."""
	if args.size() < 5:
		push_warning("[DeviceInstance %s] Invalid param info message" % device.name)
		return
	
	var param_id: int = args[0]
	var param_name: String = args[1]
	var min_val: float = args[2]
	var max_val: float = args[3]
	var default_val: float = args[4]

	# Create DeviceParameter and add to device
	var param = DeviceParameter.new(param_id, param_name, "")
	param.min_value = min_val
	param.max_value = max_val
	param.default_value = default_val
	if args.size() >= 6 and args[5] is String:
		param.group = args[5]
	if args.size() >= 7 and args[6] is String:
		param.param_type = args[6]
	var flags: int = args[7] if args.size() >= 8 else 0
	param.is_hidden = (flags & 1) != 0
	param.is_read_only = (flags & 2) != 0
	param.is_bypass = (flags & 4) != 0
	if args.size() >= 9 and args[8] is String:
		param.module = args[8]
	if args.size() >= 10:
		var enum_count: int = args[9]
		var enum_values: Array[String] = []
		for i in range(enum_count):
			var arg_idx := 10 + i
			if arg_idx < args.size():
				enum_values.append(str(args[arg_idx]))
		param.enum_values = enum_values
	parameters.append(param)
	
	parameter_values[param_id] = _value_for_advertised_param(param_id, param)
	
	logger.debug("[%s] Param %d: %s [%.2f - %.2f, default %.2f, type %s, module '%s']" %
		[device.name, param_id, param_name, min_val, max_val, default_val, param.param_type, param.module])

	# Check if we've received all expected parameters
	if parameters.size() >= _expected_param_count and _expected_param_count > 0:
		logger.debug("[%s] All %d parameters loaded" % [device.name, _expected_param_count])
		_expected_param_count = 0  # Reset
		_push_restored_parameters_to_engine()
		parameters_updated.emit()


## Prefer a project-restored value over the engine default when a param list is advertised.
func _value_for_advertised_param(param_id: int, param: DeviceParameter) -> float:
	if param_id in _restored_parameter_values:
		return clamp(_restored_parameter_values[param_id], 0.0, 1.0)
	return param.value_to_normalized(param.default_value)


## After SFZ/plugin param advertisement, send restored values so the engine matches the project.
func _push_restored_parameters_to_engine() -> void:
	if _restored_parameter_values.is_empty():
		return
	sync_to_engine()
	_restored_parameter_values.clear()


## Sync this device instance's parameters to the audio engine (bulk sync)
## TODO: Implement this
func sync_to_engine() -> void:
	sync_mod_routes_to_engine()
	for param_id in parameter_values:
		var param = get_parameter(param_id)
		if param and not param.syncable:
			continue
		var normalized_value = parameter_values[param_id]
		if param and param.param_type == "bool":
			var idx: int = 1 if normalized_value >= 0.5 else 0
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [idx])
		elif param and param.param_type == "enum":
			var n: int = max(1, param.enum_values.size())
			var idx: int = int(round(normalized_value * float(n - 1)))
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [idx])
		else:
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [normalized_value])
	# A Drum Machine pad re-sends its choke group so a reload restores it (the note itself goes
	# through sync_slot_to_engine() in the device-tree walk).
	var choke_addr := _drum_pad_addr("choke")
	if choke_addr != "":
		AudioEngineOSC.send(choke_addr, [choke_group])


## Sync a single parameter to the audio engine
func sync_parameter_to_engine(param_id: int) -> void:
	if param_id in parameter_values:
		var param = get_parameter(param_id)
		if param and not param.syncable:
			return
		var normalized_value = parameter_values[param_id]
		if param and param.param_type == "bool":
			var idx: int = 1 if normalized_value >= 0.5 else 0
			logger.debug("send BOOL param_id=", param_id, " idx=", idx)
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [idx])
		elif param and param.param_type == "enum":
			var n: int = max(1, param.enum_values.size())
			var idx: int = int(round(normalized_value * float(n - 1)))
			logger.debug("send ENUM param_id=", param_id, " idx=", idx, " n=", n, " normalized=", normalized_value)
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [idx])
		else:
			logger.debug("send FLOAT param_id=", param_id, " normalized=", normalized_value)
			AudioEngineOSC.send(osc_addr("param/%d" % param_id), [normalized_value])


## Load a file into this device (SFZ or audio sample).
func load_file(file_path: String) -> void:
	if not device.supports_file_loading:
		push_error("[DeviceInstance] Device %s does not support file loading" % device.name)
		return

	logger.info("Loading file into %s: %s" % [device.name, file_path])
	loaded_file_path = file_path
	key_info_received = false
	if sample_source == null:
		sample_source = AudioSourceInfo.new()
	else:
		sample_source.reset()
	var req_id := "device:%s:%d" % [id, Time.get_ticks_usec()]
	var channel := get_channel()
	var project := channel.get_project() if channel else null
	if project:
		project.track_device_request(self, req_id)
	else:
		logger.warn("load_file on %s before it is on a project channel; waveform won't be tracked" % name)
	AudioEngineOSC.send(osc_addr("load_file"), [file_path, req_id])
	# Also set locally: if the engine's own "loading" is dropped, the re-check still runs.
	_set_loading_state("loading")


## Remember `file_path` for an instance that is not on a channel yet. Channel.add_device()
## loads it right after telling the engine to create the device (or on connect when offline),
## so callers never have to wait for the engine before loading.
func queue_file_load(file_path: String) -> void:
	if device == null or not device.supports_file_loading:
		push_error("[DeviceInstance] Device %s does not support file loading" % (device.name if device else "?"))
		return
	loaded_file_path = file_path


## Send Layer/Drum slot controls to the engine (no-op for other parents).
func sync_slot_to_engine() -> void:
	var parent := get_parent_device()
	if parent == null or parent.device == null:
		return
	if _is_layer(parent):
		for action in LAYER_SLOT_ACTIONS:
			_send_layer_slot(action)
	elif parent.device.device_id == "sonara.builtin.drum_machine" and slot_note >= 0:
		AudioEngineOSC.send(parent.osc_addr("slot/%d/note" % position), [slot_note])


## OSC address for a control (`note`, `choke`) on this Drum Machine pad, or "" when this
## instance is not a pad (its parent is not a Drum Machine, or it has no note yet).
func _drum_pad_addr(action: String) -> String:
	var parent := get_parent_device()
	if parent == null or parent.device == null:
		return ""
	if parent.device.device_id != "sonara.builtin.drum_machine" or slot_note < 0:
		return ""
	return parent.osc_addr("slot/%d/%s" % [position, action])


## Layer slot controls, each sent as `slot/{position}/{action}`.
const LAYER_SLOT_ACTIONS := ["volume", "mute", "solo", "note_map", "separate_out"]


## Send one Layer slot control (no-op unless the parent is a Layer).
func _send_layer_slot(action: String) -> void:
	var parent := get_parent_device()
	if not _is_layer(parent):
		return
	var value
	match action:
		"volume": value = slot_volume
		"mute": value = 1 if slot_mute else 0
		"solo": value = 1 if slot_solo else 0
		"note_map": value = slot_note_map
		"separate_out": value = 1 if slot_separate_out else 0
	AudioEngineOSC.send(parent.osc_addr("slot/%d/%s" % [position, action]), [value])


static func _is_layer(inst: DeviceInstance) -> bool:
	return inst != null and inst.device != null and inst.device.device_id == "sonara.builtin.layer"


## Set this child's Layer slot volume (normalized 0–1, 0.5 = unity).
func set_slot_volume(normalized: float) -> void:
	slot_volume = clampf(normalized, 0.0, 1.0)
	_send_layer_slot("volume")
	slot_changed.emit()


## Mute this Layer slot.
func set_slot_mute(muted: bool) -> void:
	slot_mute = muted
	_send_layer_slot("mute")
	slot_changed.emit()


## Solo this Layer slot.
func set_slot_solo(soloed: bool) -> void:
	slot_solo = soloed
	_send_layer_slot("solo")
	slot_changed.emit()


## Replace this Layer slot's note map (see LayerNoteMap). Invalid maps are ignored.
func set_slot_note_map(map: PackedByteArray) -> void:
	if not LayerNoteMap.is_valid(map):
		logger.warn("Ignoring invalid Layer note map (%d bytes)" % map.size())
		return
	slot_note_map = map.duplicate()
	_send_layer_slot("note_map")
	slot_changed.emit()


## Send this Layer slot to its own return channel (created or restored by AuxReturnSync).
func set_slot_separate_out(on: bool) -> void:
	if slot_separate_out == on:
		return
	slot_separate_out = on
	var layer := get_parent_device()
	var channel := get_channel()
	if layer != null and channel != null:
		AuxReturnSync.on_layer_slot_separate_changed(channel.get_project(), channel, layer, self)
	_send_layer_slot("separate_out")
	slot_changed.emit()


## Play `note` on this Layer slot only, bypassing its note map (mapping window audition).
func audition_slot(note: int, velocity: int, is_note_on: bool) -> void:
	var parent := get_parent_device()
	if not _is_layer(parent):
		return
	AudioEngineOSC.send(parent.osc_addr("slot/%d/audition" % position), [note, velocity, 1 if is_note_on else 0])


## Assign the MIDI note this Drum Machine child responds to.
func set_slot_note(note: int) -> void:
	slot_note = clampi(note, 0, 127)
	sync_slot_to_engine()
	slot_changed.emit()


## Set this Drum Machine pad's choke group (0 = none, 1–8) and tell the engine.
func set_choke_group(group: int) -> void:
	choke_group = clampi(group, 0, 8)
	var addr := _drum_pad_addr("choke")
	if addr != "":
		AudioEngineOSC.send(addr, [choke_group])
	choke_group_changed.emit(choke_group)


## Next unused pad note from C1 upward (Drum Machine containers only).
func next_free_drum_note() -> int:
	var used := {}
	for child in children:
		if child.slot_note >= 0:
			used[child.slot_note] = true
	for n in range(36, 128):
		if not used.has(n):
			return n
	for n in range(0, 36):
		if not used.has(n):
			return n
	return 36


## ============================================================================
## SERIALIZATION
## ============================================================================

## Remember the preset this device now stands for ("" clears it).
func set_preset(p_name: String, p_path: String = "") -> void:
	if p_name == preset_name and p_path == preset_path:
		return
	preset_name = p_name
	preset_path = p_path
	preset_changed.emit()


## Serialize to JSON
func to_json() -> Dictionary:
	var data := {
		"id": id,
		"name": name,
		"device_id": device.id,
		"channel_id": channel_id,
		"position": position,
		"active": active,
		"enabled": enabled,
		"parameter_values": _parameter_values_to_json(),
		"loaded_file_path": loaded_file_path,
		"children": children.map(func(c): return c.to_json()),
		"slot_volume": slot_volume,
		"slot_mute": slot_mute,
		"slot_solo": slot_solo,
		"slot_note": slot_note,
		"choke_group": choke_group,
		"slot_separate_out": slot_separate_out,
		"return_channel_id": return_channel_id,
		"return_channel_ids": return_channel_ids.duplicate(),
		"slots": _slots_to_json(),
	}
	if not preset_name.is_empty():
		data["preset_name"] = preset_name
		data["preset_path"] = preset_path
	if has_modulation():
		data["mod_routes"] = _mod_routes_to_json()
	if not plugin_state.is_empty():
		data["plugin_state"] = Marshalls.raw_to_base64(plugin_state)
	var note_map_json = LayerNoteMap.to_json(slot_note_map)
	if note_map_json != null:
		data["slot_note_map"] = note_map_json
	return data


## `[{source, param_id, amount}]`, sorted so saves are stable.
func _mod_routes_to_json() -> Array:
	var out: Array = []
	for key in mod_routes:
		var parts := String(key).rsplit(":", true, 1)
		out.append({"source": parts[0], "param_id": int(parts[1]), "amount": mod_routes[key]})
	out.sort_custom(func(a, b): return _mod_key(a["source"], a["param_id"]) < _mod_key(b["source"], b["param_id"]))
	return out


## JSON object keys must be strings; keep parameter IDs stable across save/load.
func _parameter_values_to_json() -> Dictionary:
	var out := {}
	for param_id in parameter_values:
		out[str(param_id)] = parameter_values[param_id]
	return out


## Give a serialized device tree new instance ids on `channel_id`, dropping aux return links.
static func refresh_ids_in_json(device_data: Dictionary, channel_id: int) -> void:
	device_data.erase("id")
	device_data["channel_id"] = channel_id
	device_data["return_channel_id"] = -1
	device_data["return_channel_ids"] = []
	for child_data in device_data.get("children", []):
		if child_data is Dictionary:
			refresh_ids_in_json(child_data, channel_id)


## Ask every loaded CLAP plugin under `roots` for its current state so `to_json()` saves it. Waits
## until all of them answered or `timeout_sec` passed; a plugin that didn't answer keeps its last
## saved state. Returns true when every request was answered in time.
static func refresh_plugin_states(roots: Array, timeout_sec: float = 3.0) -> bool:
	var waiting: Array[DeviceInstance] = []
	for inst in roots:
		_collect_plugin_state_requests(inst, waiting)
	if waiting.is_empty():
		return true
	var remaining := {"count": waiting.size()}
	var on_saved := func(_ok: bool) -> void:
		remaining.count -= 1
	for inst in waiting:
		inst.plugin_state_saved.connect(on_saved, CONNECT_ONE_SHOT)
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while remaining.count > 0 and Time.get_ticks_msec() < deadline and tree:
		await tree.process_frame
	for inst in waiting:
		if inst.plugin_state_saved.is_connected(on_saved):
			inst.plugin_state_saved.disconnect(on_saved)
	if remaining.count > 0:
		logger.warn("%d plugin(s) didn't return their state in time; using their last known state" % remaining.count)
		return false
	return true


static func _collect_plugin_state_requests(inst: DeviceInstance, out: Array[DeviceInstance]) -> void:
	if inst.save_plugin_state():
		out.append(inst)
	for child in inst.children:
		_collect_plugin_state_requests(child, out)


## Deserialize from JSON
static func from_json(data: Dictionary) -> DeviceInstance:
	var device_id = data.get("device_id", "")
	var loaded_device = AssetService.get_device(device_id)
	
	if not loaded_device:
		logger.warn("Device not found (may need plugin scan): %s" % device_id)
		return null
	
	var chan_id = data.get("channel_id", 0)
	var pos = data.get("position", 0)
	var is_active = data.get("active", true)
	var is_enabled = data.get("enabled", true)
	
	var instance = DeviceInstance.new(loaded_device, chan_id, pos, is_active, is_enabled)
	instance.id = data.get("id", instance.id)  # Restore original ID
	instance.name = str(data.get("name", ""))
	instance.preset_name = str(data.get("preset_name", ""))
	instance.preset_path = str(data.get("preset_path", ""))
	
	# Restore parameter values (kept aside so SFZ/plugin advertisement does not wipe them)
	var param_values = data.get("parameter_values", {})
	for param_id_str in param_values.keys():
		var param_id = int(param_id_str) if param_id_str is String else param_id_str
		var value = float(param_values[param_id_str])
		instance.parameter_values[param_id] = value
		instance._restored_parameter_values[param_id] = value
	
	# Saved routes replace the default patch (an empty list means the user removed them all);
	# a project saved before routes existed keeps the defaults.
	if data.has("mod_routes") and data["mod_routes"] is Array:
		instance.mod_routes.clear()
		for route in data["mod_routes"]:
			if route is Dictionary and route.has("source") and route.has("param_id"):
				var amount := clampf(float(route.get("amount", 0.0)), -1.0, 1.0)
				if amount != 0.0:
					instance.mod_routes[_mod_key(str(route["source"]), int(route["param_id"]))] = amount

	# Restore loaded file path (will be reloaded after engine connection)
	instance.loaded_file_path = data.get("loaded_file_path", "")
	instance.slot_volume = float(data.get("slot_volume", 0.5))
	instance.slot_mute = bool(data.get("slot_mute", false))
	instance.slot_solo = bool(data.get("slot_solo", false))
	instance.slot_note = int(data.get("slot_note", -1))
	instance.choke_group = clampi(int(data.get("choke_group", 0)), 0, 8)
	instance.slot_note_map = LayerNoteMap.from_json(data.get("slot_note_map", null))
	instance.slot_separate_out = bool(data.get("slot_separate_out", false))
	instance.return_channel_id = int(data.get("return_channel_id", -1))
	var extra_ids = data.get("return_channel_ids", [])
	instance.return_channel_ids.assign(extra_ids)
	var state_b64 := str(data.get("plugin_state", ""))
	if not state_b64.is_empty():
		instance.plugin_state = Marshalls.base64_to_raw(state_b64)
		instance._plugin_state_restore_pending = not instance.plugin_state.is_empty()

	for child_data in data.get("children", []):
		if child_data is Dictionary:
			var child := DeviceInstance.from_json(child_data)
			if child:
				child.set_parent_device(instance)
				instance.children.append(child)
	instance._slots_from_json(data.get("slots", {}))
	instance._wrap_slot_children()

	return instance


## ============================================================================
## DISPLAY HELPERS
## ============================================================================

## Instance name if assigned, otherwise the device type name.
func get_display_name() -> String:
	if not name.is_empty():
		return name
	return device.name if device else "Device"


## Channel/device/child path for the assistant, e.g. `Kick/Chain/Delay 2`.
func address_path(project: Project = null) -> String:
	var ch := get_channel()
	if ch == null and project:
		ch = project.get_channel_by_id(channel_id)
	var parts: PackedStringArray = []
	if ch:
		parts.append(ch.name)
	var names: PackedStringArray = []
	var current: DeviceInstance = self
	while current:
		names.insert(0, current.get_display_name())
		current = current.get_parent_device()
	for n in names:
		parts.append(n)
	return "/".join(parts)
