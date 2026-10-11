# Key changes (scale changes along the timeline) — Plan

Status: **implemented (T-000, E-001→E-006, G-001→G-008, D-001→D-004) — [x?] pending live verification (L-001→L-005, needs the user's engine/Godot).** Written for implementer agents. Follows the repo's spec
format (`docs/specs/_templates/tasks.md`); if the owner wants the full requirements/design split,
promote the "Decisions" section into `design.md`.

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Goal

Today the project has **one** scale (`Project.scale_root` / `scale_type`, spec 026). The engine
gets only its 12-bit pitch-class mask (`/project/scale`, `ProjectSettings.scale_mask`,
`Transport.scale_mask`), and only **Transpose in "Follow Project" mode** reads it (spec 027).

Add **key changes**: a lane in the arranger ruler (next to Markers / Tempo / Time Signature) where
each marker changes the project scale from that point on. Each marker has a dropdown to pick root
and scale type. The engine must know the scale **sample-accurately at every note**, because note
effects use it.

Out of scope for v1 (listed so nobody gold-plates): per-key-region fold/highlight inside the
clip editor, per-clip keys, modulating existing notes when a key changes (REQ-020 of spec 026
still holds: changing a scale never touches notes), DAWproject key export.

## Decisions (made — don't re-litigate without a reason)

| # | Decision | Why |
|---|---|---|
| D1 | **Tick-anchored**, like `TempoMap`/markers, not bar-anchored like `TimeSignatureMap`. | The engine looks up by tick; bar anchoring would force the engine to resolve bars through the time signature map. The UI snaps new/dragged changes to bar lines, so it still *looks* bar-aligned. |
| D2 | The **base key stays `Project.scale_root/scale_type`** (the toolbar `ScalePicker`). Key changes are additional entries at tick ≥ 1. | Old projects, `/project/scale`, the clip editor and every test keep working unchanged. A change at tick 0 is invalid (it would be the base). |
| D3 | New OSC message **`/project/scale_map`**: `(i:tick, i:mask)` pairs, whole map replaced on every edit, empty = clear. Mask `0` is a valid change ("no scale from here"). | Mirrors `/transport/tempo_map` and `/transport/time_signature_map`. The engine never needs root/type, only the mask (as in spec 027). |
| D4 | Engine resolves the scale **per note-on frame**, not per block. `Transport` carries the mask at block start plus a small fixed array of `(frame, mask)` changes inside the block. | `Transport` is built once per block at the start. A note at the exact key-change tick would otherwise get the *old* scale whenever the block started before that tick — audibly wrong in the most common case (a clip with a note on bar 17 beat 1). |
| D5 | In Godot "scale" is overloaded (`GridHelper.scale_changed` = zoom). All new Godot names use **"key change"**: `KeyChangeMap`, `KeyChangeTrack`, `KeyChangeItem`. Engine names use `scale_map`. | Avoids grep and signal confusion. |
| D6 | Clip editor v1 uses the scale in effect **at the start of the bound clip instance** (project base in track mode). | One `ScaleContext` per editor. A key change *inside* a clip is not shown in v1. Documented limitation. |

## Gotchas and risks (read before starting)

### Engine (highest risk)

1. **Audio thread contract** (`AGENTS.md`): no allocation, no locks, no I/O in the callback. The map
   is built in the CommandWorker *off* the state lock and the old one dropped *after* unlock — copy
   `set_time_signature_map` in `command_worker/project.rs` exactly. The callback only does a binary
   search on a slice and writes into a fixed array.
2. **Block-boundary accuracy (D4).** `Transport::at` runs at the start of `process_audio`
   (`processing/mod.rs`, ~line 49) *before* tick events exist. The per-block changes need frames,
   which come from `tick_events: &[(Tick, usize)]`. Note `Transpose::note(…, at)` gets an
   **absolute** sample; the in-block frame is `at - cx.now()` (`NoteCx::now`, `note_fx/host.rs`).
3. **Do not call `apply_transport` twice per block.** Clock-like devices store the snapshot, and
   other devices may not be idempotent. Reorder instead: when playing, collect tick events first,
   fill `transport.scale_changes`, then `apply_transport` once, then handle the `!is_playing`
   early return. Nothing between the current `apply_transport` and tick collection depends on
   devices having the transport (automation runs earlier; in between are only `fill_tick_rates`
   and `take_playhead_midi_dispatch`). Checked against `processing/mod.rs` on 2026-10-11.
4. **Loop wraps make ticks non-monotonic** within a block. Look the mask up per tick event with
   `mask_at(tick)` (binary search); never assume "next change" ordering. Test a loop that wraps
   from a C-major bar back onto a D-minor bar inside one block.
5. **Stopped transport / seek / live MIDI.** Devices see the transport every block even when
   stopped, and Transpose is used by live keyboard input. Mask at the playhead tick must apply
   (seeking to bar 20 then playing the keyboard must follow bar 20's key). Covered for free if
   the block-start mask is looked up at the integer playhead `start_tick` (playing or stopped);
   add a test.
6. **Note-off pairing is already safe** (Transpose records the key it actually started on in the
   sounding table). Still add a test: key changes while a note is held, note-off releases the
   pitch it started on.
7. **Fixed capacity.** More than `MAX_SCALE_CHANGES_PER_BLOCK` (suggest 4) changes inside one
   block is physically implausible (a block is a few ms) but possible with a hostile map. When
   full, **overwrite the last slot** (so the end of the block has the right key; dropping the
   *first* entries instead would make every frame before the kept ones read the stale
   block-start mask). Errors never outlive the block: the next block's start mask comes straight
   from the map. Never grow, never `println!`, no per-tick `warn!` — silently saturate.
8. **`Transport` is `Copy` + `Default`** and is constructed in many tests (`transport.rs`,
   `clock.rs`, `transpose.rs` use struct-update syntax with `..Transport::default()`). An array of
   `(u32, u16)` keeps both derives. **Don't change the `Transport::at` signature** (7 callers,
   mostly tests in `transport.rs` and `clock.rs`): it keeps setting `scale_mask` from
   `settings.scale_mask`, and `process_audio` overrides it with the map lookup right after.
9. **`ClearProject` / `/project/init`.** `clear_project` takes the maps with `std::mem::take`; add
   `scale_map` there or a closed project's key changes leak into the next one. `/project/init`
   rebuilds `ProjectSettings` with `scale_mask: 0` and the base scale arrives separately — the
   key-change map must also be re-sent after init and after reconnect (see Godot task G2).
10. **Offline render / bounce** (`render/worker.rs`) drives the same `process_audio`, so it gets
    key changes for free *if* the map lives on `EngineState`. Do not put it anywhere the render
    snapshot wouldn't see. `AnalyzerConfig` doesn't need it. Add one render test across a key change.
11. **OSC input hardening.** Follow `parse_time_signature_map_args` (in `osc/routes/transport.rs`,
    with its test `parse_time_signature_map_args_filters`): drop malformed pairs, clamp
    `mask & 0x0FFF`, drop `tick < 1`, sort, keep the last of a duplicate tick, cap the count
    (suggest 256 ≈ 2 KB, well under a UDP datagram). The datagram reader is its own thread
    (commit 314423b) — no change needed, but keep the message small.
12. **Rust ↔ Godot catalogue drift.** `note_fx/scale.rs` mirrors `MusicalScale.TYPES`;
    `test_project_scale_sync.gd` guards labels. Key changes reuse masks, so no new table — don't
    add one.

### Godot

13. **Model setter pattern**: UI never sends OSC; the model syncs itself. `Project` already hooks
    `time_signature_map.changed` → `_sync_…_to_engine()` through a setter that reconnects
    signals. Copy that exactly for `key_change_map`, including the reconnect on replace.
14. **Undo**: edits are one `HistoryUtil.record(...)` step via before/after snapshots (see
    `TimeSignatureMapStateCommand`). Dragging must record **once on release**, not per motion.
    The base key still goes through `Editor.set_project_scale` (PropertyCommand).
15. **Drag spam**: while dragging, the map changes every mouse motion → one OSC datagram each
    (same as tempo/time signature today; acceptable, packet is tiny).
16. **Time signature edits move bars.** Because D1 anchors by tick, a time-signature change does
    *not* move key changes — they can end up mid-bar. Accepted; do not try to re-snap.
17. **Persistence**: additive keys with per-key defaults (`from_json`), `FORMAT_VERSION` stays 2.
    Validate every loaded entry with `MusicalScale.is_valid_type(type_id)` and drop the entry if
    it fails. **Not** `MusicalScale.make`: it silently maps an unknown id to `"none"`, so a
    future type id would become a "no scale" change. (`"none"` itself is a valid type, so a
    deliberate "no scale from here" change survives.)
18. **Headless tests** need `-- --test`; sends queue in `AudioEngineOSC._pending_sends` (see
    `test_project_scale_sync.gd`). Run via `Godot/tests/run_all.sh <word>`.
19. **Cargo**: don't run more than 2–3 cargo jobs in parallel (memory: parallel agent limits).
    Engine and Godot phases are independent after Phase 0 and can run as two agents.

---

## Phase 0 — Protocol contract (one agent, 10 min, unblocks both sides)

- [x?] **T-000** Document `/project/scale_map` in `docs/subsystems/osc-protocol.md` next to
  `/project/scale`: `i:tick, i:mask` pairs; replaces the whole map; ticks ≥ 1; mask 12-bit,
  0 = no scale; invalid pairs dropped with a warning; duplicate tick keeps the last; empty clears;
  base scale remains `/project/scale`.
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Verify_: row exists with direction, arg types, semantics.
  - _Depends on_: —

## Phase 1 — Engine: model and message (agent A)

- [x?] **E-001** `ScaleMap` pure type.
  - _Files_: `Engine/src/audio/scale_map.rs` (new), `Engine/src/audio/mod.rs` (`pub mod`)
  - _Output_: `ScaleMap::from_changes(Vec<(i64 tick, u16 mask)>)` (sort, drop `tick < 1`,
    `mask &= 0x0FFF`, last-wins on duplicate tick, cap `MAX_CHANGES`),
    `changes() -> &[(Tick, u16)]`, `mask_at(tick, base_mask) -> u16` (binary search with
    `partition_point`; before the first change → `base_mask`), `is_empty()`. Style: copy
    `time_signature_map.rs` header comment and `valid()`/`from_changes` shape.
  - _Verify_: `cargo test scale_map` — before/at/after a change, base fallback, mask 0 change,
    dedupe, sort, invalid dropped, tick 0 dropped.
  - _Depends on_: —

- [x?] **E-002** Command + OSC route + state.
  - _Files_: `audio/commands/mod.rs` (`AudioCommand::SetScaleMap(Vec<(Tick, u16)>)`; add it to the
    "must be handled by CommandWorker" arm near line ~1283), `audio/command_worker/mod.rs`
    (dispatch), `audio/command_worker/project.rs` (`set_scale_map`: build off-lock, swap under
    lock, drop old after unlock; add to `clear_project`'s `mem::take` tuple),
    `audio/state.rs` (`pub scale_map: ScaleMap`, default), `osc/routes/project.rs` (route
    `["project","scale_map"]` next to `["project","scale"]` + `parse_scale_map_args` with a unit
    test; copy the shape of `parse_time_signature_map_args` in `osc/routes/transport.rs`).
  - _Verify_: `cargo test scale_map parse_scale_map`; sending `oscsend localhost 7000
    /project/scale_map ii 3840 2741` logs "Scale map set: 1 changes" in `logs/last_info.log`.
  - _Depends on_: E-001

- [x?] **E-003** Transport carries the scale timeline.
  - _Files_: `audio/transport.rs`
  - _Output_: `MAX_SCALE_CHANGES_PER_BLOCK`, fields `scale_changes: [(u32, u16); N]`,
    `scale_change_count: u8`; `Transport::at` unchanged (Gotcha 8);
    `fn scale_mask_at_frame(&self, frame: usize) -> u16` (last change with `frame <= f`, else
    `scale_mask`); `fn push_scale_change(&mut self, frame, mask)` (when full, overwrites the last
    slot — Gotcha 7). Keep `Copy + Default`.
  - _Verify_: `cargo test transport` — `scale_mask_at_frame` before/at/after the change frame;
    saturation overwrites the last slot; existing `Transport::at` tests untouched.
  - _Depends on_: E-001

- [x?] **E-004** Fill per-block changes in `process_audio`.
  - _Files_: `audio/processing/mod.rs` (+ a small pure helper in `processing/timeline.rs` so it is
    unit-testable, e.g. `fn scale_changes_in_block(&ScaleMap, base_mask, &[(Tick,usize)], &mut Transport)`)
  - _Output_: per Gotchas 2–5: after `Transport::at`, set
    `transport.scale_mask = state.scale_map.mask_at(start_tick, state.settings.scale_mask)`
    (playing or stopped); collect tick events before the single `apply_transport` when
    playing; walk `tick_events` carrying the running mask, `push_scale_change(frame, mask_at(tick))`
    whenever it differs. Skip the walk entirely when `scale_map.is_empty()`.
    No allocation, no `info!` in the loop.
  - _Verify_: `cargo test` — helper tests: change mid-block at the right frame; change exactly on
    the first tick event; loop wrap from one key into another; empty map is a no-op; existing
    timeline/processing tests unchanged.
  - _Depends on_: E-003

- [x?] **E-005** Transpose follows the per-note scale.
  - _Files_: `audio/devices/note_fx/transpose.rs`
  - _Output_: store the `Transport` (Copy) instead of `project_mask`; in `note()` use
    `transport.scale_mask_at_frame((at - cx.now()) as usize)` for `MODE_FOLLOW`. Custom/Off modes
    unchanged. Check `chord.rs`, `step_sequencer.rs`, `arpeggiator.rs` do **not** read
    `scale_mask` (grep currently shows only Transpose) and leave them alone.
  - _Verify_: `cargo test transpose` — new tests, with a pitch whose snap **differs** between the
    two keys (snap ties go down: B is B in C major but Bb in D minor; C# is C in both, so it
    proves nothing): B at frame 0 stays B under block-start C major; the same note-on at the
    D-minor change frame gives Bb; note held across a change releases
    the pitch it started on; `Follow Project` with no map behaves exactly as before
    (`follow_project_without_a_scale_does_not_snap` still passes).
  - _Depends on_: E-003

- [x?] **E-006** End-to-end engine test and render check.
  - _Files_: `audio/processing/` test module or `audio/render/worker.rs` tests
  - _Output_: a project with Transpose(Follow) on a channel, base C major, key change to D minor
    at bar 3, a clip with a B on bar 2 beat 1 and on bar 3 beat 1 → dispatched pitch is B on
    bar 2 (in C major) and Bb on bar 3 (D minor, tie snaps down). Don't use C#: it snaps to C in
    both keys and can't catch the bug. Identical across block sizes 64/512/2048
    (this is the block-boundary regression test).
  - _Verify_: `cargo test key_change` passes at three block sizes.
  - _Depends on_: E-004, E-005

## Phase 2 — Godot: model, persistence, sync (agent B, parallel with Phase 1)

- [x?] **G-001** `KeyChangeMap` model.
  - _Files_: `Godot/data/KeyChangeMap.gd` (new), `Godot/tests/test_key_change_map.gd` (new)
  - _Output_: `class_name KeyChangeMap extends RefCounted`, `signal changed`; entries
    `{id, tick, root, type_id}` sorted by tick, tick ≥ 1. API mirroring `TimeSignatureMap` /
    `TempoMap`: `add_change(tick, root, type_id) -> id` (same tick edits), `update_change(id, tick,
    root, type_id)` (clamped between neighbours), `remove_change(id)`, `index_of`, `index_at_tick`,
    `scale_at_tick(tick, base_root, base_type) -> MusicalScale`, `snapshot()`/`restore()`,
    `to_json()`/`from_json()` (drop entries failing `MusicalScale.is_valid_type` — Gotcha 17),
    `to_osc_args() -> Array` (flat `[tick, mask, …]`).
  - _Verify_: `Godot/tests/run_all.sh key_change_map` — lookup before/at/after, clamping, dedupe,
    JSON round trip, unknown type dropped, OSC args equal `MusicalScale.make(...).mask()`.
  - _Depends on_: —

- [x?] **G-002** `Project` owns the map and syncs it.
  - _Files_: `Godot/data/Project.gd`, `Godot/tests/test_key_change_sync.gd` (new),
    `Godot/tests/test_scale_persistence.gd`
  - _Output_: `var key_change_map: KeyChangeMap` with the reconnecting setter (copy
    `time_signature_map`, Project.gd ~L74–81 and L163); `_sync_key_change_map_to_engine()` sending
    `/project/scale_map` only when `CONNECTED`; call it in `_on_engine_confirmed_connected` next to
    `_sync_time_signature_map_to_engine()` (~L245). That one site covers first connect,
    reconnect and engine restart (the restart path re-runs `connect_to_engine` → confirm).
    Don't add a call after `_send_scale_to_engine()` in `connect_to_engine` (~L211): the state
    isn't `CONNECTED` yet there, so the guard makes it a no-op. `to_json` key `"key_changes"`, `from_json` default empty (old projects load
    unchanged); `get_scale_at_tick(tick) -> MusicalScale` helper.
  - _Verify_: `run_all.sh key_change` — edit sends one `/project/scale_map` with correct args;
    nothing sent while disconnected; save/load round trip; a project JSON without
    `key_changes` loads with an empty map; `test_scale_persistence` still green.
  - _Depends on_: G-001; T-000 for the address

- [x?] **G-003** Undo command.
  - _Files_: `Godot/history/commands/KeyChangeMapStateCommand.gd` (new; clone of
    `TimeSignatureMapStateCommand`)
  - _Verify_: do/undo/redo restore snapshots (test in `test_key_change_map.gd`).
  - _Depends on_: G-001

## Phase 3 — Godot: ruler lane UI (agent B)

- [x?] **G-004** `KeyChangeItem`: tab at a tick showing e.g. `D Dorian` plus a **▾ arrow button**.
  - _Files_: `Godot/arranger/ruler/KeyChangeItem.gd` (new; start from `TimeSignatureItem.gd`)
  - _Output_: drag along bars (signals `pressed/dragged/released` like the time signature item),
    right-click → `menu_requested`, arrow click → `dropdown_requested(id, global_pos)`. It only
    reports gestures; the track applies them. Double-click is **not** text editing here (opens the
    same dropdown).
  - _Verify_: headless test instantiates the item, calls `set_key(id, root, type_id)`, asserts the
    label (`MusicalScale.display_name()`), min width, and that signals fire.
  - _Depends on_: G-001

- [x?] **G-005** `KeyChangeTrack` lane.
  - _Files_: `Godot/arranger/ruler/KeyChangeTrack.gd` (new; start from `TimeSignatureTrack.gd`)
  - _Output_: `bind_project`, items rebuilt on `key_change_map.changed`, layout from
    `grid_helper.ticks_to_pixels`, add on double-click/right-click→"Add Key Change" at the nearest
    **bar line** (use `time_signature_map.tick_of_bar` + the `_bar_at_x` logic; initial value =
    the scale in effect there), drag snaps to bar lines and clamps between neighbours and to
    **bar 2 at the earliest** (`tick_of_bar(1, …)`; tick 0 is the base key, D2), delete via
    menu, every edit one undo step (record on release). The dropdown is a `PopupPanel` hosting a
    **`ScalePicker`** (root + type, already exists in `Godot/editor/ScalePicker.gd`) → on
    `scale_picked`, `update_change(...)` + record. A start-key chip drawn at x=0 shows the base
    scale and opens the same popup, calling `Sonara.editor.set_project_scale` (so it stays in step
    with the toolbar picker). The track listens to `project.scale_changed` as well as
    `key_change_map.changed`, so the chip follows toolbar edits and undo of the base key; and
    redraws on `time_signature_map.changed` (bar lines move under tick-anchored tabs, Gotcha 16).
  - _Verify_: `run_all.sh key_change_track` — add / edit / move / delete each produce exactly one
    history entry and undo restores; moving past a neighbour clamps; dragging to bar 1 stops at
    bar 2; changing the base scale through `Editor.set_project_scale` updates the chip.
  - _Depends on_: G-002, G-003, G-004

- [x?] **G-006** Mount the lane in the Arranger and persist visibility.
  - _Files_: `Godot/arranger/Arranger.tscn` (node next to `TimeSignatureTrack`, line ~173, plus a
    `KeyToggle` button in `RulerButtons`), `Godot/arranger/Arranger.gd` (mirror every
    `time_signature_*` reference: `@onready` ~L63–64, toggle connect ~L161, save ~L837, visibility
    ~L844, restore ~L886, bind ~L899, unbind ~L967), `Godot/data/Project.gd` (`ruler_lanes` gains
    `"key": false`), `Godot/tests/test_ruler_lanes_persist.gd`.
  - _Verify_: `run_all.sh ruler_lanes` — the key lane flag persists and defaults hidden for old
    projects; hand check: toggle shows the lane, tab lines up with the bar line under the ruler.
  - _Depends on_: G-005

## Phase 4 — Consumers of "the scale at a position"

- [x?] **G-007** Clip editor uses the key at the bound instance (D6).
  - _Files_: `Godot/clip_editor/ClipEditor.gd` (`_refresh_scale_context`, `_bind_project_scale`
    ~L250–290)
  - _Output_: `ctx.scale = p.get_scale_at_tick(bound_clip_instance.start_ticks)` when a single
    instance is bound, project base in track mode. There is an exact precedent:
    `_apply_signature_context()` (~L325) already does "time signature at the bound instance's
    start" and is called from the three places where the binding changes (~L319, ~L405, ~L548).
    Call `_refresh_scale_context()` from the same three places. Also refresh on
    `key_change_map.changed` (disconnect it in `_bind_project_scale` when the project changes, like
    `scale_changed`) and on the bound instance's `position_changed` (`ClipInstance.gd:12`;
    disconnect on rebind). `_sync_scale_toggles` already reads `scale_context.scale`, so the
    fold/snap enablement follows for free.
  - _Verify_: extend `test_scale_ui.gd`: base C major, change to A minor at bar 5, bind an
    instance at bar 5 → context scale is A minor; at bar 1 → C major; editing the map refreshes.
  - _Depends on_: G-002

