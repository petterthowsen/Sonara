# MIDI Send — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine tests run from `Engine/`. Build-heavy work runs one agent at a time with
`CARGO_BUILD_JOBS=2`. Godot tests run with `Godot/tests/run_all.sh <word>`.

## Phase 1 — engine: device and pre-pass, end to end

- [x?] **T-001** [REQ-004, REQ-006, REQ-009] Create `MidiSend` in `note_fx/midi_send.rs`. It has a
  Thru parameter (id 0, bool, default on), a sorted input queue, a sounding table (input id →
  output id from `next_generated_id(is_clip_note(..))`, key), an outbox of notes and CC, and
  requested and effective target arrays (`MAX_TARGETS = 64`). It implements `process_notes` (outbox
  always; downstream gets the original events only with Thru) and `send_cc` (outbox). Add
  `AudioDevice::as_midi_send_mut` (default `None`), forward it in `ModulatedDevice`, and register
  the device in `NOTE_EFFECT_IDS` and `create_note_effect`.
  - _Files_: `Engine/src/audio/devices/note_fx/midi_send.rs`, `.../note_fx/mod.rs`,
    `Engine/src/audio/devices/device.rs`, `Engine/src/audio/modulation/host.rs`,
    `Engine/src/audio/devices/factory.rs`
  - _Output_: `sonara.builtin.midi_send` is created by the factory and passes conformance
  - _Verify_: `cargo test note_fx` passes, including conformance and the new
    `forwards_with_new_ids_and_paired_offs`, `thru_passes_original_downstream`,
    `consume_passes_nothing_downstream` and `cc_goes_to_outbox`
  - _Depends on_: —

- [x?] **T-002** [REQ-008, REQ-014] Add `mixing/midi_send.rs` with `MidiSendOrder` and
  `rebuild_midi_sends(state)`. It scans the top-level chains, drops invalid ids (self, `1`,
  ≥ 1000, missing), adds edges in a fixed order, skips edges that would close a loop, writes the
  effective targets into each device, puts the senders in topological order, and returns the old
  order plus the `blocked` sets. Add `EngineState::midi_sends`.
  - _Files_: `Engine/src/audio/mixing/midi_send.rs`, `Engine/src/audio/mixing/mod.rs`,
    `Engine/src/audio/state.rs`
  - _Output_: a deterministic sender order and effective targets from any project
  - _Verify_: `cargo test midi_send` passes `invalid_targets_dropped` and `loop_edge_is_blocked`
  - _Depends on_: T-001

- [x?] **T-003** [REQ-005, REQ-013] Add the pre-pass. `midi_send::forward` runs first in
  `mix_and_output`: for each sender in order it calls `dispatch_notes`, sets `notes_dispatched`,
  copies each send's outbox into `RenderScratch::midi_forward`, and delivers to enabled effective
  targets with `send_note_event_to_devices` (CC through `route_cc`). Guard both `dispatch_notes`
  call sites in `chain.rs`. Clear the flag at the end of `mix_and_output`.
  - _Files_: `Engine/src/audio/mixing/midi_send.rs`, `Engine/src/audio/mixing/mod.rs`,
    `Engine/src/audio/channel/mod.rs`, `Engine/src/audio/channel/chain.rs`,
    `Engine/src/audio/render_scratch.rs`
  - _Output_: forwarded notes sound on targets in the same block
  - _Verify_: `cargo test midi_send` passes `forwarded_clip_matches_direct_clip`,
    `chain_of_sends_same_block` and `pool_output_matches_single_thread_with_sends`; the full
    `cargo test` is still green
  - _Depends on_: T-002

- [x?] **T-004** [REQ-008, REQ-014, REQ-017] Wire the OSC end to end. Add
  `AudioCommand::SetMidiSendTargets` with `commands/device.rs::set_midi_send_targets` (store,
  rebuild), the `["midi_send", "targets"]` route, `EngineStatus::MidiSendBlocked` and its encoding.
  Call `rebuild_midi_sends` next to every `rebuild_taps` call (`InitProject`, `CreateChannel`,
  device move, add, remove, clear, `remove_channel`, project load), and drop the old order after
  unlock.
  - _Files_: `Engine/src/audio/commands/mod.rs`, `Engine/src/audio/commands/device.rs`,
    `Engine/src/audio/commands/status.rs`, `Engine/src/osc/routes/device.rs`,
    `Engine/src/osc/encode.rs`, `Engine/src/audio/command_worker/devices.rs`,
    `Engine/src/audio/command_worker/project.rs`
  - _Output_: `oscsend localhost 7000 /channel/2/device/0/midi_send/targets ii 3 4` changes the
    targets
  - _Verify_: `cargo test` passes a route test for the address and
    `set_targets_closing_loop_emits_blocked`
  - _Depends on_: T-003

## Phase 2 — engine: no stuck notes

