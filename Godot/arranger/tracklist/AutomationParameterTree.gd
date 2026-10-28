# AutomationParameterTree.gd
# The data behind the automation parameter picker (REQ-015, REQ-016): everything a track's linked
# Channel lets a lane drive, as a tree of `Level`s made of `Row`s. No UI here, so ordering,
# nesting and search ranking can be tested without a window.
#
# Categories, each introduced by a HEADER row (the labelled divider): Channel (volume, pan),
# Stage (spec 051), Sends, one section per top-level device in chain order, then MIDI CC (spec 030).
# Per device the section holds its "param" group, then one section per modulator (spec 018), then
# its slot children.
#
# Hierarchical mode (the default): top-level devices stay at the root so nothing needs digging for;
# only the children of a device that has slots (a PolySynth's FX, a Layer's or Drum Machine's
# slots) become SUBMENU rows holding that slot's devices as sections. A Chain device's children
# are a plain device chain and appear as sections in the same level. MIDI CC is one submenu.
# Flat mode puts every section in the root level, headed by the full path ("PolySynth › FX › EQ").
#
# Two kinds of entry are left out: a parameter whose `is_automation_safe` is false (the device
# says driving it from the audio thread is unsafe), and a parameter that already has a lane on
# this track - one target, one lane.
class_name AutomationParameterTree extends RefCounted

const SEPARATOR := " › "
## Setting key and values for the flat/hierarchical choice (see Settings.gd).
const SETTING_KEY := "appearance/automation_parameter_list"
const MODE_HIERARCHICAL := "Hierarchical"
const MODE_FLAT := "Flat"


class Row extends RefCounted:
	enum Kind { HEADER, ITEM, SUBMENU }
	var kind: int = Kind.ITEM
	var label: String = ""
	## ITEM only: what choosing the row automates.
	var target: AutomationTarget = null
	## ITEM only: submenu and device names leading to the parameter, from the root.
	var trail: PackedStringArray = PackedStringArray()
	## SUBMENU only: the level it opens.
	var level: Level = null
	## ITEM only: id of the level this row is listed in.
	var level_id: int = 0


class Level extends RefCounted:
	var id: int = 0
	var label: String = ""
	## Submenu and device names leading to this level (empty for the root).
	var trail: PackedStringArray = PackedStringArray()
	var rows: Array = []

	## First row a user can choose (an ITEM or SUBMENU), or -1.
	func first_selectable() -> int:
		for i in rows.size():
			if rows[i].kind != Row.Kind.HEADER:
				return i
		return -1


class Result extends RefCounted:
	var row: Row = null
	var score: float = 0.0
	## True when the row is listed in the searched level itself, not in a submenu below it.
	var in_level: bool = false
	## Names from the searched level down to the parameter ("EQ › Band 1" parts), for display.
	var path: PackedStringArray = PackedStringArray()
	var order: int = 0


var track: Track = null
var channel: Channel = null
var hierarchical: bool = true
var root: Level = null

var _next_level_id: int = 0


## Build the tree for `p_track`'s linked channel.
static func build(p_track: Track, p_channel: Channel, p_hierarchical: bool = true) -> AutomationParameterTree:
	var tree := AutomationParameterTree.new()
	tree.track = p_track
	tree.channel = p_channel
	tree.hierarchical = p_hierarchical
	tree._build()
	return tree


## True when nothing is left to automate.
func is_empty() -> bool:
	return root == null or root.first_selectable() < 0


# ============================================================================
# SEARCH
# ============================================================================

## Fuzzy search every parameter at or below `level`. Rows listed in `level` itself rank above
## deeper ones; within each group, by score then by menu order. Reuses `Utils.fuzzy_match`.
func search(level: Level, query: String) -> Array[Result]:
	var results: Array[Result] = []
	var q := query.strip_edges()
	if q.is_empty() or level == null:
		return results
	_collect(level, level, q, results)
	results.sort_custom(func(a: Result, b: Result) -> bool:
		if a.in_level != b.in_level:
			return a.in_level
		if not is_equal_approx(a.score, b.score):
			return a.score > b.score
		return a.order < b.order)
	return results


