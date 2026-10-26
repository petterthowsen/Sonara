# AutomationLanePresetActions.gd
# Undoable automation lane actions shared by the Arranger and the MIDI editor (spec 055). Both
# hosts pass their AutomationLaneView, so one code path covers lane creation and lane presets.
#
# Creation and preset loads are ONE macro each: create commands, then an
# AutomationShownStateCommand, so a single undo removes the created lanes and restores the shown
# set, and redo re-attaches the lanes before showing them.
class_name AutomationLanePresetActions extends RefCounted

const _Presets := preload("res://data/AutomationLanePresets.gd")
const _ShownStateCommand := preload("res://history/commands/AutomationShownStateCommand.gd")


## Create a lane for `target` on `track` as ONE undoable step, seeded with a single point holding
## the parameter's current value so creating a lane never jumps what you hear. The lane is then
## shown in `view`, inside the same step. Returns the lane, or null when nothing was created.
static func create_lane_for(track: Object, target: AutomationTarget, view: Object) -> Object:
	if track == null or target == null:
		return null
	var before: Variant = view.capture(track) if view != null else null
	var shown: Array = view.shown_lanes(track) if view != null else []
	var lane: Object = _new_seeded_lane(track, target, [])
	var cmds: Array[Command] = AutomationActions.create_lane_commands(track, lane, _seed_specs(track, target))
	if view != null:
		shown.append(lane)
		cmds.append(_ShownStateCommand.new("Show Lanes", track, view, shown, before))
	HistoryUtil.execute_many("Create Lane", cmds)
	return lane


## Save the lanes `view` shows on `track` as preset `preset_name`, in shown order. Returns false
## for an empty name, no shown lanes, or an existing name when `overwrite` is false.
static func save(view: Object, track: Object, preset_name: String, overwrite := false) -> bool:
	if track == null or view == null or preset_name.strip_edges().is_empty():
		return false
	var lanes: Array = view.shown_lanes(track)
	if lanes.is_empty():
		return false
	return _Presets.save(preset_name, _Presets.entries_for(track, lanes), overwrite)


## Show exactly the lanes of `preset` (the `{"name", "entries"}` dictionary) on `track` in
## `view`, in the preset's order, creating the lanes the track lacks. One undo step. Returns the
## entries that couldn't be resolved (skipped). A load that resolves nothing changes nothing.
static func load(view: Object, track: Object, preset: Dictionary) -> Array:
	var skipped: Array = []
	if track == null or view == null:
		return skipped
	var channel: Object = track.get_linked_channel()
	var before: Variant = view.capture(track)
	var lanes: Array = []
	var created: Array = []
	var cmds: Array[Command] = []
	var seen: Dictionary = {}
	for entry in preset.get("entries", []):
		var target := _Presets.resolve_entry(entry, channel)
		if target == null:
			skipped.append(entry)
			continue
		var key := str(target)
		if seen.has(key):
			continue
		var lane: Object = track.get_automation_lane_for(target)
		if lane == null:
			lane = _new_seeded_lane(track, target, created)
			created.append(lane)
			cmds.append_array(AutomationActions.create_lane_commands(track, lane, _seed_specs(track, target)))
		seen[key] = true
		lanes.append(lane)
	if lanes.is_empty():
		return skipped
	cmds.append(_ShownStateCommand.new("Show Lanes", track, view, lanes, before))
	HistoryUtil.execute_many("Load Lane Preset", cmds)
	return skipped


## Remove preset `preset_name` from the store. Lanes on any track are untouched.
static func delete(preset_name: String) -> bool:
	return _Presets.delete(preset_name)


static func _seed_specs(track: Object, target: AutomationTarget) -> Array:
	var seed_value: float = target.current_normalized_value(track.get_linked_channel())
	return [{"tick": 0, "value": seed_value, "curve": AutomationPoint.CurveType.LINEAR, "tension": 0.0}]


## An unattached lane for `target` whose id differs from the track's lanes and from `pending`
## (lanes made earlier in the same macro, which aren't attached yet).
static func _new_seeded_lane(track: Object, target: AutomationTarget, pending: Array) -> Object:
	var lane: Object = AutomationToolUtil.new_lane(track, target)
	var used: Dictionary = {}
	for other in pending:
		used[other.id] = true
	for other in track.automation_lanes:
		used[other.id] = true
	var n: int = track.automation_lanes.size() + pending.size()
	while used.has(lane.id):
		lane.id = "lane%d" % n
		n += 1
	return lane
