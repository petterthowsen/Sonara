## SamplerActions.gd
## Undoable Sampler multisample edits (spec 023): file drops, mode conversion, batch operations,
## deletion and group changes. Each public function is exactly one history step. They apply the
## change through the model (which sends the OSC), then record a `SamplerStateCommand` holding the
## state before and after, so undo and redo go through `SamplerMultisample.restore()` and send
## only what differs.
class_name SamplerActions extends RefCounted

## The per-zone device parameters (REQ-017). Conversions copy them to and from a zone.
const ZONE_PARAMS := [
	"Root", "Tune", "Fine", "Start", "End", "Reverse", "Loop Mode", "Loop Start", "Loop End", "Crossfade",
]


## Undo state of a Sampler: the multisample snapshot, the single-mode file and the per-zone
## parameters (conversions rewrite them).
class SamplerStateCommand extends Command:
	var inst: DeviceInstance
	var old_state: Dictionary
	var new_state: Dictionary

	func _init(label: String, p_inst: DeviceInstance, p_old: Dictionary, p_new: Dictionary) -> void:
		name = label
		inst = p_inst
		old_state = p_old
		new_state = p_new

	func do() -> void:
		SamplerActions.apply_state(inst, new_state)

	func undo() -> void:
		SamplerActions.apply_state(inst, old_state)


# --- state capture ---------------------------------------------------------

static func capture_state(inst: DeviceInstance) -> Dictionary:
	var params := {}
	for param_name in ZONE_PARAMS:
		var id := inst.get_parameter_id_by_name(param_name)
		if id >= 0:
			params[id] = inst.get_parameter_normalized(id)
	return {
		# An inactive multisample is {} whatever its id counters say, so single-mode states compare equal.
		"ms": inst.multisample.snapshot() if inst.multisample != null and inst.multisample.active else {},
		"file": inst.loaded_file_path,
		"params": params,
	}


## Make `inst` match `state`. Used by undo and redo.
static func apply_state(inst: DeviceInstance, state: Dictionary) -> void:
	var params: Dictionary = state.get("params", {})
	for id in params:
		if not is_equal_approx(inst.get_parameter_normalized(int(id)), float(params[id])):
			inst.set_parameter_normalized(int(id), float(params[id]))
	var ms_state: Dictionary = state.get("ms", {})
	if inst.multisample != null or not ms_state.is_empty():
		inst.ensure_multisample().restore(ms_state)
	var file: String = state.get("file", "")
	if file != inst.loaded_file_path:
		if file.is_empty() or inst.multisample.active:
			inst.loaded_file_path = file
		else:
			inst.load_file(file)


static func _record(inst: DeviceInstance, label: String, old_state: Dictionary) -> void:
	var new_state := capture_state(inst)
	if new_state == old_state:
		return
	HistoryUtil.record(SamplerStateCommand.new(label, inst, old_state, new_state))


## Run `change` on the model as one undo step. The generic form behind the helpers below.
static func edit(inst: DeviceInstance, label: String, change: Callable) -> void:
	var old_state := capture_state(inst)
	change.call(inst.ensure_multisample())
	_record(inst, label, old_state)


# --- drops and conversion --------------------------------------------------

## Files dropped on a Sampler (REQ-011, REQ-012, REQ-015). `at_key` places new zones from that key.
## - Multisample mode: one zone per file is added.
## - Single mode, one file: replaces the sample.
## - Single mode, two or more: switches to multisample mode with one zone per file, and keeps a
##   sample the Sampler already holds as a zone too, laid out together with the new ones.
static func drop_files(inst: DeviceInstance, paths: Array, at_key: int = -1) -> void:
	if inst == null or paths.is_empty():
		return
	var model := inst.ensure_multisample()
	var old_state := capture_state(inst)
	if model.active:
		model.add_files(paths, at_key)
	elif paths.size() == 1:
		inst.load_file(str(paths[0]))
	else:
		var new_zones: Array[SamplerZone] = []
		var roots: Array = []
		if not inst.loaded_file_path.is_empty():
			new_zones.append(zone_from_params(inst))
			roots.append(new_zones[0].root)
		for path in paths:
			new_zones.append(SamplerZone.new(0, str(path)))
			roots.append(ZoneLayout.parse_root(str(path).get_file()))
		model.place_zones(new_zones, roots, at_key)
		inst.loaded_file_path = ""
	_record(inst, "Add Samples" if model.active else "Load Sample", old_state)


