class_name AutomationTarget extends RefCounted

## What a lane drives on the track's linked channel. Mirrors
## `Engine/src/audio/automation.rs::AutomationTarget` exactly: `to_string()` / `parse()` must
## match the engine's `Display` / `AutomationTarget::parse` spelling byte-for-byte, since the
## string is what travels over OSC and is persisted in the project file.

enum Kind { CHANNEL_VOLUME, CHANNEL_PAN, SEND_AMOUNT, DEVICE_PARAM }

var kind: Kind = Kind.CHANNEL_VOLUME
var send_index: int = -1          # SEND_AMOUNT only
var device_path: Array = []       # DEVICE_PARAM only: indices into channel.devices / .children
var param_id: int = -1            # DEVICE_PARAM only


static func channel_volume() -> AutomationTarget:
	var t := AutomationTarget.new()
	t.kind = Kind.CHANNEL_VOLUME
	return t


static func channel_pan() -> AutomationTarget:
	var t := AutomationTarget.new()
	t.kind = Kind.CHANNEL_PAN
	return t


static func send_amount(index: int) -> AutomationTarget:
	var t := AutomationTarget.new()
	t.kind = Kind.SEND_AMOUNT
	t.send_index = index
	return t


static func device_param(path: Array, p_param_id: int) -> AutomationTarget:
	var t := AutomationTarget.new()
	t.kind = Kind.DEVICE_PARAM
	t.device_path = path.duplicate()
	t.param_id = p_param_id
	return t


## Wire spelling: `channel/volume`, `channel/pan`, `channel/send/{index}`,
## `device/{i0}[/{i1}...]/param/{param_id}`.
func _to_string() -> String:
	match kind:
		Kind.CHANNEL_VOLUME:
			return "channel/volume"
		Kind.CHANNEL_PAN:
			return "channel/pan"
		Kind.SEND_AMOUNT:
			return "channel/send/%d" % send_index
		Kind.DEVICE_PARAM:
			var indices: Array[String] = []
			for i in device_path:
				indices.append(str(i))
			return "device/%s/param/%d" % ["/".join(indices), param_id]
	return ""


## Parse the target string used by OSC, the `.sonara` file and the AI assistant. Returns null on
## anything unparseable, matching `AutomationTarget::parse` on the engine side.
static func parse(s: String) -> AutomationTarget:
	var parts: Array = []
	for part in s.split("/"):
		if part != "":
			parts.append(part)

	if parts.size() == 2 and parts[0] == "channel" and parts[1] == "volume":
		return AutomationTarget.channel_volume()
	if parts.size() == 2 and parts[0] == "channel" and parts[1] == "pan":
		return AutomationTarget.channel_pan()
	if parts.size() == 3 and parts[0] == "channel" and parts[1] == "send":
		if not (parts[2] as String).is_valid_int():
			return null
		return AutomationTarget.send_amount(int(parts[2]))
	if parts.size() >= 1 and parts[0] == "device":
		var rest: Array = parts.slice(1)
		# rest = i0 [i1 ...] "param" param_id
		if rest.size() < 3:
			return null
		var param_pos: int = rest.size() - 2
		if param_pos == 0 or rest[param_pos] != "param":
			return null
		if not (rest[param_pos + 1] as String).is_valid_int():
			return null
		var param_id_val := int(rest[param_pos + 1])
		var indices: Array = []
		for i in range(param_pos):
			var index_str: String = rest[i]
			if not index_str.is_valid_int():
				return null
			indices.append(int(index_str))
		return AutomationTarget.device_param(indices, param_id_val)

	return null


## The `DeviceInstance` this target drives, or null for a channel-level target (volume, pan,
## send). Returns null when the path no longer resolves (a removed device) - REQ-024.
func resolve(channel: Object) -> Object:
	if kind != Kind.DEVICE_PARAM or channel == null:
		return null
	var host: Array = channel.devices
	var instance: Object = null
	for i in device_path:
		if i < 0 or i >= host.size():
			return null
		instance = host[i]
		host = instance.children
	return instance


