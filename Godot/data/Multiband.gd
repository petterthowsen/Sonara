## Multiband FX (`sonara.builtin.multiband`): six fixed band positions, any 2–6 active (spec 016).
## Child *i* is the slot chain of band position *i + 1*. Every band has the same parameter block
## (`10 * position + offset`), so automation survives other bands being toggled. A band owns its
## **low edge**: the crossovers are the low edges of every active band except the lowest.
## This class holds the id scheme, band names, the edge placement for enabling a band (D7) and the
## undoable toggle command (D8). It stays off the Layer slot paths: per-band gain, mute and solo are
## device parameters, never `/slot/*` OSC.
class_name Multiband extends RefCounted

const DEVICE_ID := "sonara.builtin.multiband"
const BAND_COUNT := 6
const MIN_ACTIVE := 2

const ID_MIX := 0
const ID_OUTPUT := 1
const OFFSET_ACTIVE := 0
const OFFSET_EDGE := 1
const OFFSET_GAIN := 2
const OFFSET_MUTE := 3
const OFFSET_SOLO := 4

## Crossover range (Hz) and the smallest ratio between neighbouring active crossovers (D6).
const FREQ_MIN := 20.0
const FREQ_MAX := 20000.0
const MIN_RATIO := 1.1

## Display names by number of active bands, low to high (index = count - 2).
const NAMES := [
	["Low", "High"],
	["Low", "Mid", "High"],
	["Low", "Low Mid", "High Mid", "High"],
	["Sub", "Low", "Mid", "High Mid", "High"],
	["Sub", "Low", "Low Mid", "Mid", "High Mid", "Air"],
]


## Default slot color of band `position`: warm for low bands, cool for high ones.
static func band_color(position: int) -> Color:
	var hues := [0.02, 0.09, 0.16, 0.38, 0.55, 0.75]
	return Color.from_hsv(hues[clampi(position, 1, BAND_COUNT) - 1], 0.6, 0.78)


static func is_multiband(inst: DeviceInstance) -> bool:
	return inst != null and inst.device != null and inst.device.device_id == DEVICE_ID


## True for the slot chain of a band (a child of a Multiband FX).
static func is_band_chain(inst: DeviceInstance) -> bool:
	return inst != null and is_multiband(inst.get_parent_device())


static func param_id(position: int, offset: int) -> int:
	return 10 * position + offset


## 1-based band position of `chain` inside `mb`, or 0.
static func position_of(mb: DeviceInstance, chain: DeviceInstance) -> int:
	return mb.children.find(chain) + 1


## Create the missing empty slot chains so the device has exactly six (D9). No-op for others.
static func ensure_chains(mb: DeviceInstance) -> void:
	if not is_multiband(mb):
		return
	while mb.children.size() < BAND_COUNT:
		var chain := SlotChain.empty(mb.channel_id, "Band %d" % (mb.children.size() + 1))
		if chain == null:
			return
		chain.position = mb.children.size()
		chain.set_parent_device(mb)
		mb.children.append(chain)
	refresh_names(mb)


## The band chain a device dropped *onto* the Multiband FX goes into: the open band, else the
## lowest active one.
static func target_chain(mb: DeviceInstance) -> DeviceInstance:
	for key in mb.open_slot_keys():
		var open := mb.slot_chain(key)
		if open != null and is_active(mb, position_of(mb, open)):
			return open
	var active := active_positions(mb)
	if active.is_empty() or active[0] > mb.children.size():
		return null
	return mb.children[active[0] - 1]


# --- Parameter access (normalized values, real values computed here) --------------------------

static func _norm(mb: DeviceInstance, id: int, fallback: float) -> float:
	return float(mb.parameter_values.get(id, fallback))


static func is_active(mb: DeviceInstance, position: int) -> bool:
	if position < 1 or position > BAND_COUNT:
		return false
	return _norm(mb, param_id(position, OFFSET_ACTIVE), 1.0 if position in [1, 3, 5] else 0.0) >= 0.5


## Active band positions, ascending.
static func active_positions(mb: DeviceInstance) -> Array[int]:
	var out: Array[int] = []
	for p in range(1, BAND_COUNT + 1):
		if is_active(mb, p):
			out.append(p)
	return out


static func freq_to_norm(hz: float) -> float:
	return clampf(log(hz / FREQ_MIN) / log(FREQ_MAX / FREQ_MIN), 0.0, 1.0)


static func norm_to_freq(n: float) -> float:
	return FREQ_MIN * pow(FREQ_MAX / FREQ_MIN, clampf(n, 0.0, 1.0))


## Stored `Low Edge` of band `position` (2..6) in Hz.
static func edge_hz(mb: DeviceInstance, position: int) -> float:
	var defaults := {2: 60.0, 3: 200.0, 4: 700.0, 5: 2500.0, 6: 8000.0}
	return norm_to_freq(_norm(mb, param_id(position, OFFSET_EDGE), freq_to_norm(defaults.get(position, 1000.0))))


