# Sampler Multisample — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Order: Phase 1 (views) works on its own and can ship first. Phase 2 (engine) and Phase 3 (Godot
model) only share the OSC contract in design.md, so they can run in parallel, with at most 2–3
cargo-building agents at once. Phase 4 needs both. Run `cargo test` from `Engine/` after each
engine task and `Godot/tests/run_all.sh sampler` after each Godot task.

## Phase 1 — Window and Companion views

- [x?] **T-001** [REQ-003] Extract `SampleDisplayBinder` from `SamplerDefaultView`: source
  binding, `_update_waveform`, playhead subscription and point-drag commits. No behaviour change.
  - _Files_: `Godot/devices/builtin/sampler/SampleDisplayBinder.gd` (new),
    `Godot/devices/builtin/SamplerDefaultView.gd`
  - _Output_: `SamplerDefaultView` uses the binder. The view's public test hooks
    (`apply_playheads`, `display`) still work.
  - _Verify_: `Godot/tests/run_all.sh sampler waveform device_presets device_drop` all pass
    unchanged.
  - _Depends on_: —

- [x?] **T-002** [REQ-002] Companion view: `@export var show_display := true` on
  `SamplerDefaultView`, a `SamplerCompanionView.tscn` with it off, registered in
  `BUILTIN_COMPANION_SCENES`.
  - _Files_: `Godot/devices/builtin/SamplerDefaultView.gd`,
    `Godot/devices/builtin/SamplerCompanionView.tscn` (new), `Godot/devices/DeviceViewFactory.gd`
  - _Output_: the factory creates a Sampler Companion view with every Panel control and no
    display.
  - _Verify_: new cases in `Godot/tests/test_sampler_view.gd`: the factory returns a Companion
    view, its knob/segment/check names equal the Panel's, and `display == null` (or hidden).
  - _Depends on_: T-001

- [x?] **T-003** [REQ-001, REQ-003] Window view: `SamplerWindowView.gd/.tscn` with a
  `SampleDisplay` filling the view through the binder, registered in `BUILTIN_WINDOW_SCENES`.
  - _Files_: `Godot/devices/builtin/SamplerWindowView.gd` / `.tscn` (new),
    `Godot/devices/DeviceViewFactory.gd`
  - _Output_: the Sampler can open in a device frame showing the waveform.
  - _Verify_: `test_sampler_view.gd`: the factory returns a Window view, and a simulated Start
    drag on its display changes the parameter that the Companion view's knob shows.
  - _Depends on_: T-001

- [x] **T-004** [REQ-001–003] Live check of Phase 1.
  - _Files_: —
  - _Output_: Phase 1 confirmed in the running app.
  - _Verify_: with the engine and Godot running, open a Sampler's window from the device lane.
    The frame shows a waveform at frame size and the panel switches to the Companion view.
    Dragging Start in the frame moves the panel's display region. Playheads show in the frame
    while notes play. Closing the frame restores the Panel view.
  - _Depends on_: T-002, T-003

## Phase 2 — Engine

- [x?] **T-005** [NF compatibility] Record a single-mode render fixture *before* the refactor:
  render a fixed note sequence through today's Sampler (loop on, reverse, filter, pitch change
  mid-note) and store the hash/RMS per block in a test.
  - _Files_: `Engine/src/audio/devices/sampler.rs` (`mod tests`)
  - _Output_: `single_mode_unchanged_through_zone_path` test, green on today's code.
  - _Verify_: `cargo test single_mode_unchanged` passes before T-007 starts.
  - _Depends on_: —

- [x?] **T-006** [REQ-016, REQ-030–032] `sampler_zones.rs`: `ZoneRanges`, `fade_gain`,
  `ZoneGroup` + `PlayMode`, `select_zones` (match → mute/solo → All/RR/Random into a reserved
  `Vec<u16>`), `velocity_to_midi`, xorshift helper.
  - _Files_: `Engine/src/audio/devices/sampler_zones.rs` (new), `Engine/src/audio/devices/mod.rs`
  - _Output_: pure module with unit tests.
  - _Verify_: `cargo test sampler_zones`:
    - `fade_gain_edges` (≈0.707 for the REQ-030 example)
    - `select_matches_key_and_velocity`
    - `mute_and_solo_filter`
    - `round_robin_cycles`
    - `random_never_repeats_and_covers_all`
    - `select_does_not_allocate`
  - _Depends on_: —

