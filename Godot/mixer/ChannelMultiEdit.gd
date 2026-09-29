# ChannelMultiEdit.gd
# Applies one mixer edit (volume, pan, send level) to every selected channel. A drag moves the
# others by the same amount (relative); typing a value sets them all to it; Ctrl/Cmd-click resets
# each to its own default. Every gesture is one undo step. Setters stay on Channel, which syncs
# to the engine; nothing here sends OSC.
class_name ChannelMultiEdit extends RefCounted

const MIN_DB := -60.0
const MAX_DB := 12.0


## The selected channels other than `channel`, when `channel` is part of a multi-selection.
static func peers_of(channel: Channel, from_node: Node) -> Array[Channel]:
	var mixer := Mixer.of(from_node)
	return mixer.get_multi_edit_peers(channel) if mixer and channel else ([] as Array[Channel])


# -- Volume ---------------------------------------------------------------------------------

## `primary` already holds its new volume (from `old_volume`). Bring `peers` along and record it all.
static func apply_volume(primary: Channel, old_volume: float, peers: Array[Channel], kind: ValueEditKind.Kind) -> void:
	var old_values := {primary: old_volume}
	var new_values := {primary: primary.volume}
	var delta := primary.volume - old_volume
	for peer in peers:
		old_values[peer] = peer.volume
		match kind:
			ValueEditKind.Kind.DRAG:
				new_values[peer] = clampf(peer.volume + delta, MIN_DB, MAX_DB)
			ValueEditKind.Kind.TYPED:
				new_values[peer] = primary.volume
			ValueEditKind.Kind.RESET:
				new_values[peer] = peer.get_default_volume()
	_commit("Set Volume", primary, old_values, new_values, _set_volume, "volume" if kind == ValueEditKind.Kind.DRAG else "")


static func _set_volume(ch: Channel, value: float) -> void:
	ch.set_volume(value)


# -- Pan ------------------------------------------------------------------------------------

## `primary` already holds `new_state` (from `old_state`). Bring `peers` along and record it all.
static func apply_pan(primary: Channel, old_state: Dictionary, new_state: Dictionary, peers: Array[Channel], kind: ValueEditKind.Kind) -> void:
	var old_states := {primary: old_state}
	var new_states := {primary: new_state}
	for peer in peers:
		var peer_state: Dictionary = peer.get_pan_state()
		old_states[peer] = peer_state
		new_states[peer] = _reset_pan_position(peer_state) if kind == ValueEditKind.Kind.RESET else _shift_pan_state(peer_state, old_state, new_state)
	_commit("Set Pan", primary, old_states, new_states, _set_pan_state, "pan" if kind == ValueEditKind.Kind.DRAG else "")


static func _set_pan_state(ch: Channel, state: Dictionary) -> void:
	ch.set_pan_state(state)


## `state` moved by the change from `from` to `to`. Same mode: every field moves by its own
## difference. Other modes: only the position moves (the midpoint of the handles in Dual).
static func _shift_pan_state(state: Dictionary, from: Dictionary, to: Dictionary) -> Dictionary:
	var out := state.duplicate()
	if state.get("mode") == from.get("mode"):
		for key in ["pan", "width", "left", "right"]:
			out[key] = _clamp_pan(state[key] + to[key] - from[key])
		return out
	var shift := _position_shift(from, to)
	if state.get("mode") == Channel.PanMode.STEREO_DUAL:
		out["left"] = _clamp_pan(state["left"] + shift)
		out["right"] = _clamp_pan(state["right"] + shift)
	else:
		out["pan"] = _clamp_pan(state["pan"] + shift)
	return out


static func _position_shift(from: Dictionary, to: Dictionary) -> float:
	if from.get("mode") == Channel.PanMode.STEREO_DUAL:
		return (to["left"] - from["left"] + to["right"] - from["right"]) / 2.0
	return to["pan"] - from["pan"]


## Centered, keeping the mode and the width between the Dual handles or the Combined width.
static func _reset_pan_position(state: Dictionary) -> Dictionary:
	var out := state.duplicate()
	out["pan"] = 0.0
	var middle: float = (state["left"] + state["right"]) / 2.0
	out["left"] = _clamp_pan(state["left"] - middle)
	out["right"] = _clamp_pan(state["right"] - middle)
	return out


static func _clamp_pan(value: float) -> float:
	return clampf(value, -1.0, 1.0)


# -- Sends ----------------------------------------------------------------------------------

## `primary`'s send to `bus_id` already holds `new_db` (from `old_db`; MIN_SEND_DB when it had no
## send). Bring the peers' sends to the same bus along and record it all.
static func apply_send(primary: Channel, bus_id: int, old_db: float, new_db: float, peers: Array[Channel], kind: ValueEditKind.Kind) -> void:
	var old_values := {primary: old_db}
	var new_values := {primary: new_db}
	for peer in peers:
		if peer.id == bus_id:
			continue
		var peer_db := send_db(peer, bus_id)
		old_values[peer] = peer_db
		match kind:
			ValueEditKind.Kind.DRAG:
				new_values[peer] = clampf(peer_db + new_db - old_db, MIN_DB, MAX_DB)
			ValueEditKind.Kind.TYPED:
				new_values[peer] = new_db
			ValueEditKind.Kind.RESET:
				new_values[peer] = MIN_DB
	_commit("Set Send", primary, old_values, new_values, _set_send.bind(bus_id), "send:%d" % bus_id if kind == ValueEditKind.Kind.DRAG else "")


## Send level of `channel` to `bus_id`; the bottom of the range (silence) when it has none.
static func send_db(channel: Channel, bus_id: int) -> float:
	var config := channel.get_send(bus_id)
	return config.amount if config else MIN_DB


static func _set_send(ch: Channel, db: float, bus_id: int) -> void:
	if ch.get_send(bus_id):
		ch.set_send_amount(bus_id, db)
	else:
		ch.add_send(bus_id, db, false)


# -- Shared ---------------------------------------------------------------------------------

## Apply the peers' values (the primary's is applied already) and record the whole gesture.
static func _commit(label: String, primary: Channel, old_values: Dictionary, new_values: Dictionary, apply: Callable, merge_key: String) -> void:
	var changed := false
	for ch in new_values:
		if old_values[ch] == new_values[ch]:
			continue
		changed = true
		if ch != primary:
			apply.call(ch, new_values[ch])
	if changed:
		HistoryUtil.record(ChannelsPropertyCommand.new(label, old_values, new_values, apply, merge_key))