- [x?] **T-005** [REQ-010] Release notes on every path that removes a target. A target dropped from
  the list gets offs under the lock (`release_send_targets`). A removed or cleared send, or a
  removed sender channel, releases all its targets before removal. Bypass emits offs into the
  outbox on the next note phase.
  - _Files_: `Engine/src/audio/devices/note_fx/midi_send.rs`, `Engine/src/audio/mixing/midi_send.rs`,
    `Engine/src/audio/commands/device.rs`, `Engine/src/audio/command_worker/devices.rs`,
    `Engine/src/audio/command_worker/project.rs`
  - _Output_: no hanging notes after any REQ-010 trigger
  - _Verify_: `cargo test midi_send` passes `retarget_releases_removed_targets`,
    `removing_send_or_sender_releases_targets` and `bypass_releases_sounding_into_outbox`
  - _Depends on_: T-004

- [x?] **T-006** [REQ-011, REQ-012] Handle the transport and several sources. `note_discontinuity`
  releases clip-origin entries; loop wraps propagate through the sender's `release_clip_notes_at`.
  Confirm that same-key notes from two sources are independent on a PolySynth target. When a table
  is full, new note-ons are dropped (logged at most once a second) and note-offs never are.
  - _Files_: `Engine/src/audio/devices/note_fx/midi_send.rs`, `Engine/src/audio/mixing/midi_send.rs`
  - _Output_: stop, jump and loop wrap behave like the target's own clip notes
  - _Verify_: `cargo test midi_send` passes `discontinuity_releases_clip_origin_only`,
    `loop_wrap_releases_on_target`, `same_key_from_two_sources_is_independent` and
    `full_tables_drop_ons_never_offs`
  - _Depends on_: T-005

- [x?] **T-007** [REQ-002, REQ-003, REQ-004] Cover bus channels and nested sends. Test that a clip on
  a bus-channel track reaches its chain. Test that a bus with only audio effects is silent and logs
  no WARN. Make `add_device` refuse a MIDI Send at a nested path, with a warning.
  - _Files_: `Engine/src/audio/processing/clip_midi.rs`, `Engine/src/audio/mixing/midi_send.rs`,
    `Engine/src/audio/command_worker/devices.rs`
  - _Output_: group playback works in the engine, and nested sends are refused
  - _Verify_: `cargo test` passes `clip_on_bus_channel_reaches_its_chain`,
    `bus_without_note_device_is_silent` and `nested_midi_send_is_refused`; `cargo fmt` is clean
  - _Depends on_: T-004

## Phase 3 — Godot

- [x?] **T-008** [REQ-001, REQ-002, REQ-016] Let group tracks hold MIDI clips. `has_clips()` becomes
  true for `GROUP`; add `accepts_audio_clips()`; `connect_to_engine()` connects groups. Review every
  `has_clips()` call site listed in the design, so arm-target and child lookups keep groups out and
  audio drops onto groups are refused.
  - _Files_: `Godot/data/Track.gd`, `Godot/arranger/timeline/Timeline.gd`,
    `Godot/arranger/timeline/TimelineTrack.gd`, `Godot/editor/Editor.gd`,
    `Godot/editor/RecordArmPolicy.gd`, `Godot/history/commands/TrackDuplicateCommand.gd`,
    `Godot/ai/tools/AiTool.gd`
  - _Output_: MIDI clips can be drawn, moved and pasted on a group, and audio clips can't
  - _Verify_: `Godot/tests/run_all.sh group_midi_clips record_arm clip` passes, with the new
    `test_group_midi_clips.gd` covering create, move, paste, the refused audio drop and save/load
  - _Depends on_: —

- [x?] **T-009** [REQ-007, REQ-008, REQ-016] Add the MIDI Send state to `DeviceInstance`: mode,
  targets and blocked; signals; setters with history; `resolved_midi_send_targets()` and
  `_send_midi_send_targets()` driven by `sync_to_engine`, `hierarchy_changed` and
  `Project.channel_removed`; JSON; a listener for `midi_send/blocked`. `DevicePreset` leaves out
  the targets.
  - _Files_: `Godot/data/DeviceInstance.gd`, `Godot/data/DevicePreset.gd`
  - _Output_: the model keeps the engine's target list current
  - _Verify_: `Godot/tests/run_all.sh midi_send_targets` passes the new
    `test_midi_send_targets.gd` (children re-resolve on nest/unnest and removal, list filtering,
    round-trip, preset leaves out targets)
  - _Depends on_: T-004

- [x?] **T-010** [REQ-004] Refuse MIDI Send in nested chains: `device_fits_host`,
  `can_drop_instance_on_host` and `copy_fits_host` reject it when `host_parent != null`.
  - _Files_: `Godot/devices/DeviceDropUtil.gd`
  - _Output_: you can't drop or paste a MIDI Send into a container or slot
  - _Verify_: a case in `test_midi_send_targets.gd` asserts all three return false for a container
    host
  - _Depends on_: T-009

