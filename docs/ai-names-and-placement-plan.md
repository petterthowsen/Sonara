# AI tools: unique names, device lookup, linked delete, clip placement

Implementation plan based on what went wrong in the city_pop_2 conversation. The sections below explain what happened and what we change.

## Checklist

- [ ] Phase 1: Fuzzy device and asset lookup (validate before creating anything)
- [ ] Phase 2: Deleting a track or channel removes its linked partner
- [ ] Phase 3: Where new clips go by default, and refusing overlaps
- [ ] Phase 4: Unique track and channel names in the data model
- [ ] Phase 5: Tools and the system prompt refer to things by name, not id

## Why

Conversation: `~/Documents/Sonara/city_pop_2.aichat/conv_851bcdd6929c.json`. The user asked for a drum machine track made from `acoustic-drums-2/med-velocity` samples, then for a "Plastic Love" style groove.

| Call | Result | Cause |
|---|---|---|
| `create_track device_id:"drum_machine"` | Track and channel created, then `Warning: device not added` | The model guessed the id; the real one is `sonara.builtin.drum_machine`. [CreateTrackTool.gd](../Godot/ai/tools/CreateTrackTool.gd) creates the track *before* it resolves the device, so a bad id still leaves a half-made track behind. |
| `delete_track track_id:0` | `Deleted track "Drums"` | `TrackDeleteCommand` doesn't remove the linked channel. Channel 2 "Drums" was left behind, still routed to Master. The tracklist context menu has the same bug. |
| `create_track … name:"Drums"` (again) | Track 1, channel 3 | Nothing stops duplicate names, so the mixer now has two "Drums" strips. |
| `list_tracks`, then `add_device channel_id:3 parent:"Drum Machine"` | Worked | The model kept mixing up track ids and channel ids. Track ids start at 0, while channel id 0 means "no output". |
| `create_clip` with no `start` | Placed at `1.1.013` | `resolve_start_ticks` returns the raw `Sonara.editor.playhead_ticks`, which had drifted to tick 13. The prompt snapshot still said `1:1:000`. |

It also turned out that `create_clip` and `place_clip` never check for overlap, while the timeline's paste and duplicate refuse to overlap ([Timeline.gd:850](../Godot/arranger/timeline/Timeline.gd#L850), [Timeline.gd:924](../Godot/arranger/timeline/Timeline.gd#L924)).

## Goals

1. A device id or asset path that doesn't match exactly is looked up by fuzzy search. If exactly one thing matches, the tool uses it and says so. If several match, the tool returns "did you mean …?". If nothing matches, the tool fails **before** it changes anything.
2. Deleting a track also deletes the channel linked to it, and the reverse. Both are undoable as one step.
3. When no `start` is given, a new clip goes to the range start, then 1.1.000 if the track is empty, then the playhead rounded down to the bar. Overlapping placements are refused with a hint.
4. Track and channel names are unique. The model enforces this by adding a suffix (`Drums 2`), and projects are cleaned up when they load.
5. AI tools take names (`track`, `channel`, `output`, `path`) instead of numeric ids. Ids no longer appear in tool results or in the system prompt.

## Non-goals

- Replacing existing clips on overlap (a `replace` flag). Refusing is enough for now.
- Fixing the range-selection UX and the selection context badges. Both are in TODO.md › AI Assistant. This plan only reads the range state as it is today.
- Engine or OSC changes. Channel ids stay the engine-facing identity; names are a Godot-side concept.
- Changing the persisted format. Names are already saved; loading only renames duplicates.

---

## Phase 1: Fuzzy device and asset lookup

### 1.1 `DeviceToolUtil.resolve_asset_fuzzy` ([DeviceToolUtil.gd](../Godot/ai/tools/DeviceToolUtil.gd))

Add a resolver that returns a result dictionary instead of `Asset`/null:

```gdscript
## { asset: Asset, note: String } on success, or AiTool.fail(...) with suggestions.
static func resolve_asset_fuzzy(args: Dictionary, type_filter: String = "") -> Dictionary
```

1. Try `resolve_asset(args)` first, as today (exact path, exact device id, registry lookup). If it succeeds, return it with an empty `note`.
2. Otherwise build a query from the input:
   - Device ids: drop a `sonara.builtin.` prefix, and turn `_`, `-` and `.` into spaces (`drum_machine` → `drum machine`).
   - Paths: use the file name without its extension, plus the last folder name (`VPO3/Strings/violin.sfz` → `strings violin`).
3. Run `AssetService.search_assets(query, type_filter, 6)`. For `device_id`, `type_filter` is `device`. For `asset_path`, infer it from the extension (`.sfz` → sfz, audio extensions → audio). Otherwise leave it empty.
4. What to return:
   - `total == 1`: `{asset, note: "Resolved \"drum_machine\" → Drum Machine (sonara.builtin.drum_machine)"}`.
   - `total > 1`: `fail("Unknown device \"drum\". Did you mean: Drum Machine (sonara.builtin.drum_machine), Drum Bus (…)?")`. List at most 5 candidates as `name (id)` for devices, or as relative paths for assets.
   - `total == 0`: `fail("Unknown device \"drum_machine\". Use search_assets type:device.")`.

An exact name match counts as one hit even when other assets also match. Otherwise the query "delay" could never resolve if "Delay" and "Tape Delay" both exist.

### 1.2 Callers

- **`create_track`**: resolve the device *before* running `TrackCreateCommand`. If resolving fails, return the error and create nothing. Add the `note` to the result text as a second line.
- **`add_device`** (the single `device_id`/`asset_path`, each entry of `asset_paths`, and each object in `samples`): if any entry fails, fail the whole call before adding anything. Collect the notes from every entry.
- **`load_device_file`**: same fuzzy lookup for `asset_path`, restricted to the file type the target device accepts.

### 1.3 Tests

In `Godot/ai/tests/test_device_tools.gd`, or a new `test_fuzzy_resolve.gd`:

- `drum_machine` → Drum Machine, with a note.
- A query matching several devices → the fail text contains "Did you mean" and both names.
- An unknown id on `create_track` → fails, and `project.tracks.size()` is unchanged.
- An exact name ("Delay") wins even though "Tape Delay" also exists.

---

## Phase 2: Deleting a track or channel removes its linked partner

### 2.1 Which pairs count as linked

`Track.get_linked_channel()` already defines the pairs:

| Track | Linked channel |
|---|---|
| Instrument or audio track | Its routed strip (`default_channel_id`) |
| Group track | The group channel |
| Folder bus | The bus channel |
| Plain folder | None |
| Drum pad return track | The aux return channel (`Channel.is_aux_return()`) |

Only delete the channel if no *other* track still uses it (check `channel.routed_tracks` without the tracks being deleted). The Master channel is never deleted.

### 2.2 `TrackDeleteCommand` ([TrackDeleteCommand.gd](../Godot/history/commands/TrackDeleteCommand.gd))

- In `do()`: for every track in `_subtree`, collect its linked channel if it qualifies.
- Before removing anything, take a snapshot of everything `Project.remove_channel` changes but doesn't restore:
  - Channels whose `output_channel_id` pointed at a deleted channel (they get rerouted to Master).
  - Sends that target a deleted channel.
  - Any `parent_channel_id` that points at a deleted channel.
- Remove the tracks, then the channels.
- In `undo()`: add the channels back first, with the same `Channel` objects so ids and devices are kept (the way `TrackCreateCommand.do()` re-adds them). Then add the tracks back, restore the routes, sends and parents from the snapshot, and finally apply `_layout_snapshot`.
- Rename the command to "Delete Track" only when no channel was removed, otherwise "Delete Track and Channel".

### 2.3 New `ChannelDeleteCommand`