## Score of `query` against a parameter: its own name, or (slightly discounted) the full path so
## "poly eq freq" finds PolySynth › FX › EQ › Freq.
static func score_item(query: String, label: String, path: PackedStringArray) -> float:
	var best := Utils.fuzzy_match(query, label)
	if not path.is_empty():
		var full := " ".join(path) + " " + label
		best = maxf(best, 0.85 * Utils.fuzzy_match(query, full))
	return best


func _collect(level: Level, searched: Level, query: String, out: Array[Result]) -> void:
	for row: Row in level.rows:
		if row.kind == Row.Kind.SUBMENU:
			_collect(row.level, searched, query, out)
		elif row.kind == Row.Kind.ITEM:
			var path := row.trail.slice(searched.trail.size())
			var score := score_item(query, row.label, path)
			if score <= 0.0:
				continue
			var result := Result.new()
			result.row = row
			result.score = score
			result.in_level = row.level_id == searched.id
			result.path = path
			result.order = out.size()
			out.append(result)


# ============================================================================
# BUILD
# ============================================================================

func _build() -> void:
	root = _new_level("", PackedStringArray())
	if channel == null:
		return
	_add_channel_items()
	_add_stage_items()
	_add_send_items()
	for i in range(channel.devices.size()):
		_add_device(root, channel.devices[i], PackedStringArray(), [i])
	_add_cc_items()


func _new_level(label: String, trail: PackedStringArray) -> Level:
	var level := Level.new()
	level.id = _next_level_id
	_next_level_id += 1
	level.label = label
	level.trail = trail
	return level


func _add_header(level: Level, label: String) -> void:
	var row := Row.new()
	row.kind = Row.Kind.HEADER
	row.label = label
	level.rows.append(row)


func _add_item(level: Level, label: String, target: AutomationTarget, trail: PackedStringArray) -> void:
	var row := Row.new()
	row.kind = Row.Kind.ITEM
	row.label = label
	row.target = target
	row.trail = trail
	row.level_id = level.id
	level.rows.append(row)


func _add_submenu(level: Level, sub: Level) -> void:
	var row := Row.new()
	row.kind = Row.Kind.SUBMENU
	row.label = sub.label
	row.level = sub
	level.rows.append(row)


## One labelled section: a header, then `entries` ({label, target}). Nothing when empty.
func _add_section(level: Level, header: String, entries: Array, trail: PackedStringArray) -> void:
	if entries.is_empty():
		return
	_add_header(level, header)
	for entry in entries:
		_add_item(level, entry["label"], entry["target"], trail)


func _add_channel_items() -> void:
	var entries: Array = []
	for target in [AutomationTarget.channel_volume(), AutomationTarget.channel_pan()]:
		if not _has_lane(target):
			entries.append({"label": target.display_name(channel), "target": target})
	_add_section(root, "Channel", entries, PackedStringArray())


## Placement parameters of a stage source (spec 051); nothing for channels in another pan mode.
func _add_stage_items() -> void:
	if channel.pan_mode != Channel.PanMode.STAGE:
		return
	var entries: Array = []
	for stage_param in AutomationTarget.STAGE_PARAMS:
		var target := AutomationTarget.stage(stage_param)
		if not _has_lane(target):
			entries.append({"label": target.display_name(channel), "target": target})
	_add_section(root, "Stage", entries, PackedStringArray(["Stage"]))


func _add_send_items() -> void:
	var entries: Array = []
	for i in range(channel.send_channels.size()):
		var target := AutomationTarget.send_amount(i)
		if not _has_lane(target):
			entries.append({"label": target.display_name(channel), "target": target})
	_add_section(root, "Sends", entries, PackedStringArray(["Sends"]))