- [x?] **T-011** [REQ-017] Build `MidiSendDefaultView`: mode switch, Thru toggle, a target list that
  follows renames and marks blocked targets, and an add-target picker of valid channels. Register
  it in `DeviceViewFactory`.
  - _Files_: `Godot/devices/builtin/midi_send/MidiSendDefaultView.gd`,
    `Godot/devices/builtin/midi_send/MidiSendDefaultView.tscn`,
    `Godot/devices/DeviceViewFactory.gd`
  - _Output_: the panel view shows and edits the send
  - _Verify_: live check from T-015 (rename updates, delete removes, a loop is marked)
  - _Depends on_: T-009

- [x?] **T-012** [REQ-018] Add the arm option: `RecordArmPolicy.ARM_GROUP_IF_NOTES`, the "group has a
  top-level `Instrument` or `NoteEffect` device" check, and the new choice plus descriptions on
  both settings.
  - _Files_: `Godot/editor/RecordArmPolicy.gd`, `Godot/settings/Settings.gd`
  - _Output_: a group with a MIDI Send arms itself; a group with only a Reverb arms its last armed
    child
  - _Verify_: `Godot/tests/run_all.sh group_record_arm` passes with the new cases
  - _Depends on_: T-008

- [x?] **T-013** [REQ-020] DAWproject export: write group clips on the group's lane, and add a
  `TransferReport` entry for each MIDI Send.
  - _Files_: `Godot/dawproject/DawProjectExporter.gd`
  - _Output_: the transfer report lists every MIDI Send
  - _Verify_: `Godot/tests/run_all.sh dawproject` passes a new case for a group clip plus a send
  - _Depends on_: T-008, T-009

## Phase 4 — docs

- [x?] **T-014** [REQ-all] Write the docs: both OSC addresses and a MIDI Send entry in
  `osc-protocol.md`; the pre-pass in `engine-architecture.md`; ADR 0023 (MIDI pre-pass, extends
  0020); the device list and mixing step in `AGENTS.md`; `CHANGELOG.md` Unreleased lines. In
  requirements.md, carry the REQ-019 note into the future MIDI-recording issue.
  - _Files_: `docs/subsystems/osc-protocol.md`, `docs/subsystems/engine-architecture.md`,
    `docs/adr/0023-midi-pre-pass.md`, `AGENTS.md`, `CHANGELOG.md`
  - _Output_: every message added by this spec is documented
  - _Verify_: `grep -c midi_send docs/subsystems/osc-protocol.md` ≥ 2; the ADR exists; the
    CHANGELOG has the entries
  - _Depends on_: T-004, T-011, T-012

## Phase 5 — live verification

- [ ] **T-015** [REQ-005, REQ-010, REQ-011, REQ-015, REQ-017] Verify live with the engine and Godot
  running. Ask before touching a running user engine on port 7000.
  - _Files_: —
  - _Output_: `STATUS.md` notes what was and wasn't checked; the GitHub issue gets a comment
  - _Verify_: Choir group with 4 sfizz children, a chord clip on the group, a MIDI Send in children
    mode. Playback sounds on every child, with no flamming against the same clip on a child. Loop,
    stop, bypass mid-note and retarget mid-note leave no hanging notes. Arm the group and play the
    virtual keyboard, and the children sound. Rename a child and the view follows; delete it and
    it disappears; make B list A and the row is marked as looping.
  - _Depends on_: T-007, T-011, T-012, T-014

## Implementation notes (Phases 3 and 4)

Deviations from design.md:

- `TrackDuplicateCommand.can_duplicate` still refuses groups (`has_clips() and not is_group()`). The
  design says duplicate copies group clips, but duplicating a group copies no children, so it would
  yield a half group; left for a later change.
- Added `Track.default_clip_type()` (MIDI on instrument and group tracks) for the double-click
  create, and `Timeline._track_accepts_instance()` so moves, drags and pastes refuse audio clips on
  a group.
- `DeviceDropUtil.device_fits_channel` and the channel-type checks in `can_drop_instance_on_host` /
  `can_transfer_to_channel` restricted every note effect to instrument channels, which contradicts
  REQ-004 (any user channel). MIDI Send is now exempt (any non-master channel); a Chain wrapping a
  MIDI Send is refused, and a drum pad refuses it.
- The target picker and children-mode resolution also exclude Layer and Drum Machine return
  channels (`Channel.is_aux_return()`); the design only listed the sender, master and hardware ids.
- DAWproject: besides one `MIDI_SEND` entry per send (subject is `channel / device name`), a
  `GROUP_CLIP` entry reports group MIDI clips; the exporter already wrote them on the group's lane
  once `has_clips()` was true for groups.
- Not done: the GitHub issue for MIDI recording (the REQ-019 note is in requirements.md for it).
