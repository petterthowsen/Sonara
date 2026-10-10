class_name AutomationTarget extends RefCounted

## What a lane drives on the track's linked channel. Mirrors
## `Engine/src/audio/automation.rs::AutomationTarget` exactly: `to_string()` / `parse()` must
## match the engine's `Display` / `AutomationTarget::parse` spelling byte-for-byte, since the
## string is what travels over OSC and is persisted in the project file.

enum Kind { CHANNEL_VOLUME, CHANNEL_PAN, SEND_AMOUNT, DEVICE_PARAM, DEVICE_MODULATOR_PARAM, MIDI_CC }

var kind: Kind = Kind.CHANNEL_VOLUME
var send_index: int = -1          # SEND_AMOUNT only
var cc: int = -1                  # MIDI_CC only: controller number 0..=119
var device_path: Array = []       # DEVICE_PARAM / DEVICE_MODULATOR_PARAM: indices into channel.devices / .children
var param_id: int = -1            # DEVICE_PARAM / DEVICE_MODULATOR_PARAM only
var mod_id: int = -1              # DEVICE_MODULATOR_PARAM only


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


## Controller `cc` (0..=119) on the track's linked channel (spec 030). Not tied to one device:
## the lane drives the whole chain, and live input on the same controller is suppressed while
## the lane is active.
static func midi_cc(cc: int) -> AutomationTarget:
	var t := AutomationTarget.new()
	t.kind = Kind.MIDI_CC
	t.cc = clampi(cc, 0, Midi.CC_LANE_MAX)
	return t


static func device_param(path: Array, p_param_id: int) -> AutomationTarget:
	var t := AutomationTarget.new()
	t.kind = Kind.DEVICE_PARAM
	t.device_path = path.duplicate()
	t.param_id = p_param_id
	return t


## A parameter of a modulator on the device at `path` (spec 018).
static func device_modulator_param(path: Array, p_mod_id: int, p_param_id: int) -> AutomationTarget:
	var t := AutomationTarget.new()
	t.kind = Kind.DEVICE_MODULATOR_PARAM
	t.device_path = path.duplicate()
	t.mod_id = p_mod_id
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
			return "device/%s/param/%d" % [_path_string(), param_id]
		Kind.DEVICE_MODULATOR_PARAM:
			return "device/%s/mod/%d/param/%d" % [_path_string(), mod_id, param_id]
		Kind.MIDI_CC:
			return "channel/cc/%d" % cc
	return ""


## `i0/i1/...` for the device path, as the wire spelling writes it.
func _path_string() -> String:
	var indices: Array[String] = []
	for i in device_path:
		indices.append(str(i))
	return "/".join(indices)


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
	if parts.size() == 3 and parts[0] == "channel" and parts[1] == "cc":
		# 0..=119: 120-127 are channel-mode messages, not controllers (REQ-002).
		if not (parts[2] as String).is_valid_int():
			return null
		var cc_value := int(parts[2])
		if cc_value < 0 or cc_value > Midi.CC_LANE_MAX:
			return null
		return AutomationTarget.midi_cc(cc_value)
	if parts.size() == 3 and parts[0] == "channel" and parts[1] == "send":
		if not (parts[2] as String).is_valid_int():
			return null
		return AutomationTarget.send_amount(int(parts[2]))
	if parts.size() >= 1 and parts[0] == "device":
		var rest: Array = parts.slice(1)
		# rest = i0 [i1 ...] "param" param_id
		#     or i0 [i1 ...] "mod" mod_id "param" param_id
		if rest.size() < 3:
			return null
		var param_pos: int = rest.size() - 2
		if param_pos == 0 or rest[param_pos] != "param":
			return null
		if not (rest[param_pos + 1] as String).is_valid_int():
			return null
		var param_id_val := int(rest[param_pos + 1])
		var head: Array = rest.slice(0, param_pos)
		var mod_id_val := -1
		if head.size() >= 2 and head[head.size() - 2] == "mod":
			if not (head[head.size() - 1] as String).is_valid_int():
				return null
			mod_id_val = int(head[head.size() - 1])
			head = head.slice(0, head.size() - 2)
		if head.is_empty():
			return null
		var indices: Array = []
		for index_str in head:
			if not (index_str as String).is_valid_int():
				return null
			indices.append(int(index_str))
		if mod_id_val >= 0:
			return AutomationTarget.device_modulator_param(indices, mod_id_val, param_id_val)
		return AutomationTarget.device_param(indices, param_id_val)

	return null


## The `DeviceInstance` this target drives, or null for a channel-level target (volume, pan,
## send). Returns null when the path no longer resolves (a removed device) - REQ-024.
func resolve(channel: Object) -> Object:
	if (kind != Kind.DEVICE_PARAM and kind != Kind.DEVICE_MODULATOR_PARAM) or channel == null:
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
		Kind.CHANNEL_VOLUME, Kind.CHANNEL_PAN, Kind.MIDI_CC:
			return true
		Kind.SEND_AMOUNT:
			return send_index >= 0 and send_index < channel.send_channels.size()
		Kind.DEVICE_PARAM:
			var instance := resolve(channel)
			return instance != null and instance.get_parameter(param_id) != null
		Kind.DEVICE_MODULATOR_PARAM:
			var instance := resolve(channel)
			var modulator = instance.get_modulator(mod_id) if instance != null else null
			return modulator != null and modulator.get_parameter(param_id) != null
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
				var project: Object = channel.get_project()
				var target_channel: Object = project.get_channel_by_id(target_id) if project else null
				if target_channel != null:
					return "Send: %s" % target_channel.name
				return "Send %d" % target_id
			return "Send %d" % send_index
		Kind.DEVICE_PARAM:
			var instance := resolve(channel)
			if instance == null:
				return "Unresolved"
			var param: Object = instance.get_parameter(param_id)
			var param_name: String = param_label(instance, param) if param else "Param %d" % param_id
			return "%s / %s" % [instance.name, param_name]
		Kind.DEVICE_MODULATOR_PARAM:
			var instance := resolve(channel)
			if instance == null:
				return "Unresolved"
			var modulator = instance.get_modulator(mod_id)
			if modulator == null:
				return "Unresolved"
			var param: Object = modulator.get_parameter(param_id)
			var param_name: String = param.name if param else "Param %d" % param_id
			return "%s / %s / %s" % [instance.name, modulator.name, param_name]
		Kind.MIDI_CC:
			return cc_label(channel, cc)
	return "Unknown"


