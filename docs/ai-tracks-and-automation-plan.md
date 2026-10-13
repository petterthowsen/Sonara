# AI Assistant: track ordering, grouping and automation

The assistant can create tracks, groups and folders, but it can't move existing tracks into or out of them or reorder them. It also can't touch automation. This plan adds three things:

- **Phase 0**: one tool that moves tracks and channels (reorder, nest, un-nest).
- **Phase 1**: tools to add, remove and list automation lanes.
- **Phase 2**: one tool that writes automation points. It is atomic and simple for the LLM to call.

Each phase ships on its own, with tests, and leaves the build green. Do them in order.

## Read first

- `Godot/ai/tools/AiTool.gd`: base class. Covers result helpers (`ok`, `ok_text`, `fail`), name resolvers (`resolve_track`, `resolve_channel`, `resolve_device`), time parsing (`resolve_start_ticks`, `resolve_time_span`, `position_error`) and the compact row builders.
- `Godot/ai/tools/ToolRegistry.gd`: `create_default()` registers each tool.
- `Godot/ai/prompt/system_prompt.md`: domain notes for the model. Add one short bullet per new capability.
- Pattern tools: `RouteChannelTool.gd` (simple), `SetDeviceParamsTool.gd` (validate everything, then apply one `HistoryUtil.execute_many` macro).
- Tests: `Godot/ai/tests/test_set_mixer_pan.gd` shows the setup pattern (a fresh `Project` plus `Editor`, with `Sonara.editor` assigned). Run them with `Godot/tests/run_all.sh <word>`.

Tool conventions every new tool must follow:

- Address things by **name**, never by numeric id. Resolve them with the `AiTool` resolvers, which already return "did you mean" errors.
- **Validate everything before mutating anything.** On any error, return `fail("... Nothing was changed.")`.
- Each tool call produces **one undo step** (`HistoryUtil.execute`, `execute_many`, `record`, or `record_many`).
- Return `ok_text("<short human summary>", data)`. Only the text goes to the model.
- Values go in and come out in **real units** (dB, pan -1..1, the parameter's own units or enum label). Never ask the model for normalized 0..1 values.

---

## Phase 0: `move_track`

### Existing machinery

- `Project.place_track(track, new_parent_id, after_sibling)` (`Godot/data/Project.gd` ~1502) reorders and reparents a track. It also syncs the paired channel nesting and routing (`_sync_channel_nest_for_track_move`, `sync_subtree_hierarchy_routing`). `new_parent_id = -1` means top level. `after_sibling = null` places the track first.
- `Project.can_place_track(track, new_parent_id)` refuses moving a track into itself or its own subtree, moving it under a parent that can't hold tracks, and moving an aux return away from its source.
- Undo goes through `TrackReorderCommand.capture_layout()` before and after, then `HistoryUtil.record(TrackReorderCommand.new(project, before, after))`. `TrackDropTarget.commit()` (`Godot/arranger/tracklist/TrackDropTarget.gd:78`) is the reference implementation. Copy its shape, including the `begin_track_layout_batch()` / `end_track_layout_batch()` pair and the "unfold the target folder" step.
- For a **bus channel with no paired track** (made by `create_bus`), use `MixerChannelDrag.commit(project, child, parent_channel_or_null, after_sibling_channel)` (`Godot/mixer/MixerChannelDrag.gd`). It already handles history.

### Tool: `Godot/ai/tools/MoveTrackTool.gd`

```
name: move_track
description: Reorder tracks, or move them into or out of a group or folder. Moves the
  listed tracks together, in the given order. Undoable.
parameters:
  tracks:  array of string, required. Track names (a bus name also works), moved as a block in this order.
  into:    string, optional. Group or folder name, or "top" for the top level.
           Omitted = stay under the current parent.
  after:   string, optional. Sibling name to place the block after, or "start" for first.
           Omitted = last under the target parent.
```

Execution:

1. Resolve each name. Try `project.find_by_name` (as `resolve_track` does). If a name is a bus channel with no paired track, collect it separately (see step 6). Duplicate names → fail.
2. Resolve `into`. `"top"` (via `NameStyle.key`) → `-1`. Otherwise it must be a track with `can_contain_tracks()`; if not, fail with `"<name>" is not a group or folder`. If `into` is omitted, use the first track's current `parent_track_id`.
3. Resolve `after`. `"start"` → `null`. A name must resolve to a track whose `parent_track_id == parent_id` and that is not in the moved set; otherwise fail with `"X" is not inside <parent>`. If `after` is omitted, use the last sibling under the parent that is not being moved (`project.get_track_children(parent)` or, at top level, the sorted roots; see `_sorted_track_siblings`). If there are no siblings, use `null`.
4. Pre-check every track with `can_place_track(track, parent_id)`. Fail on the first one that is refused, with a reason. The most common reason is moving a group into its own child.
5. Apply it as `TrackDropTarget.commit` does: capture the layout, batch, call `place_track(t, parent_id, after)` and then set `after = t` for each track, end the batch, capture again. If `layouts_equal`, return `ok_text("Already in place")`. Otherwise `HistoryUtil.record(...)`. If the target folder is collapsed, unfold it.
6. Bus-only channels: keep it simple and **don't mix them with tracks**. If every name is a bus with no track, `into` names a group channel (or `"top"` to un-nest) and `after` names a sibling channel. Call `MixerChannelDrag.commit` for each channel. If tracks and track-less buses are mixed in one call → fail with "Move buses and tracks in separate calls".
7. Result text: `Moved Bass, Keys into "Band" after "Drums"`. Data: the new `list_tracks` rows.

### Expose the hierarchy

The model can't move what it can't see:

- `AiTool.compact_track`: add `"parent": <parent name>` when `parent_track_id >= 0`.
- `ListTracksTool`: iterate `project.get_visual_track_list()` (tree order) instead of `project.tracks`, so the list order matches the arranger.
- Check `PromptContext.gd` for any track listing it builds. If it lists tracks, use the same order and parent field there.

### Prompt

Add one bullet next to the Group and Folder Bus lines in `system_prompt.md`: "`move_track` reorders tracks or moves them into or out of a group or folder (`into: "top"` un-nests). Moving into a group re-routes the channel to the group."

### Tests: `Godot/ai/tests/test_move_track.gd`

- Reorder three top-level tracks with `after`, including `"start"`. Check the order, then undo and redo.
- Move two tracks into a group. Check `parent_track_id`, that the channels route to the group channel, and the order. Undo restores the parent and the routing.
- `into: "top"` un-nests.
- Refusals leave the layout unchanged: a group into its own child, `into` set to an instrument track, `after` naming a track under a different parent, an unknown name with a suggestion.
- A track-less bus nested into a group via the bus branch.
- `list_tracks` includes `parent` and returns tree order.

---

## Phase 1: automation lanes

### Existing machinery

- Model: `Track.automation_lanes`, `Track.add_automation_lane` / `remove_automation_lane` / `get_automation_lane_for(target)`. `AutomationLane` holds points (normalized values, sorted by tick). `AutomationTarget` comes from `channel_volume()`, `channel_pan()`, `send_amount(i)`, `midi_cc(n)` and `device_param(path_indices, param_id)`. It also provides `display_name(channel)`, `format_value(channel, n)`, `parse_edit_text(channel, text)` and `current_normalized_value(channel)`.
- Undo: `AutomationActions.create_lane(track, lane)` / `delete_lane(track, lane)` / `add_points(lane, specs)` / `delete_points(lane, points)` (`Godot/arranger/.../AutomationActions.gd`; find it with `grep -rl "class_name AutomationActions"`). Its header comment explains why it `preload`s the command scripts. Follow that if you reference the commands directly.
- The UI flow to mirror is `TrackList._on_automation_parameter_chosen` and `_unique_lane_id` (`Godot/arranger/tracklist/TrackList.gd` ~897). A new lane gets a unique id (`lane<N>`), a height from settings, and **one seed point at tick 0 holding the current value**, so adding a lane never changes the sound.
- Rules from `AutomationParameterPicker`: one lane per target per track, and a device parameter must have `is_automation_safe`. Lanes live on a track and drive its linked channel, so a track with no linked channel (a plain folder) can't have lanes.

### Shared helper: `Godot/ai/tools/AutomationToolUtil.gd`

All three automation tools address a target with the same two arguments:

```
track: string, required. Track name.
param: string, required. "Volume", "Pan", "Send <bus name>", "CC <0-119>", or a device parameter name.
path:  string, optional. Device path (as in get_device / set_device_params), required for a device parameter.
```

`static func resolve_target(project, track, args) -> Variant` returns an `AutomationTarget` or `fail(...)`:

1. If there is no `path`, match `param` with `NameStyle.key`:
   - `volume` → `channel_volume()`.
   - `pan` → `channel_pan()`. Pan lanes drive the position in balance, combined and mono modes. Don't special-case dual mode beyond what `AutomationTarget` already does.
   - `send <name>` → find the index in `channel.send_channels` whose target channel name matches → `send_amount(i)`. If not found, fail and list the existing sends.
   - `cc <n>` or `cc<n>` → `midi_cc(n)`, with `n` in 0..119.
   - Anything else → fail: "For a device parameter pass path too".
2. If there is a `path`: `resolve_device(project, args)`. The device must sit on **the track's linked channel**; check that the path's channel is `track.get_linked_channel()`, else fail. Find the parameter with `DeviceToolUtil.match_param(inst.get_parameters(), param)`. Require `is_automation_safe`. Build the index path by walking from the device up through its parents to the channel root, collecting each device's index in its host array (`channel.devices` / `parent.children`). Add that as a small static on the util, and check that it round-trips through `AutomationTarget.resolve(channel)`. Return `device_param(indices, param.id)`.
   - Modulator parameters are out of scope; say so in the failure text if needed.

`static func describe_lane(track, lane) -> Dictionary` returns `{param: display_name, points: N, bypassed?}`. For ≤ 16 points it also returns `values: [["<bbt>", "<format_value>"], ...]`; past that, `range: [first_bbt, last_bbt]`. Format positions with `ClipTextTime.format_bbt`.

`static func unique_lane_id(track) -> String`: move `TrackList._unique_lane_id` here as a static and have `TrackList` call it, so there is one source.

`static func new_lane(track, target) -> AutomationLane`: id, height (same settings logic as `TrackList`) and target. Have `TrackList._on_automation_parameter_chosen` use it too.

### Tools

`add_automation_lane` (`AddAutomationLaneTool.gd`):
- Takes `track`, `param`, and `path`. Fails if a lane already exists for the target (`get_automation_lane_for`). Name the existing lane so the model knows it can write to it directly.
- Creates the lane and its seed point as **one** undo step: `HistoryUtil.execute_many("Create Lane", [LaneCreateCommand, PointsAddCommand])`. Don't call `AutomationActions.create_lane` and `add_point` back to back, because that makes two undo steps. If building the commands needs the lane attached first, do `create_lane` then `add_points` inside a single macro. Check how `HistoryUtil.execute_many` runs commands in order.
- Sets `track.automation_expanded = true` so the user sees the lane.
- Text: `Added Volume lane on Lead (starts at -6.0 dB)`.

`remove_automation_lane` (`RemoveAutomationLaneTool.gd`):
- Takes `track`, `param`, and `path`. Resolves the target, then the lane, and fails if there is none. It also accepts `param` equal to the lane's `display_name` for lanes whose device has since moved (unresolved lanes). Match against `display_name(channel)` of every lane before resolving.
- Calls `AutomationActions.delete_lane`.

`list_automation` (`ListAutomationTool.gd`):
- `track` is optional. If omitted, list every track that has lanes. Returns `describe_lane` rows per track. Mark unresolved lanes with `"unresolved": true`.

Also add `"lanes": N` to `compact_track` when N > 0, so `list_tracks` hints that automation exists.

### Prompt

Add one bullet: lanes belong to a track and drive its own channel. `param` is Volume, Pan, `Send <bus>`, `CC <n>`, or a device parameter with `path`. One lane per parameter.

### Tests: `Godot/ai/tests/test_automation_lane_tools.gd`

- Add Volume, Pan, `Send <bus>`, `CC 1` and a built-in device parameter (e.g. the Filter cutoff on a channel). Each has one seed point equal to the current value. One undo removes both the lane and the point.
- Refusals: a duplicate lane, an unknown param, a device path on another channel, a folder track with no channel, a non-automation-safe parameter (if a built-in exposes one; otherwise skip).
- Remove, then undo restores the points.
- `list_automation` output shape.
- `TrackList` still compiles after the `unique_lane_id` / `new_lane` move. Run the existing arranger automation tests (`run_all.sh automation`).

---

## Phase 2: `write_automation`

### Design goal

The model describes a shape over a time range in one call, in real units. The tool turns that into points. The model never manages point ids, never deletes points one by one, and never creates the lane separately.

```
name: write_automation
description: Write automation for one parameter on a track over a time range, replacing
  whatever was there in that range. Creates the lane if needed. Undoable as one step.
parameters:
  track, param, path: as in add_automation_lane.
  points: array, required. Each item is [position, value] or [position, value, "step"].
      position: bar number, "bar.beat.tick", or ticks (same parsing as other tools' start).
      value:    real units: dB for Volume/Send, -1..1 for Pan, 0..127 for CC,
                the parameter's real value / bool / enum label for device params.
      "step":   hold this value until the next point (no ramp). Default is a linear ramp.
  clear: optional {start, end}. Range to wipe first. Default: from the first to the last
         given position, inclusive.
```

Examples to put in the prompt bullet (they're short and teach the whole thing):

- Fade in over bars 1–5: `points: [[1, -60], [5, 0]]`
- Filter sweep: `path: "Lead/Filter", param: "Cutoff", points: [[9, 200], [17, 8000]]`
- Gate pattern: `points: [[1,0,"step"],[1.3,-60,"step"],[2,0,"step"],[2.3,-60,"step"]]`. Note that `1.3` as a number is a bar number, so the prompt must say to use **strings** for bar.beat: `["1.3", -60, "step"]`.

### Execution (atomic)

1. Resolve the track, then the target (`AutomationToolUtil.resolve_target`).
2. Parse every point first, collecting **all** errors as `SetDeviceParamsTool` does:
   - Position: run `position_error`, then `resolve_start_ticks(project, {"start": item[0]})`.
   - Value → normalized, with one helper `AutomationToolUtil.to_normalized(target, channel, value) -> {ok, normalized} | {error}`:
     - Volume or Send: clamp dB to -60..12 (as `SetMixerTool` does) → `AutomationTarget.db_to_normalized`.
     - Pan: -1..1 → `pan_to_normalized`.
     - CC: 0..127 → `/127.0`.
     - Device param: `DeviceToolUtil.parse_param_value(param, value).normalized`. That gives the same units, bool and enum handling as `set_device_params`.
   - Curve: `"step"` → `CurveType.STEP`, else `LINEAR`. Any other third element → error.
   - Duplicate positions: keep the last one; don't treat it as an error.
   - If there are errors, `fail("<all errors>. Nothing was changed.")`.
3. The clear range is `clear` (via `resolve_time_span` on its own sub-dict) or `[min_tick, max_tick]` of the given points. Use inclusive bounds for points.
4. Build **one** command list:
   - If there is no lane: a lane-create command (no seed point; the written points are the content). Note that this means a lane starts with nothing before the first point. That's fine, because a lane holds its first value before the first point (`get_value_at_tick`).
   - Remove existing points whose tick is inside the clear range (`PointsRemoveCommand`).
   - Add the new points (`PointsAddCommand`).
   - `HistoryUtil.execute_many("Write Automation", cmds)`.
   - Check order sensitivity: the add and remove commands need `lane` to be attached for OSC sync. `execute_many` must run `do()` in list order and `undo()` in reverse. Confirm in `HistoryUtil._one_or_macro` and the macro command class.
5. Expand the track's automation and set the lane visible.
6. Result text: `Lead Volume: wrote 2 points 1.1.000 → 5.1.000 (-60.0 dB → 0.0 dB), replaced 3`. Format values with `target.format_value`.

### Why not more shapes?

Linear and step points cover fades, sweeps, swells and gates. Curved shapes (`tension`) and LFO-style generators (`"sine", rate, depth`) are tempting but add parameters the model will misuse. Leave them out. If they're needed later, add an optional `shape` argument that expands to points on the Godot side; the tool stays atomic either way.

### Also add

- `clear_automation`: probably not needed. `write_automation` with `points: []` and `clear` should remove a range. Allow an empty `points` **only** when `clear` is given, and say so in the description. Removing the whole lane is `remove_automation_lane`.
- `list_automation` from Phase 1 is the read side. Check that its `values` use the same units the write accepts, so the model can round-trip them.

### Tests: `Godot/ai/tests/test_write_automation.gd`

- A volume fade on a new lane creates the lane and 2 points with the right ticks and normalized values. **One** undo removes the lane entirely, and redo restores it.
- Writing into an existing lane replaces only the points inside the range and keeps those outside it. Undo restores the replaced points with their original ids.
- Step points get `CurveType.STEP`.
- A device param with an enum label and a real value (e.g. Filter type and cutoff) gives the same normalized value as `set_device_params` for the same input.
- `"1.3"` as a string resolves to bar 1, beat 3.
- Mixed errors (a bad position and an out-of-range enum) list both and change nothing (lane count and points unchanged).
- `points: []` with `clear` removes a range; `points: []` without `clear` fails.
- A round trip: the `list_automation` values written back produce the same points.

---

## Done checklist (per phase)

- [ ] Tool(s) registered in `ToolRegistry.create_default()`.
- [ ] `system_prompt.md` bullet added (keep it to a few lines).
- [ ] New test script passes, and `Godot/tests/run_all.sh ai` plus `run_all.sh automation` pass.
- [ ] Manual check in the app: ask the assistant to do it, then press Ctrl+Z once and confirm the whole change is reverted.
- [ ] Commit per phase.