## True when this target can currently be resolved against `channel` (REQ-024).
func is_resolvable(channel: Object) -> bool:
	if channel == null:
		return false
	match kind:
		Kind.CHANNEL_VOLUME, Kind.CHANNEL_PAN:
			return true
		Kind.SEND_AMOUNT:
			return send_index >= 0 and send_index < channel.send_channels.size()
		Kind.DEVICE_PARAM:
			var instance := resolve(channel)
			return instance != null and instance.get_parameter(param_id) != null
	return false


## Human-readable label, e.g. `Filter / Freq` or `Piano / CC1 Mod Wheel` (REQ-017).
func display_name(channel: Object) -> String:
	match kind:
		Kind.CHANNEL_VOLUME:
			return "Volume"
		Kind.CHANNEL_PAN:
			return "Pan"
		Kind.SEND_AMOUNT:
			if channel != null and send_index >= 0 and send_index < channel.send_channels.size():
				var target_id: int = channel.send_channels[send_index].target_channel_id
				return "Send %d" % target_id
			return "Send %d" % send_index
		Kind.DEVICE_PARAM:
			var instance := resolve(channel)
			if instance == null:
				return "Unresolved"
			var param: Object = instance.get_parameter(param_id)
			var param_name: String = param.name if param else "Param %d" % param_id
			if param and param.group == "cc":
				param_name = Midi.cc_display_name(param_id, param_name)
			return "%s / %s" % [instance.name, param_name]
	return "Unknown"


# ============================================================================
# NORMALIZATION
# ============================================================================
# Duplicated from `Engine/src/audio/automation.rs` (VOLUME_DB_MIN/MAX and the four helpers) and
# locked by the curve-parity test. Both sides must change together.

const VOLUME_DB_MIN: float = -60.0
const VOLUME_DB_MAX: float = 12.0


static func normalized_to_db(normalized: float) -> float:
	return VOLUME_DB_MIN + clampf(normalized, 0.0, 1.0) * (VOLUME_DB_MAX - VOLUME_DB_MIN)


static func db_to_normalized(db: float) -> float:
	return clampf((db - VOLUME_DB_MIN) / (VOLUME_DB_MAX - VOLUME_DB_MIN), 0.0, 1.0)


static func normalized_to_pan(normalized: float) -> float:
	return clampf(normalized, 0.0, 1.0) * 2.0 - 1.0


static func pan_to_normalized(pan: float) -> float:
	return (clampf(pan, -1.0, 1.0) + 1.0) * 0.5


## The target's current *base* value on `channel`, normalized 0.0..1.0. Used to seed a new lane's
## first point so creating a lane doesn't jump the parameter. Returns 0.5 when unresolvable.
func current_normalized_value(channel: Object) -> float:
	match kind:
		Kind.CHANNEL_VOLUME:
			return db_to_normalized(channel.volume) if channel else 0.5
		Kind.CHANNEL_PAN:
			return pan_to_normalized(channel.pan) if channel else 0.5
		Kind.SEND_AMOUNT:
			if channel and send_index >= 0 and send_index < channel.send_channels.size():
				return db_to_normalized(channel.send_channels[send_index].amount)
			return 0.5
		Kind.DEVICE_PARAM:
			var instance := resolve(channel)
			if instance:
				return clampf(instance.get_parameter_normalized(param_id), 0.0, 1.0)
			return 0.5
	return 0.5


## Format a normalized value the way the target's own control would, e.g. `-6.0 dB`, `L20`,
## or the device parameter's own formatting. Used by the lane row's value readout.
func format_value(channel: Object, normalized: float) -> String:
	match kind:
		Kind.CHANNEL_VOLUME, Kind.SEND_AMOUNT:
			return "%.1f dB" % normalized_to_db(normalized)
		Kind.CHANNEL_PAN:
			var p := normalized_to_pan(normalized)
			if absf(p) < 0.005:
				return "C"
			return ("R%d" if p > 0.0 else "L%d") % int(round(absf(p) * 100.0))
		Kind.DEVICE_PARAM:
			var instance := resolve(channel)
			if instance:
				var param: Object = instance.get_parameter(param_id)
				if param:
					return param.format_value(param.normalized_to_value(normalized))
			return "%.3f" % normalized
	return "%.3f" % normalized