Add `Godot/history/commands/ChannelDeleteCommand.gd`. It deletes the channel and every track linked to it, using the same snapshot and restore logic. Put that logic in a shared helper (`history/commands/LinkedDeleteSnapshot.gd`) so the two commands don't drift apart.

- [Mixer.gd:292](../Godot/mixer/Mixer.gd#L292) `_on_channel_delete_requested` currently calls `project.remove_channel` directly, so the delete can't be undone and the linked instrument track is quietly rerouted to Master. Change it to `HistoryUtil.execute(ChannelDeleteCommand.new(...))`.
- [TrackItemContextMenu.gd:187](../Godot/arranger/tracklist/TrackItemContextMenu.gd#L187) needs no change; it picks up the new `TrackDeleteCommand` behavior.

### 2.4 AI tool

`delete_track` becomes `delete`, taking `{name}`. Because names become unique across tracks and channels (Phase 4), one name identifies exactly one track/channel pair, a bus, or a folder. The result lists everything removed: `Deleted track and channel "Drums"`.

### 2.5 Tests

Add `Godot/tests/test_linked_delete.gd`:

- Deleting an instrument track removes its channel. Undo brings both back with the same ids and devices.
- Deleting a channel from the mixer path removes its track. Undo restores it.
- A channel routed to the deleted bus goes back to its original route after undo.
- A group with children: the children's tracks and channels are deleted and restored.
- A channel still used by another track is not deleted.

---

## Phase 3: Where new clips go by default, and refusing overlaps

### 3.1 `AiTool.resolve_placement` ([AiTool.gd](../Godot/ai/tools/AiTool.gd))

This replaces the `resolve_start_ticks` call in `create_clip` and `place_clip`:

```gdscript
## { start: int, length: int, reason: String } or fail(...).
## `length` is the requested length, or -1 to let the range decide (create_clip only).
static func resolve_placement(project: Project, track: Track, args: Dictionary, length: int) -> Dictionary
```

Rules for the start, in order; the first one that applies wins:

1. **`start` was given**: parse it as today, don't snap it. Reason: `at 5.1.000`.
2. **A range is active** (`ClipSelectionManager.has_range()`): use `range_start_tick`. If `length == -1` and the range has an end (`range_has_end`, with end > start), the length is `range_end_tick - range_start_tick`. Reason: `at range start 5.1.000`.
3. **The track is empty** (`track.clip_instances.is_empty()`): start at 0. Reason: `at 1.1.000 (empty track)`.
4. **Otherwise**: round the playhead down to the bar, `floor(playhead / ticks_per_bar) * ticks_per_bar`. Reason: `at playhead bar 5`.

If the length is still -1, fall back to `bars` (default 1) × ticks per bar.

Get the range through a small accessor such as `Sonara.editor.arranger.timeline.clip_selection_manager`, and add `Editor.get_time_range() -> Dictionary` so tools don't reach into the arranger themselves. In test mode, or when there's no editor, treat it as "no range, playhead 0".

**Overlap:** if `track.has_clip_overlap(start, length)` is true, fail:

```
Error: Bars 1–3 on "Drums" are occupied by "City Pop Groove" (1.1.000–3.1.000). Next free bar: 3.
```

- List up to 3 overlapping instances.
- "Next free bar" is the first bar boundary at or after the end of the last overlapping instance where `[bar, bar + length)` is free on that track.
- This applies to explicit starts too.

### 3.2 Callers

- **`create_clip`**: `bars` becomes optional, since the length can come from the range. Resolve the placement *before* `ClipActions.create_clip`, so a failure doesn't leave an empty clip in the pool. Put `reason` in the result line: `Created clip "Groove" on "Drums" at range start 5.1.000 (2 bars)`.
- **`place_clip`**: same rules, with `length` = the clip's content length. Rule 3 ("empty track") applies to the target track.
- Update the `start` description in both schemas: "bar.beat.tick or bar number. Default: range start, else 1.1.000 on an empty track, else the playhead's bar".

### 3.3 System prompt ([PromptContext.gd](../Godot/ai/prompt/PromptContext.gd))

- Add a `Range:` line next to `Playhead:`, e.g. `Range: 5.1.000–9.1.000`, `Range: start 5.1.000`, or `Range: none`.
- Add one line to `system_prompt.md` under "MIDI clips": "Without `start`, clips go to the range start, then 1.1.000 on an empty track, then the playhead's bar. Overlaps are refused."

### 3.4 Tests

In `Godot/ai/tests/test_clip_tools.gd`, or a new `test_clip_placement.gd`, with the range and playhead faked through the editor accessor:

- Empty track, no start → tick 0, even when the playhead is at 13.
- Track with clips, playhead at bar 5 + 13 ticks → bar 5.
- Range 5–9 with no `bars` → start at bar 5, 4 bars long.
- Overlap → fails, the text names the clip and the next free bar, and the clip pool is unchanged.
- Explicit `start: "1.1.013"` → used exactly as given.

---

## Phase 4: Unique track and channel names in the data model

### 4.1 One shared namespace

Tracks and channels share **one** namespace, and a linked track/channel pair counts as one entry. As a result, "Drums" always means one thing, and tools don't need separate `track` and `channel` lookups.

| Situation | Allowed? |
|---|---|
| Instrument track "Drums" and its own channel "Drums" | Yes (a linked pair) |
| Folder "Drums" and an unrelated bus "Drums" | No; the bus becomes "Drums 2" |
| Two instrument tracks "Drums" | No; the second becomes "Drums 2" |

Reserved names, compared case-insensitively: `Master` (only channel 1 may use it), `None`, and `Hardware Out`/`Hardware Out N`. A user name that matches one gets a suffix.

### 4.2 `Project` API ([Project.gd](../Godot/data/Project.gd))

```gdscript
## Every track and channel name except `exclude_track` / `exclude_channel` (and each one's linked partner).
func names_in_use(exclude_track: Track = null, exclude_channel: Channel = null) -> PackedStringArray

## `desired`, or `desired N` if the name is taken or reserved. Reuses DeviceNaming.unique_in.
func unique_name(desired: String, exclude_track: Track = null, exclude_channel: Channel = null) -> String

## The track or channel called `name` (case-insensitive), as {track, channel}. Either may be null.
func find_by_name(name: String) -> Dictionary
```

`DeviceNaming.unique_in`, `names_equal` and `sanitize` already provide the suffix and comparison logic devices use (`Delay 2`). Reuse them.

### 4.3 Where names get enforced

Names are currently written directly in several places, so enforcement has to happen where a name *enters* the project:

| Site | Change |
|---|---|
| `Project.create_channel` ([Project.gd:592](../Godot/data/Project.gd#L592)) | `channel.name = unique_name(channel_name)` |
| `Project.create_*_track` ([Project.gd:717](../Godot/data/Project.gd#L717), 966, 988) | Give the track and its new channel one name: `unique_name(track_name)` |
| `Project.add_track` / `add_channel` (the undo/redo re-add path) | If the name is now taken, for example the user created "Drums" after deleting it, add a suffix and log it |
| `Track.name` setter / `set_name` ([Track.gd:30](../Godot/data/Track.gd#L30)) | When a project is attached, `unique_name(value, self, linked_channel)` |
| `Channel.set_name` ([Channel.gd:253](../Godot/data/Channel.gd#L253)) | `unique_name(new_name, null, self)` through `_project_ref` |
| `AuxReturnSync` ([AuxReturnSync.gd:171](../Godot/data/AuxReturnSync.gd#L171), 187, 268) | Name the return channel and track through `unique_name` (a second drum machine gets `KICK 2`) |
| Mixer "Bus %d" ([Mixer.gd:402](../Godot/mixer/Mixer.gd#L402)) | Fine as is; `create_channel` enforces it |
| `TrackItemContextMenu._on_name_changed` ([TrackItemContextMenu.gd:180](../Godot/arranger/tracklist/TrackItemContextMenu.gd#L180)) | Goes through the setter. The inline editor must show the *final* name: re-read it after setting, or listen to `name_changed` |

Undo of a rename: `HistoryUtil.execute_property("Rename Track", track, "set_name", old, new)` stores the *requested* name. Use the name after uniquifying as `new`, so redo doesn't produce a different suffix. Either compute `unique_name` before recording, or use a `RenameCommand` that captures the result.

`name_by_channel` syncing: when a track renames its linked channel, pass the track and the channel as exclusions, so the pair doesn't collide with itself.

### 4.4 Loading projects

At the end of `Project.from_json`, after tracks and channels are attached, run `dedupe_names()`:

- Walk channels in id order, then tracks in tree order.
- Rename the second and later occurrences with `unique_name`. Linked pairs share a name, so they aren't treated as duplicates.
- Log each rename at info level: `[Project] Renamed duplicate channel 3 "Drums" → "Drums 2"`.

This renames city_pop_2's second "Drums" when the project loads. The next save writes the new names; there's no format change.

### 4.5 Tests

Add `Godot/tests/test_unique_names.gd`:

- Creating two instrument tracks named "Drums" gives "Drums" and "Drums 2".
- Renaming a bus to an existing track's name adds a suffix, and undo/redo keeps the same final name.
- A linked pair can share a name, and renaming the track renames the channel without "Drums 2".
- `Master`, `none` and `hardware out` are refused for user tracks.
- `from_json` with duplicate names results in unique names, and linked pairs stay linked.
- Deleting "Drums", creating a new "Drums", then undoing the delete re-adds the old one as "Drums 2".

---

## Phase 5: Tools and the system prompt refer to things by name, not id

### 5.1 Resolvers ([AiTool.gd](../Godot/ai/tools/AiTool.gd))

- `resolve_track(project, args, key := "track")`: look up by name through `project.find_by_name`. A name that belongs only to a bus is an error (`"Bus 1" is a bus, not a track`).
- `resolve_channel(project, args, key := "channel")`: look up by name. A folder without a channel is an error.
- `resolve_route_target(project, value) -> int`:
  - `"Master"` → 1.
  - `"None"` → 0.
  - `"Hardware Out"` → 1000, `"Hardware Out N"` → 1000 + N.
  - Anything else is a channel name.
- Every "not found" error lists up to 5 near matches, using the same "did you mean" format as Phase 1 (case-insensitive substring match on existing names).
- Delete the `track_id`/`channel_id` branches and the "Multiple … use id" errors; they can't happen any more.

### 5.2 Schema changes

| Tool | Before | After |
|---|---|---|
| `create_track` | `output_channel_id` | `output` (name) |
| `delete_track` | `track_id` | `delete` with `name` (Phase 2.4) |
| `rename_track` | `track_id`, `name` | `track`, `new_name` (the result shows the final, possibly suffixed, name) |
| `set_track_color` | `track_id` | `track` |
| `set_mixer` | `channel_id` | `channel` |
| `route_channel` | `channel_id`, `output_channel_id` | `channel`, `output` |
| `add_send` | `channel_id`, `target_channel_id` | `channel`, `target` |
| `list_devices` | `channel_id` | `channel` |
| `add_device` | `channel_id`, `parent_instance_id` | `channel`, or just `parent` as a full path |
| `get_device`, `set_device`, `set_device_params`, `load_device_file`, `remove_device`, `move_device` | `instance_id`, `channel_id` | `path` only (`Drums/Drum Machine/KICK`) |
| `create_clip`, `list_clips` | `track_id` | `track` |
| `place_clip`, `read_clip`, `write_clip`, `rename_clip` | `clip`, `clip_id` | `clip` only (clip names are already unique) |
| `create_bus` | output id, if present | `output` |

The data layer still uses device `instance_id`; the model just never sees it. Paths are unambiguous now that channel names are unique and sibling device names already are.

### 5.3 Result text

- `compact_track` / `compact_channel` / `compact_device`: remove `id`, `channel_id` and `instance_id`. A track row shows `channel: "Drums"` only if its channel has a different name, which should be rare.
- `describe_route_target` returns `Master`, `None`, `Hardware Out` or the channel name, never `name (id)`.
- Examples:
  - `Created instrument track "Drums" with Drum Machine, output → Master`
  - `Added 6 pads to Drums/Drum Machine: KICK (36), SNARE (38), …`
  - `Renamed "Bus" → "Drums 2" ("Drums" is taken)`

### 5.4 System prompt

[PromptContext.gd](../Godot/ai/prompt/PromptContext.gd):

- In the Tracks table, remove the `id` column. Keep `channel` only when it differs from the track name.
- In the Mixer table, remove `id`. `route` and `sends` show names.
- `Selection:` becomes ``track `RIDE`; channel `RIDE` ``.

[system_prompt.md](../Godot/ai/prompt/system_prompt.md) (and the user copy in `~/.config/sonara/aichat/system_prompt.md`, which is a *copy* and must be updated or reset by hand):

- Replace "Channel id 1 is Master … Hardware outs are 1000+" with: "Tracks, buses and channels are referenced by their unique name. Route targets: a channel name, `Master`, `None`, or `Hardware Out`."
- Replace "Prefer tools over guessing IDs" with "Don't guess device ids or asset paths; use `search_assets`."
- Update the device addressing line: "Address devices by `path` only."

### 5.5 Tests

- Update `test_device_tools.gd`, `test_tool_results.gd` and the existing clip and mixer tool tests to the new argument names.
- Check that no tool schema mentions `_id` except `device_id` (the registry id of a device *type*, which the model gets from `search_assets`). Write this as a registry-level test that walks `ToolRegistry` schemas.
- Unknown track name → the error lists the near matches.

---

## Verification

1. Run `Godot/tests/run_all.sh`; everything passes.
2. Manually replay city_pop_2 in a new project:
   - `create_track device_id:"drum_machine"` resolves and says so. No stray track is created.
   - Deleting a track from the tracklist removes the mixer strip; undo brings it back with its devices.
   - Asking for a groove with the playhead in the middle of bar 1 on an empty track puts the clip at `1.1.000`.
   - Drawing a range over bars 5–9 and asking for "a fill here" gives a 4-bar clip at bar 5.
3. Open `city_pop_2.sonara`. The duplicate "Drums" loads as "Drums 2", and a warning shows in `Godot/logs/last.log`.
4. Open the rendered system prompt popup: no id columns, and a `Range:` line is present.

## Gotchas

- **The user prompt copy.** `~/.config/sonara/aichat/system_prompt.md` overrides the shipped prompt. Old id-based wording there will contradict the new tool schemas.
- **Old conversations.** Saved chats contain calls with `track_id` and similar. The model may copy that style when a chat is resumed. The error for an unknown argument should name the replacement (`track_id is gone; pass track: "<name>"`). Keep that mapping in `AiTool` for one release.
- **Rename in the middle of a conversation.** Earlier tool results then use stale names. Rename results always show `old → new`, which is enough.
- **The inline name editor.** When a name gets a suffix, the editor must show the final name. Otherwise the user sees "Drums" while the project has "Drums 2".
- **`remove_channel` has side effects that undo doesn't reverse** (rerouting to Master, clearing parents). Phase 2's snapshot has to cover every one of them, or undoing a delete leaves routing silently wrong.
- **Aux returns** are created and renamed by `AuxReturnSync` when pads change. Check that renaming a pad whose name is already taken (`KICK` on a second machine) doesn't loop, with the sync renaming it and the uniquifier renaming it back.