- [x?] **T-007** [NF compatibility] Introduce `Zone` and run single-sample mode through it:
  `single: Zone` rebuilt from `Params` (`refresh_single_zone`); `Voice.zone`; `RenderCtx`,
  `render_active_voices`, `read_voice`, `refresh_pitch` and `increment_for` read the voice's
  zone; `set_sample` fills `single`.
  - _Files_: `Engine/src/audio/devices/sampler.rs`
  - _Output_: same behaviour, new structure.
  - _Verify_: `cargo test sampler` all green, including the T-005 fixture and the `factory.rs`
    sampler conformance case. `cargo test drum_machine` is green.
  - _Depends on_: T-005

- [x?] **T-008** [REQ-016–019, REQ-030–032] Multisample state and playback: `multisample` flag,
  `zones`, `groups`, `any_solo`, `match_scratch`, `rng`. Methods `set_multisample` (reserve or
  clear, kill voices), `set_zone`, `remove_zone` (kill + `swap_remove` + remap), `set_zone_group`,
  `remove_zone_group`. Multisample `note_on` (one voice per selected zone; gain = volume × vel
  amount × zone × group × fades; forced key track from the zone root). `Voice.trigger` and the
  note-off that releases all stacked voices.
  - _Files_: `Engine/src/audio/devices/sampler.rs`
  - _Output_: a multisample Sampler playable from unit tests.
  - _Verify_: `cargo test sampler`:
    - `multisample_plays_matching_zone_only`
    - `zone_root_key_tracks_regardless_of_param`
    - `device_tune_ignored_in_multisample`
    - `note_off_releases_all_stacked_voices`
    - `voices_cap_counts_zone_voices`
    - `remove_zone_remaps_voices`
    - `mode_switch_kills_voices`
    - 512-zone × 64-note-on timing guard
  - _Depends on_: T-006, T-007

- [x?] **T-009** [REQ-024, REQ-028] Zone loading and focus: `begin_zone_load`, `set_zone_sample`
  (stale `req_id` / unknown zone ignored), `fail_zone_load`, `set_focus`, and a `playheads_payload`
  that reports only focused-zone voices normalized over that zone. Log total zone PCM MB after
  each load.
  - _Files_: `Engine/src/audio/devices/sampler.rs`
  - _Output_: per-zone PCM and loading state.
  - _Verify_: `cargo test sampler`: `stale_zone_load_ignored`, `playheads_only_focused_zone`,
    and `failed_zone_is_silent_others_play`.
  - _Depends on_: T-008

- [x?] **T-010** [REQ-016–032] Commands and status: new `AudioCommand` variants, the
  `with_sampler` helper, `zone_id: Option<u32>` on `BeginLoadDeviceSample` / `LoadDeviceSample` /
  `FailDeviceSampleLoad`, `EngineStatus::SamplerZoneLoadingState`, zone states re-sent on
  `state/get`, and `AuditionDevice`.
  - _Files_: `Engine/src/audio/commands.rs`
  - _Output_: every sampler method reachable by command.
  - _Verify_: `cargo test commands` plus a new `sampler_zone_commands_route_to_device` test
    (set zone, load sample with zone id, audition → voice active).
  - _Depends on_: T-009

- [x?] **T-011** [REQ-016–032, REQ-043] OSC: `handle_device_message` arms for `multisample`,
  `zone/{zid}/set|load_file|remove`, `zone_group/{gid}/set|remove`, `focus_zone` and
  `audition`. `PendingDevice.zone_id`, `begin_device_sample_load(.., zone_id)`,
  `handle_afs_event` forwarding, and status → `{device}/zone/{zid}/loading_state`.
  - _Files_: `Engine/src/osc/server.rs`
  - _Output_: the protocol in design.md, end to end.
  - _Verify_: `cargo test zone_osc` (19-arg parse, clamping and ordering, short args rejected).
    Then an OSC smoke test with the engine running (`./run_release.sh`) and `oscsend`: add a
    Sampler, `multisample 1`, two `zone/*/set` + `zone/*/load_file` on different keys, play notes
    via `/channel/{id}/midi_event` and hear the right file per key. `Engine/logs/last_info.log`
    shows both zone loads ready.
  - _Status_: unit tests pass. OSC smoke test done (2026-10-06): two sine zones (0–59, 60–127)
    loaded `loading` → `ready` over `zone/{zid}/loading_state`, `state/get` re-sent both, notes
    in each range sounded, and `"playheads"` only listed the focused zone's voices. Not yet
    checked by ear that each key range plays its own file.
  - _Depends on_: T-010

- [x?] **T-012** [all engine] `cargo fmt`, full `cargo test`, `cargo build --release`.
  - _Files_: —
  - _Output_: a clean engine tree.
  - _Verify_: all three commands succeed with no new warnings in the touched files.
  - _Depends on_: T-011