- [x?] **G-008** Audit other readers (no code expected if grep is clean).
  - _Output_: grep `scale_root|scale_type|get_scale()` outside `clip_editor/` and `Editor.gd`
    (currently none in `Godot/ai/` or `Godot/dawproject/`); confirm `ClipTextKey` is only the
    clip-text header parser. Note in the PR whether DAWproject export/import should mention key
    changes in the transfer report (it does not report the base scale today — leave as is
    unless the owner asks).
  - _Verify_: audit result written in the issue comment.
  - _Depends on_: G-002

## Phase 5 — Docs

- [x?] **D-001** `CONTEXT.md`: add **Key change**, **Key change map**; reword **Project scale** as
  "the key at the start of the project".
- [x?] **D-002** Amend spec 026/027 notes: "the engine only gets the base mask" is now "base mask
  plus a map" (026 `design.md` already carries an amendment box for 027 — add one for this).
  Also fix the stale doc comment on `Editor.set_project_scale` ("UI state only: nothing goes to
  the engine" — untrue since spec 027).
- [x?] **D-003** `docs/subsystems/engine-architecture.md` (Transport snapshot now has a per-block
  scale timeline), `godot-architecture.md` (key lane), `godot-osc.md` if it lists synced models.
- [x?] **D-004** No ADR contradicted (`docs/adr` mentions of "scale" are unrelated: 0005, 0016).
  If the Transport struct change is judged architectural, add a short ADR instead.

## Phase 6 — Live verification (human + agent, makes sound)

Ask first if the user's engine holds port 7000 (memory: live-check environment).

- [x] **L-001** Build both binaries (`Engine/run_release.sh`), open Godot, project in C major,
  Transpose (Follow Project) on an instrument channel, a clip with a repeating chromatic line.
  Add a key change to F# minor at bar 3 via the new lane. Play across it: pitches snap to C major
  before bar 3 and F# minor after, with the **first note on bar 3 already in the new key**.
- [ ] **L-002** Same with a 64-sample buffer and a 2048-sample buffer (AudioConfig) — identical.
- [ ] **L-003** Loop region that straddles the change; seek to after the change while stopped and
  play the virtual keyboard — follows the key at the playhead.
- [ ] **L-004** Save, close, reopen the project: key changes restored and re-sent
  (`logs/last_info.log` shows "Scale map set: N changes"); engine restart while Godot is open
  re-syncs them.
- [x] **L-005** Undo/redo of add, move, edit and delete each reflect in playback.

## Suggested agent split

| Agent | Tasks | Notes |
|---|---|---|
| 1 | T-000, E-001 → E-006 | Rust only; cap cargo at 2 jobs. Commit WIP often. |
| 2 | G-001 → G-003 | Pure GDScript + headless tests. |
| 3 | G-004 → G-007 | After agent 2's G-002/G-003 land (or stub the project API). |
| 4 | D-001 → D-004, G-008 | Last. |