## "Convert to Multisample" (REQ-013) and the empty Sampler's "Create Multisample" (REQ-010): the
## current sample becomes one zone over all keys and velocities, with its settings copied from the
## parameters. Without a sample the multisample starts empty.
static func convert_to_multisample(inst: DeviceInstance) -> void:
	var model := inst.ensure_multisample()
	if model.active:
		return
	var old_state := capture_state(inst)
	if inst.loaded_file_path.is_empty():
		model.set_active(true)
	else:
		var zone := zone_from_params(inst)
		model.place_zones([zone] as Array[SamplerZone], [zone.root])
		inst.loaded_file_path = ""
	_record(inst, "Convert to Multisample", old_state)


## "Convert to Single Sample" (REQ-014): keeps only the focused zone, copies its settings into the
## parameters and leaves multisample mode.
static func convert_to_single(inst: DeviceInstance) -> void:
	var model := inst.multisample
	if model == null or not model.active:
		return
	var old_state := capture_state(inst)
	var zone := model.focused_zone()
	if zone == null and not model.zones.is_empty():
		zone = model.zones[0]
	var keep := zone.to_json() if zone else {}
	model.set_active(false)
	if not keep.is_empty():
		write_params(inst, SamplerZone.from_json(keep))
		inst.load_file(str(keep["path"]))
	_record(inst, "Convert to Single Sample", old_state)


## A zone for the Sampler's current single-mode sample, over all keys and velocities, with its
## per-zone settings read from the parameters (no id yet; the model assigns it).
static func zone_from_params(inst: DeviceInstance) -> SamplerZone:
	var zone := SamplerZone.new(0, inst.loaded_file_path)
	zone.apply_fields({
		"root": int(round(inst.get_parameter_real_by_name("Root"))),
		"tune": inst.get_parameter_real_by_name("Tune"),
		"fine": inst.get_parameter_real_by_name("Fine"),
		"start": inst.get_parameter_real_by_name("Start"),
		"end": inst.get_parameter_real_by_name("End"),
		"reverse": inst.get_parameter_real_by_name("Reverse") >= 0.5,
		"loop_mode": int(round(inst.get_parameter_real_by_name("Loop Mode"))),
		"loop_start": inst.get_parameter_real_by_name("Loop Start"),
		"loop_end": inst.get_parameter_real_by_name("Loop End"),
		"crossfade": inst.get_parameter_real_by_name("Crossfade") / 100.0,
	})
	return zone


## Write a zone's per-zone settings into the matching device parameters.
static func write_params(inst: DeviceInstance, zone: SamplerZone) -> void:
	inst.set_parameter_real_by_name("Root", zone.root)
	inst.set_parameter_real_by_name("Tune", zone.tune)
	inst.set_parameter_real_by_name("Fine", zone.fine)
	inst.set_parameter_real_by_name("Start", zone.start)
	inst.set_parameter_real_by_name("End", zone.end)
	inst.set_parameter_real_by_name("Reverse", 1.0 if zone.reverse else 0.0)
	inst.set_parameter_real_by_name("Loop Mode", zone.loop_mode)
	inst.set_parameter_real_by_name("Loop Start", zone.loop_start)
	inst.set_parameter_real_by_name("Loop End", zone.loop_end)
	inst.set_parameter_real_by_name("Crossfade", zone.crossfade * 100.0)


# --- zone edits ------------------------------------------------------------

static func delete_zones(inst: DeviceInstance, ids: Array) -> void:
	edit(inst, "Delete Samples", func(m: SamplerMultisample): m.remove_zones(ids))