## Phase 3 — Godot model and logic

- [x?] **T-013** [REQ-025, REQ-027, REQ-031, REQ-032] `SamplerZone`, `SamplerZoneGroup` and
  `SamplerMultisample`: data, signals, setters sending OSC through the owner's `osc_addr`,
  `to_json`/`from_json`, `sync_to_engine`, `to_osc_args` matching the 19-arg layout.
  - _Files_: `Godot/data/SamplerZone.gd`, `Godot/data/SamplerZoneGroup.gd`,
    `Godot/data/SamplerMultisample.gd` (new)
  - _Output_: a self-synchronizing model (ADR 0006).
  - _Verify_: `Godot/tests/test_sampler_multisample.gd`: setters emit signals and produce the
    expected OSC (captured), JSON round-trip, and deleting a group moves its zones to Ungrouped.
  - _Depends on_: — (contract from design.md)

- [x?] **T-014** [REQ-027, REQ-028] `DeviceInstance` and `Project` integration: `multisample` var,
  JSON (omitted when unused), `sync_to_engine()` hook after the params, `load_file()` delegation
  in multisample mode, `audition()`, zone `loading_state` routing, and
  `Project.track_source_request` + `_waveform_for_req` lookup. Zone loads use the waveform retry.
  - _Files_: `Godot/data/DeviceInstance.gd`, `Godot/data/Project.gd`, `Godot/data/SamplerZone.gd`
  - _Output_: zones persist in projects and presets, and waveforms arrive per zone.
  - _Verify_: `test_sampler_multisample.gd`: preset round-trip, an old project without the key
    loads single-mode, `/audiofile/waveform/ready` for a zone `req_id` fills that zone's source,
    and `failed:…` marks the zone missing. `Godot/tests/run_all.sh device_presets dawproject`
    still pass.
  - _Depends on_: T-013

- [x?] **T-015** [REQ-026] Snapshot undo: `snapshot()`, `restore()` diffing by zone id (set only
  for changed zones, remove for gone ones, load + set for new or re-pathed ones), and the
  single-zone snapshot for mergeable knob edits.
  - _Files_: `Godot/data/SamplerMultisample.gd`
  - _Output_: undoable model edits.
  - _Verify_: `test_sampler_multisample.gd`: `restore` sends only the changed zone's `set`, and
    undo/redo of add, move and remove restores the exact JSON.
  - _Depends on_: T-013

- [x?] **T-016** [REQ-020, REQ-047] `ZoneLayout`: `parse_root`, `layout` (halfway, consecutive
  fallback, mixed, `at_key`), `assign_velocity`, `assign_note`, `distribute_velocity`,
  `distribute_notes` (stretch/gaps), `set_root_from_name`.
  - _Files_: `Godot/devices/builtin/sampler/ZoneLayout.gd` (new)
  - _Output_: pure functions.
  - _Verify_: `Godot/tests/test_sampler_zone_layout.gd`:
    - all REQ-020 name forms, and `kick` → −1
    - REQ-020 example ranges
    - fallback and mixed layouts
    - REQ-047 example (1–32, 33–64, 65–96, 97–127)
    - uneven splits, and more zones than steps
  - _Depends on_: —

- [x?] **T-017** [REQ-011–015, REQ-047] `SamplerActions` (drop, convert both ways, batch, delete,
  move to group: one undo step each) and `DeviceDropUtil` accepting `Array` of audio assets for a
  Sampler.
  - _Files_: `Godot/devices/builtin/sampler/SamplerActions.gd` (new),
    `Godot/devices/DeviceDropUtil.gd`
  - _Output_: every mode transition and batch operation as one command.
  - _Verify_:
    - `test_sampler_multisample.gd`:
      - REQ-011 replace
      - REQ-012 keeps the old sample as a zone with its loop points
      - REQ-013 and REQ-014 copy the values in both directions
      - REQ-015 adds at the key
      - one undo per action
    - `test_device_drop.gd`: new `Array[Asset]` case.
  - _Depends on_: T-014, T-015, T-016

## Phase 4 — Godot UI

- [x?] **T-018** [REQ-010, REQ-021] `SampleDisplay`: `title` with `title_clicked`, an optional
  placeholder action button with `placeholder_action_pressed`, and `_can_drop_data` /
  `_drop_data` for `Asset` / `Array` emitting `assets_dropped`.
  - _Files_: `Godot/devices/builtin/sampler/SampleDisplay.gd`
  - _Output_: a display that still knows nothing about `DeviceInstance`.
  - _Verify_: `test_sampler_view.gd`: title hit-test emits, the button shows only with a
    placeholder, and a drop emits the assets. Existing SampleDisplay cases are unchanged.
  - _Depends on_: T-001