## Label for controller `cc`: the SFZ-supplied name (the instrument's label wins, REQ-017) via
## `Midi.cc_display_name`, so an unlabelled controller falls back to `CC3 CC3`-style naming.
func cc_label(channel: Object, cc_number: int) -> String:
	var supplied := ""
	if channel != null:
		for instance in _devices_recursive(channel.devices):
			for param in instance.get_parameters():
				if param.id == cc_number and instance.is_controller_parameter(param) and param.name != "":
					supplied = param.name
					break
			if supplied != "":
				break
	return Midi.cc_display_name(cc_number, supplied)


## Depth-first walk of a device chain, containers included.
static func _devices_recursive(devices: Array) -> Array:
	var out: Array = []
	for instance in devices:
		if instance == null:
			continue
		out.append(instance)
		out.append_array(_devices_recursive(instance.children))
	return out


## Menu/lane label for `param` on `instance`. CC entries go through `Midi.cc_display_name`. A
## name shared by several parameters in the same group (the EQ's per-band `Gain`, a CLAP
## plugin's per-section `Level`) is prefixed with its module (`Band 2 / Gain`); a unique name
## stays bare.
static func param_label(instance: Object, param: Object) -> String:
	if param.group == "cc":
		return Midi.cc_display_name(param.id, param.name)
	if param.module != "":
		for other in instance.get_parameters_in_group(param.group if param.group != "" else "param"):
			if other != param and other.name == param.name:
				return "%s / %s" % [param.module, param.name]
	return param.name


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
		Kind.DEVICE_MODULATOR_PARAM:
			var instance := resolve(channel)
			var modulator = instance.get_modulator(mod_id) if instance != null else null
			if modulator:
				return clampf(modulator.get_parameter_normalized(param_id), 0.0, 1.0)
			return 0.5
		Kind.MIDI_CC:
			# Seed from the device's own controller value (an SFZ knob) so creating a lane
			# doesn't jump the controller; 0.5 when nothing reports one.
			if channel != null:
				for instance in _devices_recursive(channel.devices):
					for param in instance.get_parameters():
						if param.id == cc and instance.is_controller_parameter(param):
							return clampf(instance.get_parameter_normalized(param.id), 0.0, 1.0)
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
		Kind.DEVICE_MODULATOR_PARAM:
			var instance := resolve(channel)
			var modulator = instance.get_modulator(mod_id) if instance != null else null
			if modulator:
				var param: Object = modulator.get_parameter(param_id)
				if param:
					return param.format_value(param.normalized_to_value(normalized))
			return "%.3f" % normalized
	return "%.3f" % normalized


## Text for typing `normalized` into the value editor: the real number without unit decoration
## (dB, pan as -100..100 percent, or the device parameter's own edit text).
func edit_text(channel: Object, normalized: float) -> String:
	match kind:
		Kind.CHANNEL_VOLUME, Kind.SEND_AMOUNT:
			return "%.1f" % normalized_to_db(normalized)
		Kind.CHANNEL_PAN:
			return "%d" % int(round(normalized_to_pan(normalized) * 100.0))
	var param := _edit_param(channel)
	if param:
		return param.edit_text(param.normalized_to_value(normalized))
	return "%.3f" % normalized


## Parse text typed by the user into a normalized 0..1 value, or NAN when it isn't a value.
## Volume and sends take dB, pan takes -100..100 (also `L20`, `R30`, `C`), a device parameter its
## own units, and an unresolved target the normalized number itself.
func parse_edit_text(channel: Object, text: String) -> float:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return NAN
	match kind:
		Kind.CHANNEL_VOLUME, Kind.SEND_AMOUNT:
			if trimmed.to_lower().ends_with("db"):
				trimmed = trimmed.substr(0, trimmed.length() - 2).strip_edges()
			return db_to_normalized(trimmed.to_float()) if trimmed.is_valid_float() else NAN
		Kind.CHANNEL_PAN:
			var upper := trimmed.to_upper()
			if upper == "C":
				return 0.5
			var sign := 1.0
			if upper.begins_with("L") or upper.begins_with("R"):
				sign = -1.0 if upper.begins_with("L") else 1.0
				trimmed = trimmed.substr(1).strip_edges()
			if not trimmed.is_valid_float():
				return NAN
			return pan_to_normalized(sign * trimmed.to_float() / 100.0)
	var param := _edit_param(channel)
	if param:
		var real: float = param.parse_edit_text(trimmed)
		return NAN if is_nan(real) else clampf(param.value_to_normalized(real), 0.0, 1.0)
	return clampf(trimmed.to_float(), 0.0, 1.0) if trimmed.is_valid_float() else NAN


func _edit_param(channel: Object) -> Object:
	match kind:
		Kind.DEVICE_PARAM:
			var instance := resolve(channel)
			return instance.get_parameter(param_id) if instance else null
		Kind.DEVICE_MODULATOR_PARAM:
			var instance := resolve(channel)
			var modulator = instance.get_modulator(mod_id) if instance != null else null
			return modulator.get_parameter(param_id) if modulator else null
	return null