static func move_to_group(inst: DeviceInstance, ids: Array, group_id: int) -> void:
	edit(inst, "Move to Group", func(m: SamplerMultisample): m.move_to_group(ids, group_id))


## Change settings of several zones as one step (a move or resize drag, a batch result).
static func set_zones_fields(inst: DeviceInstance, label: String, changes: Dictionary) -> void:
	edit(inst, label, func(m: SamplerMultisample): m.set_zones_fields(changes))


## Edit one zone from a knob or field. Consecutive edits of the same zone merge into one step.
static func set_zone_fields(inst: DeviceInstance, zone_id: int, values: Dictionary, label := "Edit Sample") -> void:
	var model := inst.ensure_multisample()
	var zone := model.get_zone(zone_id)
	if zone == null:
		return
	var old_snap := model.snapshot_zone(zone_id)
	model.set_zone_fields(zone_id, values)
	var new_snap := model.snapshot_zone(zone_id)
	if new_snap == old_snap:
		return
	var cmd := PropertyCommand.new(label, zone, "", old_snap, new_snap)
	cmd.set_callable(model.restore_zone)
	cmd.set_mergeable(true)
	HistoryUtil.record(cmd)


static func add_group(inst: DeviceInstance, group_name := "") -> void:
	edit(inst, "Add Group", func(m: SamplerMultisample): m.add_group(group_name))


static func rename_group(inst: DeviceInstance, group_id: int, new_name: String) -> void:
	edit(inst, "Rename Group", func(m: SamplerMultisample): m.rename_group(group_id, new_name))


static func remove_group(inst: DeviceInstance, group_id: int) -> void:
	edit(inst, "Delete Group", func(m: SamplerMultisample): m.remove_group(group_id))


static func set_group_fields(inst: DeviceInstance, group_id: int, values: Dictionary) -> void:
	edit(inst, "Edit Group", func(m: SamplerMultisample): m.set_group_fields(group_id, values))


# --- batch operations (REQ-047) --------------------------------------------

const BATCH_OPS := [
	"assign_velocity", "assign_note", "distribute_velocity", "distribute_notes",
	"set_root_from_name", "move_to_group", "delete",
]

const BATCH_LABELS := {
	"assign_velocity": "Assign Velocity",
	"assign_note": "Assign Note",
	"distribute_velocity": "Distribute on Velocity",
	"distribute_notes": "Distribute on Notes",
	"set_root_from_name": "Set Root from Name",
	"move_to_group": "Move to Group",
	"delete": "Delete Samples",
}


## Apply batch operation `op` to the zones `ids` as one undo step. `opts`: `lo`, `hi`, `stretch`
## and `slice` for the range operations, `group` for "move_to_group". `ids` keep the order the
## caller gives them (list order for velocity distribution).
static func apply_batch(inst: DeviceInstance, op: String, ids: Array, opts: Dictionary = {}) -> void:
	var model := inst.multisample
	if model == null or not model.active or not op in BATCH_OPS:
		return
	var selected: Array = []
	for zone_id in ids:
		var zone := model.get_zone(int(zone_id))
		if zone:
			selected.append(zone)
	if selected.is_empty():
		return
	if op == "delete":
		delete_zones(inst, ids)
		return
	if op == "move_to_group":
		move_to_group(inst, ids, int(opts.get("group", 0)))
		return
	var lo := int(opts.get("lo", 1))
	var hi := int(opts.get("hi", 127))
	var stretch := bool(opts.get("stretch", true))
	var slice := int(opts.get("slice", 1))
	var changes := {}
	match op:
		"assign_velocity":
			changes = ZoneLayout.assign_velocity(selected, lo, hi)
		"assign_note":
			changes = ZoneLayout.assign_note(selected, lo, hi)
		"distribute_velocity":
			changes = ZoneLayout.distribute_velocity(selected, lo, hi, stretch, slice)
		"distribute_notes":
			changes = ZoneLayout.distribute_notes(selected, lo, hi, stretch, slice)
		"set_root_from_name":
			changes = ZoneLayout.set_root_from_name(selected)
	set_zones_fields(inst, BATCH_LABELS[op], changes)