- [x?] **T-019** [REQ-010, REQ-013, REQ-014, REQ-017, REQ-021, REQ-022] `SamplerDefaultView`
  in multisample mode:
  - the display follows the focused zone (source, title, points)
  - `ZONE_FIELDS` retargets Root/Tune/Fine/Reverse/Loop Mode/Crossfade with mergeable undo
  - "Sample" badge on those controls, Key Track hidden
  - title → zone focus menu (`ContextMenuList`)
  - the display context menu converts the mode
  - the placeholder button runs "Create Multisample"
  - `assets_dropped` → `SamplerActions.drop_files`
  - _Files_: `Godot/devices/builtin/SamplerDefaultView.gd`,
    `Godot/devices/builtin/sampler/SampleDisplayBinder.gd`
  - _Output_: the Panel and Companion views work in both modes.
  - _Verify_: `test_sampler_view.gd`:
    - focusing a zone changes the Root knob and the display title
    - turning Root edits only the focused zone
    - the focus menu lists zones by root
    - the placeholder button converts (REQ-010)
  - _Depends on_: T-017, T-018

- [x?] **T-020** [REQ-023] `ZoneStrip`, shown in the Companion view's display slot in multisample
  mode.
  - _Files_: `Godot/devices/builtin/sampler/ZoneStrip.gd` (new),
    `Godot/devices/builtin/SamplerDefaultView.gd`
  - _Output_: the focused zone's name, group, ranges, gain and fades are editable from the
    Companion view.
  - _Verify_: `test_sampler_view.gd`: the strip shows only in Companion + multisample, and an
    edit changes the zone and records one undo step.
  - _Depends on_: T-019

- [x?] **T-021** [REQ-040, REQ-041, REQ-025, REQ-031, REQ-032] `MultisampleEditor` (layout,
  selection, visible groups) and `ZoneGroupBar` (click/Ctrl-click filter, M/S toggles, right-click
  rename/delete/play mode/gain, "+").
  - _Files_: `Godot/devices/builtin/sampler/MultisampleEditor.gd`,
    `Godot/devices/builtin/sampler/ZoneGroupBar.gd` (new), `Godot/devices/builtin/SamplerWindowView.gd`
  - _Output_: an editor shell in the Window view, hidden in single mode.
  - _Verify_: `Godot/tests/test_sampler_zone_map.gd`:
    - filter click vs Ctrl-click
    - M/S reach the model
    - the editor is hidden in single mode and shown after converting
  - _Depends on_: T-017, T-003

- [x?] **T-022** [REQ-042, REQ-048] `ZoneList`: search, `SELECT_MULTI` selection shared with the
  editor, focus on click, missing zones dimmed with a tooltip, Delete / Ctrl+A.
  - _Files_: `Godot/devices/builtin/sampler/ZoneList.gd` (new)
  - _Output_: a working sample list.
  - _Verify_: `test_sampler_zone_map.gd`: the search filters case-insensitively, a shift-range
    selection shows in the editor's `selected_ids`, and Delete removes the zones in one undo.
  - _Depends on_: T-021

- [x?] **T-023** [REQ-043, REQ-044] `ZoneMap` drawing and hit testing: grid, rects, colors,
  rotated clipped labels, key strip, and the `zones_at` / `edge_at` helpers.
  - _Files_: `Godot/devices/builtin/sampler/ZoneMap.gd` (new)
  - _Output_: the map renders zones.
  - _Verify_: `test_sampler_zone_map.gd`: `zones_at` returns stacked zones, `edge_at` finds the
    edges, the label-rotation decision is correct, and key strip velocity rises with height.
  - _Depends on_: T-021

- [x?] **T-024** [REQ-043, REQ-045, REQ-046, REQ-015, REQ-048] `ZoneMap` interaction: select with
  Ctrl/Shift, click cycling, move and resize drags (one undo), resize cursors, a right-click menu
  listing the zones under the pointer, key-strip audition with release on mouse-up, file drops
  at the key under the pointer, Delete / Ctrl+A.
  - _Files_: `Godot/devices/builtin/sampler/ZoneMap.gd`
  - _Output_: an interactive map.
  - _Verify_: `test_sampler_zone_map.gd`:
    - three clicks cycle three stacked zones
    - a resize stops at a one-key range
    - a two-zone move shifts both by the same amount
    - one undo per drag
    - a drop at F3 places the zones from F3
    - key-strip press/release calls `audition` on and off
  - _Depends on_: T-023