## MIDI CC (spec 030): instrument-labelled controllers first (an SFZ sampler contributes labels
## through its controller parameters), then CC0-CC119 named by `Midi.cc_display_name`. Controllers
## that already have a lane are omitted, and labelled ones don't repeat in the generic list.
func _add_cc_items() -> void:
	var labelled: Array = []
	var labelled_ids: Dictionary = {}
	for instance in AutomationTarget._devices_recursive(channel.devices):
		for param in instance.get_parameters():
			if param.id < 0 or param.id > Midi.CC_LANE_MAX or not param.is_automation_safe:
				continue
			if not instance.is_controller_parameter(param) or param.name == "":
				continue
			if labelled_ids.has(param.id):
				continue
			var target := AutomationTarget.midi_cc(param.id)
			if _has_lane(target):
				continue
			labelled.append({"cc": param.id, "label": Midi.cc_display_name(param.id, param.name), "target": target})
			labelled_ids[param.id] = true
	labelled.sort_custom(func(a, b): return a["cc"] < b["cc"])

	var generic: Array = []
	for cc in range(Midi.CC_LANE_MAX + 1):
		if labelled_ids.has(cc) or _has_lane(AutomationTarget.midi_cc(cc)):
			continue
		generic.append({"label": Midi.cc_display_name(cc), "target": AutomationTarget.midi_cc(cc)})
	if labelled.is_empty() and generic.is_empty():
		return

	var trail := PackedStringArray(["MIDI CC"])
	var level := root
	if hierarchical:
		_add_header(root, "MIDI")
		level = _new_level("MIDI CC", trail)
	# Flat: the two groups share the one "MIDI CC" section, labelled controllers first.
	var all_entries: Array = labelled + generic
	if not hierarchical:
		_add_section(root, "MIDI CC", all_entries, trail)
		return
	_add_section(level, "Instrument controllers", labelled, trail)
	_add_section(level, "Controllers", generic, trail)
	_add_submenu(root, level)


## `instance` as a labelled section of `level` (its parameters, then one per modulator), followed
## by its children. `trail` names what leads to `instance`; `path` addresses it in the channel.
func _add_device(level: Level, instance: DeviceInstance, trail: PackedStringArray, path: Array) -> void:
	if instance == null:
		return
	var full := trail.duplicate()
	full.append(instance.name)
	var header := instance.name if hierarchical else SEPARATOR.join(full)

	var entries: Array = []
	for param in instance.get_parameters_in_group("param"):
		if not param.is_automation_safe or instance.is_controller_parameter(param):
			continue
		var target := AutomationTarget.device_param(path, param.id)
		if not _has_lane(target):
			entries.append({"label": AutomationTarget.param_label(instance, param), "target": target})
	_add_section(level, header, entries, full)

	for mod in instance.modulators:
		var mod_entries: Array = []
		for param in mod.get_parameters():
			if not param.is_automation_safe:
				continue
			var target := AutomationTarget.device_modulator_param(path, mod.mod_id, param.id)
			if not _has_lane(target):
				mod_entries.append({"label": param.name, "target": target})
		var mod_trail := full.duplicate()
		mod_trail.append(mod.name)
		_add_section(level, mod.name if hierarchical else SEPARATOR.join(mod_trail), mod_entries, mod_trail)

	# A Chain's children are a device chain like the channel's own: sections in the same level.
	# Any other device's children are slots: submenus when hierarchical.
	var inline := SlotChain.is_chain(instance)
	for i in range(instance.children.size()):
		var child: DeviceInstance = instance.children[i]
		if inline:
			_add_device(level, child, full, path + [i])
		elif hierarchical:
			var sub := _new_level(child.name, full + PackedStringArray([child.name]))
			_add_device(sub, child, full, path + [i])
			if not sub.rows.is_empty():
				_add_submenu(level, sub)
		else:
			_add_device(level, child, full, path + [i])


## True when `track` already has a lane driving `target` (REQ-015).
func _has_lane(target: AutomationTarget) -> bool:
	return track != null and track.get_automation_lane_for(target) != null