## Display names of the six positions: the auto name for active bands (by rank among them) and
## "Band n" for inactive ones.
static func auto_names(mb: DeviceInstance) -> PackedStringArray:
	var out := PackedStringArray()
	var active := active_positions(mb)
	var table: Array = NAMES[clampi(active.size(), MIN_ACTIVE, BAND_COUNT) - MIN_ACTIVE]
	for p in range(1, BAND_COUNT + 1):
		var rank := active.find(p)
		out.append(table[rank] if rank >= 0 and rank < table.size() else "Band %d" % p)
	return out


static func _is_auto_name(chain_name: String) -> bool:
	if chain_name.is_empty() or chain_name.begins_with("Band "):
		return true
	for names in NAMES:
		if chain_name in names:
			return true
	return false


## Rename the band chains after the active set. A chain the user renamed keeps its name.
static func refresh_names(mb: DeviceInstance) -> void:
	var names := auto_names(mb)
	for i in mini(mb.children.size(), BAND_COUNT):
		var chain := mb.children[i]
		if chain.name == names[i] or not _is_auto_name(chain.name):
			continue
		chain.name = names[i]
		chain.name_changed.emit(chain.name)
	mb.slots_changed.emit()  # the active set may have changed: views and the lane re-read the slots


# --- Band toggling ------------------------------------------------------------------------------


## Number of devices inside band `position`'s chain (what disabling it would remove).
static func device_count(mb: DeviceInstance, position: int) -> int:
	if position < 1 or position > mb.children.size():
		return 0
	return mb.children[position - 1].children.size()


## True when band `position` may be switched off: it is active and more than 2 remain.
static func can_disable(mb: DeviceInstance, position: int) -> bool:
	return is_active(mb, position) and active_positions(mb).size() > MIN_ACTIVE


## Edges (position -> Hz) to write when enabling band `position` (D7). Empty when it needs none.
static func edges_for_enable(mb: DeviceInstance, position: int) -> Dictionary:
	var active := active_positions(mb)
	if active.size() < 1 or position in active:
		return {}
	var edge_owner: int  # band whose Low Edge becomes the new crossover
	var lo: float
	var hi: float
	if position < active[0]:
		# The new band becomes the lowest; the old lowest band's edge splits its old range.
		edge_owner = active[0]
		lo = FREQ_MIN
		hi = edge_hz(mb, active[1]) if active.size() > 1 else FREQ_MAX
	else:
		edge_owner = position
		var below := active[0]
		var below_idx := 0
		for i in active.size():
			if active[i] < position:
				below = active[i]
				below_idx = i
		lo = FREQ_MIN if below_idx == 0 else edge_hz(mb, below)
		hi = edge_hz(mb, active[below_idx + 1]) if below_idx + 1 < active.size() else FREQ_MAX
	var stored := edge_hz(mb, edge_owner)
	if stored > lo * MIN_RATIO and stored < hi / MIN_RATIO:
		return {}
	return {edge_owner: sqrt(lo * hi)}


## One undoable command that enables or disables band `position`, or null when it isn't allowed.
## Disabling removes the band's devices (undo brings them back); enabling places its edge.
static func toggle_command(mb: DeviceInstance, position: int, on: bool) -> Command:
	if not is_multiband(mb) or position < 1 or position > BAND_COUNT or is_active(mb, position) == on:
		return null
	if not on and not can_disable(mb, position):
		return null
	var label := "%s Band %d" % ["Enable" if on else "Disable", position]
	var refresh := PropertyCommand.new(label, null).set_callable(func(_v): refresh_names(mb))
	var cmds: Array[Command] = [refresh]
	if not on and position <= mb.children.size():
		var chain := mb.children[position - 1]
		var channel := mb.get_channel()
		if channel != null:
			for i in range(chain.children.size() - 1, -1, -1):
				cmds.append(DeviceRemoveCommand.new(channel, chain.children[i], i, chain))
	if on:
		var edges := edges_for_enable(mb, position)
		for owner in edges:
			cmds.append(_param_command(label, mb, param_id(owner, OFFSET_EDGE), freq_to_norm(edges[owner])))
	cmds.append(_param_command(label, mb, param_id(position, OFFSET_ACTIVE), 1.0 if on else 0.0))
	cmds.append(refresh)
	return MacroCommand.new(label, cmds)


static func _param_command(label: String, mb: DeviceInstance, id: int, value: float) -> PropertyCommand:
	var old: float = mb.get_parameter_normalized(id)
	var cmd := PropertyCommand.new(label, null, "", old, value)
	return cmd.set_callable(func(v): mb.set_parameter_normalized(id, v))


## Undoable command that empties band `position`'s chain, or null when it is already empty.
static func clear_band_command(mb: DeviceInstance, position: int) -> Command:
	var channel := mb.get_channel()
	if channel == null or position < 1 or position > mb.children.size():
		return null
	var chain := mb.children[position - 1]
	var cmds: Array[Command] = []
	for i in range(chain.children.size() - 1, -1, -1):
		cmds.append(DeviceRemoveCommand.new(channel, chain.children[i], i, chain))
	return MacroCommand.new("Clear Band", cmds) if not cmds.is_empty() else null
