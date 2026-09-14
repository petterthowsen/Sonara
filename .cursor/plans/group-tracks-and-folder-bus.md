# Group Tracks, Folder Buses, and Nested Mixer Channels

Actionable plan to split today's "group = folder + bus" into three concepts, then use Group as the nesting primitive for multi-out instruments and the drum machine.

## Goal

| Concept | Timeline | Mixer | Audio |
|---|---|---|---|
| **Folder Track** | Organizational folder, no clips, no strip | None | None |
| **Folder Bus** | Same folder, optionally linked to a bus (today's "Group") | Bus strip in the **right pane** | Children **route** to that bus; they stay top-level mixer strips |
| **Group** | Folder-like parent; each child is a real track | Group strip in the **left pane** with a fold-out HBox of child `MixerChannel`s | Children **nest under** the group channel; output **locked** to the parent |

User-created groups, multi-out plugin returns, and drum-machine pad channels all share the same nesting: a channel with child channels, mirrored as nested tracks on the timeline.

Existing projects do **not** need a data migration. Saved "group tracks" are already `TrackType.FOLDER` + `ChannelType.BUS`. After this change they are Folder Buses, which is the same behavior under a new name.

---

## Current state (what we are changing)

- `Track.TrackType.FOLDER` is the only parent type. `Project.place_track()` rejects any other parent.
- `Track.is_group()` means "folder with `default_channel_id >= 0`" (a linked bus).
- `Project.create_group_track()` is an alias of `create_folder_track(name, true)`.
- Timeline context menu **New Group Track** and `TrackCreateCommand` kind `"group"` create that folder+bus pair.
- Folder context menu already has Link to Bus / New Bus / None (`TrackLinkBusCommand`).
- Mixer left `+` creates a **channel-only** instrument strip (no track). Right `+` creates a bus.
- Mixer strips live in two flat `ChannelsBox`es. Reorder is header-slide among siblings, not Godot drag-and-drop.
- `MixerChannel.tscn` already has `HBox { VBox (strip) | Details }`. Details is a separate slide-out; children should be a **third** pane in that HBox.
- Engine mixing already processes route-targets in dependency order regardless of channel type. Child → parent audio works today if we allow routing to a non-BUS channel.
- `Track.is_folder_expanded` is serialized but unused (timeline folders are always expanded).
- `Channel.gd` (~890 lines) and `MixerChannel.gd` (~820 lines) are near the 1000-line cap — new hierarchy/UI must go in new types, not dumped onto those files.

---

## Recommended data model

### Track

Keep `FOLDER`. Add `TrackType.GROUP`.

```
enum TrackType { AUDIO, INSTRUMENT, FOLDER, GROUP }
```

| Helper | Meaning |
|---|---|
| `can_contain_tracks()` | `FOLDER` or `GROUP`, or (later) any track whose channel already has children |
| `is_folder_bus()` | `type == FOLDER` and linked channel exists — **rename** today's `is_group()` |
| `is_group()` | `type == GROUP` |
| `has_clips()` | not `FOLDER` and not `GROUP` |

Group tracks:

- Paired with a `ChannelType.GROUP` mix channel (`pair_mixer_channel`).
- No engine timeline (`connect_to_engine` skips them, same as folders). No clips.
- Height/indent/mute/solo/color behave like a folder that has a volumeter.
- `child_track_ids` / `parent_track_id` / `is_folder_expanded` are reused.

Instrument/audio tracks stay leaf-or-parent **without** changing type. When a drum machine or multi-out plugin later spawns sub-channels, that instrument track gains children via the same `parent_track_id` path. `can_contain_tracks()` must not be hardcoded to `FOLDER` forever.

### Channel

Add an explicit child list. Routing is a consequence of nesting, not the source of truth (routing to a Folder Bus does **not** nest you in the mixer).

```
parent_channel_id: int = -1
child_channel_ids: Array[int] = []   # sibling order in the fold-out
is_children_expanded: bool = true    # mixer fold-out UI state
```

```
enum ChannelType { INSTRUMENT, AUDIO, BUS, GROUP }
```

- `is_bus` stays `channel_type == BUS` (right pane, send targets).
- `is_group_channel` = `channel_type == GROUP` **or** `parent_channel_id >= 0` is not sufficient — a GROUP is the parent mix strip; children keep their own types (`INSTRUMENT` / `AUDIO` / nested `GROUP`).
- `route_locked()` = `parent_channel_id >= 0`. Output is forced to the parent; the output menu is disabled and shows the parent name.
- Signals: `parent_changed`, `child_added`, `child_removed`, `children_reordered` (or one `hierarchy_changed`).

**Do not** infer mixer nesting from `output_channel_id`. Folder Bus children already route to a bus and must remain top-level strips.

### Source of truth and sync

Two trees, kept in sync when both sides exist:

- **Tracks** own arranger order and folder/group containment.
- **Channels** own mixer nesting and locked routing.

`Project` APIs do both in one call:

- Nesting a **track** under a Group also nests its linked channel (if any) and locks route.
- Nesting a **channel** under a Group also nests its linked track (if any) under the group's track.
- Nesting under a Folder / Folder Bus only changes track parent + `sync_track_hierarchy_routing` (today's behavior). Mixer parent stays `-1`.

### Routing rules

Walk ancestors, nearest wins:

1. Nearest **Group** ancestor → lock `output_channel_id` to that group channel.
2. Else nearest **Folder Bus** ancestor → set `output_channel_id` to that bus (unlocked; user can override, re-sync on reparent).
3. Else Master (`1`).

A Group nested inside a Folder Bus: the **group channel** routes to the bus; the group's children stay locked to the group.

Replace `get_enclosing_group_bus()` with:

- `get_enclosing_folder_bus(track) -> Channel`
- `get_enclosing_group_channel(track) -> Channel`

`sync_track_hierarchy_routing` / `sync_subtree_hierarchy_routing` use both. `place_track` already calls subtree sync on parent change — extend it to channel reparent when the new parent is a Group.

### Engine / OSC

Phase 1–4 need **no new OSC addresses**. `/channel/{id}/route` already mixes child → parent. Mixing treats any channel with incoming routes as a route target, so a GROUP strip runs devices after its children (correct for mix-down).

Godot-only changes:

- Output menu: allow routing to `BUS` **and** `GROUP` (not to INSTRUMENT/AUDIO, not to self, not into a descendant — cycle check).
- Locked children skip the menu.
- `/channel/{id}/create` still only sends a name; engine has no channel-type enum. Fine.

Follow-up (not this work): plugin extra outs and drum-pad buffers feeding child channels will need engine device multi-out. See [Phase 5](#phase-5--later-multi-out--drum-machine).

---

## UX

### Create

| Entry point | Action |
|---|---|
| Tracklist empty-area menu **New Folder Track** | Unchanged: `create_folder_track(name, false)` |
| Tracklist menu **New Group Track** | **Change**: `create_group_track()` → `TrackType.GROUP` + `ChannelType.GROUP` |
| Arranger **Add Folder** button | Unchanged: folder, no bus |
| Folder item context menu **Link to Bus** | Unchanged: Folder Bus (`TrackLinkBusCommand`) |
| Mixer left `+` | Become a **MenuButton**: keep "New Instrument Channel" (current channel-only add); add **New Group Track** (same as tracklist) |
| Mixer right `+` | Unchanged: new bus |

### Timeline

- Group headers use the same indent, parent-color border, mute/solo/arm/volumeter path as Folder Buses.
- Drag indent / right-half-of-parent nests into **any** `can_contain_tracks()` parent, not only `FOLDER`.
- Dropping a track into a Group auto-nests its channel and locks output.
- Dropping a track into a Folder Bus only routes (existing).
- Clip placement / move must skip `GROUP` the same way it skips `FOLDER` (`Timeline.gd` currently checks `type == FOLDER` in four places).
- Nested groups: TrackList is already a flattened visual list from `get_visual_track_list()`. Recurse through every `can_contain_tracks()` parent, not only `FOLDER`. Indent pixels already scale with `get_nesting_level()`.

**Collapse:** mixer fold-out is required. Timeline expand/collapse (`is_folder_expanded`) is unused today — implement a chevron on folder **and** group headers in the same UI pass if cheap; otherwise leave always-expanded and file a follow-up. Mixer and timeline expand state stay independent.

### Mixer

`MixerChannel` layout (scene edit via Godot MCP, do not hand-edit `.tscn`):

```
MixerChannel
  HBox
    VBox            # existing strip (header, meter, IO, devices, fader)
    ChildrenSlide   # NEW, hidden until expanded
      Header        # StyleBox tinted with parent channel color
      ChannelsBox   # reuse ChannelsBox for sibling reorder of children
    Details         # existing
```

- Arrow button on the parent header toggles `ChildrenSlide`. Persist `Channel.is_children_expanded`.
- Show the arrow when `channel_type == GROUP` **or** `child_channel_ids` is non-empty (so a later instrument-with-subs gets the same chrome).
- Empty group: fold-out still opens as a drop target.
- Nested `MixerChannel` instances are the same scene — arbitrary depth is just nested HBoxes. Left pane `ScrollContainer` already scrolls horizontally.
- Root left pane lists only channels with `parent_channel_id < 0` and type INSTRUMENT / AUDIO / GROUP. BUS stays right; Master stays pinned.
- Child output menu: disabled, label = parent name.
- Child header tint stays the child's color; the **container** header uses the parent color.

### Drag

**Timeline:** extend existing `TrackDrag` / `_compute_drop_placement`. Replace `type == FOLDER` with `can_contain_tracks()`. On parent change, `place_track` syncs channel nesting.

**Mixer:** two gestures, keep them simple:

1. **Sibling reorder** — keep current header-slide + `ChannelsBox.request_move` (works inside the child `ChannelsBox` too).
2. **Reparent** — Godot DnD on `MixerChannel` (`_get_drag_data` / `_can_drop_data` / `_drop_data`) plus a drop target on the children header/box. Dropping channel A onto group G (or into G's children box) calls `Project.nest_channel(A, G)`. Dropping onto the left-pane empty area (or a non-group strip's gap) un-nests to root.

Do not try to make header-slide also detect "hovering a group" — that fights sibling reorder. Follow `.cursor/rules/godot-drag-and-drop.mdc`; preview + `NOTIFICATION_DRAG_END` like `TrackDrag`.

Cycle / no-ops: cannot nest a group into its own descendant; cannot nest Master; cannot nest a BUS into a group (buses stay right-pane). Dragging a Folder Bus's **child instrument** into a Group **moves** it out of the folder-bus routing into the group (locked). Reverse: dragging a group child out restores Folder Bus or Master routing.

---

## Implementation phases

Each phase should leave the app runnable. Prefer `HistoryUtil.execute` for creates/nests; data setters stay apply + OSC + signal.

### Phase 0 — Rename today's group to Folder Bus

No behavior change. Unblocks the new Group name.

1. `Track.is_group()` → `is_folder_bus()`. Add a temporary `is_group()` that calls `is_folder_bus()` **only until Phase 1**, then switch `is_group()` to `type == GROUP`.
2. Comments / logs / AI copy: "group track" meaning folder+bus → "folder bus".
   - `TrackListContextMenu.gd` comment
   - `Project.create_folder_track` docs
   - `TrackLinkBusCommand` docs
   - `AiTool._track_kind` / `PromptContext._track_kind`: map folder+bus to `"folder_bus"`, reserve `"group"` for the new type
3. Folder context menu tooltip: "Link this folder to a mixer bus (Folder Bus)".

**Files:** `Godot/data/Track.gd`, `Godot/data/Project.gd`, `Godot/history/commands/TrackLinkBusCommand.gd`, `Godot/arranger/tracklist/TrackItemContextMenu.gd`, `Godot/ai/tools/AiTool.gd`, `Godot/ai/prompt/PromptContext.gd`.

### Phase 1 — Data model + create Group Track

1. `Track.TrackType.GROUP`. `can_contain_tracks()`. `is_group()` = `type == GROUP`.
2. `Channel.ChannelType.GROUP`. `parent_channel_id`, `child_channel_ids`, `is_children_expanded`. Serialize in `to_json` / `from_json` with defaults so old projects load.
3. **Extract** channel hierarchy helpers if `Channel.gd` would cross 1000 lines — e.g. methods on `Project` rather than bloating Channel:
   - `Project.nest_channel(child, parent, after_sibling = null)`
   - `Project.unnest_channel(child)` (parent = -1, route to enclosing folder bus or Master)
   - `Project.get_channel_children(ch)`, `channel_is_in_subtree`, `_sync_channel_child_ids`
   - Cycle checks analogous to `track_is_in_subtree`
4. `Project.create_group_track(name)`:
   - Create `ChannelType.GROUP` (default route Master, random color, name sync).
   - Create `TrackType.GROUP`, `pair_mixer_channel`, `add_track`.
   - Do **not** call `create_folder_track(..., true)`.
5. `TrackCreateCommand` kind `"group"` already exists — point `do()` at the new method. Folder + bus stays `kind "folder"` with `folder_with_channel`.
6. `place_track`: parent may be any `can_contain_tracks()` track. After parent change, if new parent is a Group (or an instrument that already has a group-like channel), `nest_channel`; if leaving a Group, `unnest_channel`.
7. `get_track_children` / `_add_track_and_descendants_to_list` / `remove_track` recursive delete: stop requiring `type == FOLDER`; use `can_contain_tracks()` or simply "has children by `parent_track_id`".
8. `connect_to_engine`: skip `GROUP` like `FOLDER`.
9. Load: after `_relink_folder_buses`, rebuild `child_channel_ids` from `parent_channel_id` if the array is empty (tolerate older partial saves).
10. Undo: extend `TrackReorderCommand.capture_layout` with per-track `channel_parent_id` + `output_channel_id` **or** add a sibling `ChannelReorderCommand` and wrap both in `MacroCommand` when a nest changes both trees. Prefer extending the existing snapshot so one undo restores mixer + timeline.

**Files:** `Track.gd`, `Channel.gd`, `Project.gd`, `TrackCreateCommand.gd`, `TrackReorderCommand.gd`, `TrackDeleteCommand.gd` (delete group removes children recursively, same as folder). New: `Godot/history/commands/ChannelNestCommand.gd` if mixer-only nest (no track) needs its own undo.

### Phase 2 — Create / list UI (no fold-out yet)

1. Tracklist context menu: **New Group Track** already wired; verify it hits the new command.
2. Mixer left `AddButton` → `MenuButton` via Godot MCP (`Mixer.tscn`). Popup: "New Instrument Channel", "New Group Track". Right add unchanged.
3. `Mixer._on_channel_added`:
   - `is_master` → right pane hbox (unchanged)
   - `is_bus` → `right_channels`
   - `parent_channel_id >= 0` → **do not** add to a pane (Phase 3 parent will spawn the child UI)
   - else INSTRUMENT / AUDIO / GROUP → `left_channels`
4. Group strips are selectable, named, colored, have devices/sends/fader like a bus, but live on the left.
5. Output menu includes GROUP channels as destinations (for non-locked strips).
6. Record-arm-follows-active: skip `GROUP` like `FOLDER` (`Editor.gd`).
7. AI: `_track_kind` / `_channel_kind` / `list_project` tables show `group` vs `folder` vs `folder_bus`.

At the end of this phase, creating a group gives a left-pane strip + a timeline folder-like track, but children are not nested in the mixer yet.

### Phase 3 — Mixer fold-out + nested MixerChannels

1. New scene `Godot/mixer/MixerChannelChildren.tscn` + script: color header + inner `ChannelsBox` + expand API. Keep `MixerChannel.gd` under 1000 lines.
2. Insert it in `MixerChannel.tscn` `HBox` between `VBox` and `Details` (Godot MCP).
3. Header arrow on the group (and any channel with children). Toggle `channel.is_children_expanded` and `ChildrenSlide.visible`.
4. `MixerChannel.bind_to_channel`: listen to hierarchy signals; spawn/destroy child `MixerChannel` instances inside the inner `ChannelsBox` (preload the same scene). Bind each child with the same `Project`.
5. `Mixer.find_mixer_channel_ui_for_channel`: recurse into children slides. `call_group("mixer_channel")` still works if nested nodes stay in that group.
6. Selection / compact / IO / sends / big-meter toggles: already `call_group` — verify nested strips pick them up.
7. Width: parent `custom_minimum_size.x` must include open children. Nested groups expand further.
8. Default: new groups start **expanded** so the empty drop target is obvious.

### Phase 4 — Drag-to-nest (timeline + mixer)

1. **Timeline** `TrackList.gd`: every `type == FOLDER` used for containment → `can_contain_tracks()`:
   - `_compute_drop_placement` / `_desired_level_after` / `_placement_after`
   - `_collect_subtree_ids` (folder descendants travel with parent — groups too)
2. `Timeline.gd`: clip drop/move skip `GROUP`.
3. `TrackItem.gd`: indent/parent-color already generic; show a group chevron if Phase 0 collapse is in scope.
4. **Mixer DnD**: `MixerChannelDrag` (mirror `TrackDrag`). `_get_drag_data` from header only when not resizing. Groups and the children box accept drops. `Mixer.left_pane` accepts un-nest to root.
5. `ChannelsBox` sibling slide stays for order within the same parent; persist `channel.order` among **siblings** (root left pane and each children box separately). On load, sort roots by `order`, children by `child_channel_ids`.
6. Live preview: timeline already moves items during drag. Mixer can wait for drop (simpler) rather than live-reparenting.
7. History: mixer nest without a linked track → `ChannelNestCommand`. Nest with a track → `TrackReorderCommand` snapshot that includes channel parent/route.

### Phase 5 — later: multi-out + drum machine

- An INSTRUMENT channel may gain `child_channel_ids` without changing `TrackType`. The instrument track `can_contain_tracks()` becomes true; TrackList indent works; MixerChannel already shows a fold-out if children exist.
- **Drum machine:** each pad (or each occupied slot) gets a child AUDIO/INSTRUMENT channel; pad audio is the child's input; child output locked to the drum channel. Pad mixer (volume/pan/fx) is the child strip. Timeline: optional nested tracks under the drum track for per-pad automation; MIDI clips stay on the parent.
- **Multi-out CLAP:** extra plugin outputs → child channels. Same UI. Engine must render extra device buses into those channel buffers **before** the child's own device chain. That is new engine work (`TODO.md` already has "Multi-in and multi-out for devices").
- Creating those children should go through `Project.nest_channel` so undo/UI/routing stay one path.

---

## File checklist

**Data / history**

- `Godot/data/Track.gd` — `GROUP`, `can_contain_tracks()`, rename `is_group`
- `Godot/data/Channel.gd` — `GROUP` type, parent/children fields + JSON; keep file &lt; 1000 lines
- `Godot/data/Project.gd` — create/nest/sync/load (`create_group_track` rewrite is the center)
- `Godot/history/commands/TrackCreateCommand.gd`
- `Godot/history/commands/TrackReorderCommand.gd` (layout snapshot + channel parent/route)
- `Godot/history/commands/TrackLinkBusCommand.gd` (comments + `is_folder_bus`)
- `Godot/history/commands/TrackDeleteCommand.gd`
- **New** `Godot/history/commands/ChannelNestCommand.gd`

**Arranger**

- `Godot/arranger/tracklist/TrackList.gd`
- `Godot/arranger/tracklist/TrackListContextMenu.gd` (comment only)
- `Godot/arranger/tracklist/TrackItem.gd` / `TrackItemContextMenu.gd`
- `Godot/arranger/tracklist/TrackDrag.gd` if subtree collection is FOLDER-only
- `Godot/arranger/timeline/Timeline.gd`
- `Godot/arranger/Arranger.gd` (folder button copy)
- `Godot/editor/Editor.gd` (record-arm skip)

**Mixer** (scenes via Godot MCP)

- `Godot/mixer/Mixer.gd` / `Mixer.tscn` (left MenuButton, pane placement)
- `Godot/mixer/MixerChannel.gd` / `MixerChannel.tscn`
- `Godot/mixer/ChannelsBox.gd` (reuse inside children slide)
- **New** `Godot/mixer/MixerChannelChildren.gd` + `.tscn`
- **New** `Godot/mixer/MixerChannelDrag.gd`
- `Godot/mixer/ChannelContextMenu.gd` — optional "Remove from Group"

**AI / copy**

- `Godot/ai/tools/AiTool.gd`, `Godot/ai/prompt/PromptContext.gd`
- `Godot/ai/prompt/system_prompt.md` — one line: Folder vs Folder Bus vs Group

**Engine**

- None for phases 0–4. Optionally a one-line comment in `Engine/src/audio/mixing.rs` that route targets include group mix channels.

**Do not** hand-edit `.tscn` / `.uid`. Use Godot MCP `scene_*` / `node_*` helpers.

---

## Acceptance tests (manual)

1. **Folder** — New Folder Track; drag instruments in/out; no mixer strip; children keep their outputs (or follow an enclosing Folder Bus).
2. **Folder Bus** — Folder → Link to Bus / New Bus; children appear as **left** strips routing to the **right** bus; unlink restores Master (or outer group).
3. **New Group Track** from tracklist **and** mixer left menu — left-pane group strip + timeline folder-like header; no right-pane bus.
4. **Timeline nest** — drag instrument/audio into the group; child indent; mixer child appears in the fold-out; output menu locked to the group name; engine: child fader then group fader then Master.
5. **Mixer nest** — drag a left-pane strip onto the group / into the children box; same lock + timeline indent.
6. **Un-nest** — drag child out on either view; output returns to Master or enclosing Folder Bus; strip returns to left root.
7. **Nested groups** — group inside group; mixer fold-outs nest; timeline indent +2; no routing cycles; delete parent deletes descendants (same as folder).
8. **Undo/redo** — create group, nest, un-nest, reorder siblings inside the group, delete group.
9. **Save/load** — nested group + Folder Bus in one project; mixer expand state; sibling order.
10. **Old project** — file saved with today's group tracks opens as Folder Buses (right pane), not as the new Group.
11. **Clips** — cannot drop MIDI/audio onto a Group or Folder header; children accept clips as usual.
12. **Sends** — still target BUS only; group is a route destination, not a send destination (unless we later allow it).

---

## Risks / decisions locked by this plan

- **Group ≠ Bus.** Buses stay a routing utility in the right pane. Groups are track-scoped mix parents in the left pane. Do not reuse `ChannelType.BUS` for groups.
- **Lock output only for Group children.** Folder Bus auto-routes but does not hide the output menu.
- **Channel tree is independent** so mixer-only instrument channels (left `+`) can still join a group without inventing a track. If a track exists, both trees stay aligned.
- **No engine multi-out in this work.** Group is mix-down (children into parent). Plugin extra-out split is Phase 5 and a different buffer graph.
- **TrackList nesting is generalized now**, not bolted on later. That is the answer to "not sure about Timeline TrackList": flatten via existing `get_visual_track_list()`, allow non-folder parents, keep indent-by-level. Deep nesting is the same code path as one level.

## Out of scope

- Timeline folder/group collapse (unless done opportunistically in Phase 4)
- Sends to groups
- Auto-creating child channels from drum pads or CLAP extra outs
- Converting an existing Folder Bus into a Group (user can create a Group and drag tracks)
- Mixer-only group without a timeline track (create path always makes both; channel-only **children** are allowed)