- [x?] **T-025** [REQ-047] `ZoneBatchMenu` and `ZoneBatchDialog`, wired into the map and list
  context menus.
  - _Files_: `Godot/devices/builtin/sampler/ZoneBatchMenu.gd`,
    `Godot/devices/builtin/sampler/ZoneBatchDialog.gd` (new),
    `Godot/devices/builtin/sampler/ZoneMap.gd`, `Godot/devices/builtin/sampler/ZoneList.gd`
  - _Output_: every batch operation is reachable from both menus.
  - _Verify_: `test_sampler_zone_map.gd`: the menu items match REQ-047 and use `ContextMenuList`,
    and applying the dialog for "Distribute on velocity" on four zones gives the REQ-047 example
    in one undo.
  - _Depends on_: T-024, T-022
  - _Status_ (Phase 4, 2026-10-06): `Godot/tests/run_all.sh sampler` is green, including the new
    `test_sampler_zone_map.gd` (94 assertions) and the spec 023 cases in `test_sampler_view.gd`.
    The full suite passes except three tests that also fail on the base commit
    (`test_clip_editor_track_list`, `test_timeline_erase_drag`, `test_value_controls`). The editor
    pieces are scenes: `MultisampleEditor.tscn`, `ZoneGroupBar.tscn` + `ZoneGroupChip.tscn`,
    `ZoneList.tscn`, `ZoneStrip.tscn`, `ZoneBatchDialog.tscn`, and `SamplerWindowView.tscn` (a
    `VSplitContainer` of editor and display). The batch menu is a `PopupMenu` node in the editor
    scene. Choices beyond the design: the binder owns the focus menu, the "Convert to …"
    right-click menu, drops and the placeholder button, so the Panel and Window views share
    them. `SamplerActions.begin_edit` / `end_edit` record zone drags and the group gain popup as
    one step each. The batch dialog uses the `ContextMenu` `PopupPanel` variation (`PrimaryPanel`
    is a `PanelContainer` type). Not yet seen in the running app.

## Phase 5 — Docs

- [ ] **T-026** [all OSC] `osc-protocol.md`: every new address, zone `loading_state`, Sampler
  section (modes, selection, groups, playheads in multisample mode).
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: the protocol documented.
  - _Verify_: every address in design.md's tables appears with arguments and direction.
  - _Depends on_: T-011

- [ ] **T-027** [all] `godot-device-views.md` Sampler section (Window/Companion views, editor,
  binder), `CONTEXT.md` glossary (Multisample mode, Zone, Zone group, Focused zone), and the
  `AGENTS.md` built-ins line.
  - _Files_: `docs/subsystems/godot-device-views.md`, `CONTEXT.md`, `AGENTS.md`
  - _Output_: docs match the code.
  - _Verify_: each new file in design.md's Godot tables is mentioned, and the glossary terms
    match requirements.md.
  - _Depends on_: T-025

- [ ] **T-028** [REQ-017] ADR 0017 "Sampler zones are device state, not parameters" (real-unit
  snapshots, not automatable, relation to 0005 and 0011, groups as the future routing unit).
  - _Files_: `docs/adr/0017-sampler-zones-are-device-state.md` (new)
  - _Output_: the decision recorded.
  - _Verify_: the ADR follows the format of 0016 and is linked from design.md's Context.
  - _Depends on_: T-013

## Phase 6 — Live verification

- [ ] **T-029** [REQ-all] Verify live with the engine and Godot running.
  - _Files_: `TODO.md`, `STATUS.md`
  - _Output_: the `TODO.md` entry marked `[x]` (or `[/]` with the gaps), and `STATUS.md` notes
    what was and wasn't checked.
  - _Verify_:
    1. Drop `Piano_C3/E3/G#3.wav` on an empty Sampler: three zones with roots and ranges as in
       REQ-020, each key range plays its file.
    2. Drop three more on a single-sample Sampler: four zones, and the old one keeps its loop.
    3. Two velocity layers: soft and hard hits switch files. Add a velocity fade and the
       transition blends.
    4. Round-robin group of three on C3: hits rotate. Random never repeats. Solo and mute
       behave.
    5. Window view: drag and resize zones while holding notes, with no clicks and no new
       entries in `Engine/logs/last_warn.log`. Playheads show for the focused zone only. The
       piano strip plays louder higher up.
    6. Panel view: the title menu changes focus and the Root knob follows.
    7. Batch "Distribute on notes" on 12 zones, then undo.
    8. Save, reopen, save as preset, load the preset: identical.
    9. Rename one sample file on disk and reopen: that zone shows missing and the rest play.
    10. A project from before this spec loads unchanged.
  - _Depends on_: T-004, T-012, T-025, T-026, T-027, T-028
