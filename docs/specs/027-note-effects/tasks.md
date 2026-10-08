# 027: Note effects — Tasks

Implements [design.md](./design.md). Backlog item: [#83](https://github.com/petterthowsen/Sonara/issues/83)
(the backlog lives in GitHub Issues, not `TODO.md`).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

The phases follow the four delivery waves in requirements.md. Each wave ends with the full
`cargo test` and `Godot/tests/run_all.sh` green, and leaves note effects usable.

## Phase 1: note flow through chains (wave 1 engine foundation)

- [x] **T-001** [REQ-005] Split the note-id ranges.
  - _Files_: `Engine/src/audio/midi_types.rs`, `Engine/src/audio/active_notes.rs`
  - _Output_: range constants and `is_clip_note` / `is_generated`. `ActiveNotes::issue_id` takes
    the source, with live ids in `[1, 2^29)` and clip ids in `[2^29, 2^30)`.
  - _Verify_: `cargo test active_notes` passes, with the wrap test updated and a new
    `live_and_clip_ids_in_their_ranges`. The full `cargo test` is green.
  - _Depends on_: —

- [x] **T-002** [REQ-001, REQ-002] Note-effect trait surface and the routing module, with no
  behaviour change.
  - _Files_: `Engine/src/audio/devices/mod.rs`, `Engine/src/audio/devices/container.rs`,
    `Engine/src/audio/devices/note_fx/mod.rs` (new), `Engine/src/audio/devices/note_fx/routing.rs`
    (new), `Engine/src/audio/devices/note_fx/ids.rs` (new)
  - _Output_:
    - `DeviceCategory::NoteEffect` and the four `AudioDevice` defaults;
    - `DeviceContainer::chain_children_mut`;
    - `TimedNote` and `NoteBuffer`;
    - `route_note`, `run_note_phase` and `release_note_effects`;
    - `next_generated_id`.
  - _Verify_: `cargo test note_fx::routing` passes. A fake note effect stops routing, its output
    reaches only later devices, and events past the end go to the sink. Two chained fakes compose
    in order. The full `cargo test` is green.
  - _Depends on_: T-001

- [x] **T-003** [REQ-001, REQ-013] Switch the channel and Chain to `route_note` and the note phase.
  - _Files_: `Engine/src/audio/types.rs`, `Engine/src/audio/devices/chain.rs`,
    `Engine/src/audio/devices/layer.rs`
  - _Output_:
    - `send_note_event_to` and `ChainDevice::send_note_event` use `route_note`;
    - `Channel::dispatch_notes` is called from `begin_device_chain` and `process_aux_source`;
    - `ChainDevice::process_block` runs the note phase first;
    - `ChainDevice` gets its note-branch output and `chain_children_mut`.
  - _Verify_: The existing chain, layer, drum_machine, mixing, processing and stream tests pass
    unchanged. New `chain::tests::note_effect_feeds_only_downstream` and
    `layer::tests::note_effect_in_one_slot_only` pass using a fake transposing note effect.
  - _Depends on_: T-002

- [x] **T-004** [REQ-011] Note effects inside `ModulatedDevice`.
  - _Files_: `Engine/src/audio/modulation/host.rs`
  - _Output_: the four methods forwarded. An inner note effect gets `send_note_event` at once,
    not queued.
  - _Verify_: `cargo test modulation::host`, with a new
    `velocity_modulator_sees_note_effect_output` test (a fake fixed-velocity note effect before a
    wrapped device with a velocity modulator reads 0.25).
  - _Depends on_: T-003

- [x] **T-005** [REQ-003, REQ-004, REQ-005, REQ-006, REQ-007, REQ-008, REQ-009, REQ-012]
  `NoteFxHost`, `NoteProcessor` and `NoteCx`.
  - _Files_: `Engine/src/audio/devices/note_fx/host.rs` (new), `Engine/src/audio/devices/note_fx/mod.rs`
  - _Output_: the host from the design's Behaviour details:
    - audio pass-through and input sorting;
    - the host loop, schedule, sounding table and capacities;
    - the release, discontinuity and bypass flags;
    - `emit_on` / `emit_off` / `pass` / `release_children`;
    - the rate-limited overflow warning.
  - _Verify_: `cargo test note_fx::host` passes, using a test processor:
    - future events cross blocks at the right offset;
    - note-offs follow their note-ons after a parameter change;
    - generated ids are distinct;
    - bypass releases;
    - stop releases clip-origin notes and keeps live ones;
    - out-of-range keys are dropped;
    - an unknown note-off passes through;
    - unsorted input comes out sorted;
    - on overflow, note-offs are kept.
  - _Depends on_: T-002

- [x] **T-006** [REQ-006, REQ-007] Transport stop, bypass and structural-edit release.
  - _Files_: `Engine/src/audio/types.rs`, `Engine/src/audio/commands.rs`,
    `Engine/src/audio/command_worker.rs`
  - _Output_: `Channel::stop_clip_notes` is used by Pause, Stop and Seek. `release_note_effects`
    runs before `remove_device` and before `MoveDevice`.
  - _Verify_: New `types::tests::stop_releases_generated_clip_notes_only` and
    `commands::tests::moving_instrument_across_note_effect_releases` pass. The full `cargo test`
    is green.
  - _Depends on_: T-003, T-005

- [x] **T-007** [REQ-013] Separate outputs skip leading note effects (amends spec 006 REQ-007).
  - _Files_: `Engine/src/audio/types.rs`, `Engine/src/audio/mixing.rs`
  - _Output_: `Channel::aux_source_index()`. `process_aux_source` and both `start` sites use it,
    and the leading note effects get their note phase first.
  - _Verify_: `cargo test mixing`, with a new `aux_source_after_leading_note_effects` test (a
    Layer with a separate output behind a fake note effect still fills its return).
  - _Depends on_: T-003

- [x] **T-008** [REQ-034] Factory registration and conformance harness.
  - _Files_: `Engine/src/audio/devices/factory.rs`, `Engine/src/audio/devices/note_fx/conformance.rs` (new)
  - _Output_: `NOTE_EFFECT_IDS` (empty to start, filled in by each device task),
    `create_note_effect`, the `"note_effect"` category string, and the conformance checks from the
    design, run bare and wrapped.
  - _Verify_: `cargo test note_fx::conformance` passes (vacuously at first). Each device task
    below adds its id and must pass it.
  - _Depends on_: T-004, T-005

## Phase 2: first devices (wave 1)

- [x] **T-009** [REQ-014, REQ-015] Scale table, project scale in the engine, and Transpose.
  - _Files_: `Engine/src/audio/devices/note_fx/scale.rs` (new),
    `Engine/src/audio/devices/note_fx/transpose.rs` (new), `Engine/src/audio/types.rs`
    (`ProjectSettings::scale_mask`), `Engine/src/audio/transport.rs`, `Engine/src/audio/commands.rs`
    (`SetProjectScale`), `Engine/src/osc/server.rs` (`["project", "scale"]`),
    `Engine/src/audio/devices/factory.rs`
  - _Output_: Transpose with Semitones, Octaves and Scale (Off, Follow Project, Custom). Snap
    searches outward and ties go down. `/project/scale` reaches `Transport::scale_mask`.
  - _Verify_: `cargo test transpose` passes:
    - +3 / −1 octave: 60 → 51;
    - C major snap: 61 → 60 and 66 → 65;
    - Follow with mask 0 doesn't snap;
    - +12 on 120 is dropped;
    - note-on 60 at +12, then set +7, then note-off 60: the note-off goes to 72.

    `cargo test note_fx::conformance` passes for Transpose. `oscsend localhost 7000 /project/scale i 2741`
    logs the mask.
  - _Depends on_: T-008

- [x] **T-010** [REQ-016] Note Filter.
  - _Files_: `Engine/src/audio/devices/note_fx/note_filter.rs` (new), `Engine/src/audio/devices/factory.rs`
  - _Output_: key and velocity ranges with Invert.
  - _Verify_: `cargo test note_filter` passes with the REQ-016 example (including a note-off after
    the range changes), and conformance passes.
  - _Depends on_: T-008

- [x] **T-011** [REQ-017] Velocity.
  - _Files_: `Engine/src/audio/devices/note_fx/velocity.rs` (new), `Engine/src/audio/devices/factory.rs`
  - _Output_: Curve, Out Low/High and Random. Release is untouched, with a 1/127 floor.
  - _Verify_: `cargo test note_fx::velocity` passes with the REQ-017 examples (0 → 0.5 and
    1 → 1.0, fixed 0.8, and 1000 random notes at 0.5 inside 0.3–0.7). Conformance passes.
  - _Depends on_: T-008

## Phase 3: Godot integration (wave 1)

- [x] **T-012** [REQ-034] Note Effect category in Godot.
  - _Files_: `Godot/data/Device.gd`, `Godot/data/DeviceRegistry.gd`, `Godot/tests/test_note_fx_category.gd` (new)
  - _Output_: `DeviceCategory.NoteEffect`, the strings, the "Note Effects" browser group, the
    icon, `is_note_effect()`, and `creates_instrument_track`.
  - _Verify_: `Godot/tests/run_all.sh note_fx_category` passes. Fake `/builtin/info` rows with
    `"note_effect"` land under "Note Effects" and nowhere else.
  - _Depends on_: T-008

- [x] **T-013** [REQ-035] Drop rules.
  - _Files_: `Godot/data/NoteFx.gd` (new), `Godot/devices/DeviceDropUtil.gd`, `Godot/tests/test_note_fx_drop.gd` (new)
  - _Output_: Note effects are allowed on non-master instrument channels and inside Chain, Layer
    and Drum Machine slots. They are refused on audio channels, buses, master and Multiband
    bands.
  - _Verify_: `Godot/tests/run_all.sh note_fx_drop device_drop` passes.
  - _Depends on_: T-012

- [x] **T-014** [REQ-015] Send the project scale to the engine (amends spec 026).
  - _Files_: `Godot/data/MusicalScale.gd`, `Godot/data/Project.gd`, `Godot/tests/test_project_scale_sync.gd` (new),
    `docs/specs/026-scale-support/design.md`
  - _Output_: `MusicalScale.mask()`. `set_scale` and project sync send `/project/scale`. A note
    in the spec 026 design.
  - _Verify_: `Godot/tests/run_all.sh project_scale_sync` passes. D natural minor sends the right
    mask, "none" sends 0, and the Scale Type labels match the engine's captured enum list.
  - _Depends on_: T-009

- [x] **T-015** [REQ-036] Note-effect marker in the device lane.
  - _Files_: `Godot/devices/device_lane/DevicePanel.gd`
  - _Output_: a header stripe in `accent_secondary` for note effects.
  - _Verify_: `Godot/tests/run_all.sh device_panel compact_device_panel` passes, with an assert
    that the stripe is visible only for a note-effect device. A live look in both themes is part
    of T-033.
  - _Depends on_: T-012

- [x] **T-016** [REQ-037] Conditional disabling in the Simple View.
  - _Files_: `Godot/devices/simple_view/ParamRules.gd` (new), `Godot/devices/simple_view/SimpleView.gd`,
    `Godot/devices/simple_view/SimpleControl.gd`, `Godot/tests/test_param_rules.gd` (new)
  - _Output_: the rules for Transpose (Root and Scale Type only with Custom), Chord (Strum
    Direction while Strum > 0), Note Echo and Note Length (Rate vs ms by Sync). They are applied
    on bind and on every parameter change.
  - _Verify_: `Godot/tests/run_all.sh param_rules simple_view` passes. Setting Transpose Scale to
    Custom enables Root, and Off disables it.
  - _Depends on_: T-012

- [x] **T-017** [REQ-005, REQ-010] Wave 1 live check.
  - _Files_: —
  - _Output_: a short note in `STATUS.md` on what was checked.
  - _Verify_: Engine and Godot are running. On a Polysynth channel, Transpose +12 followed by
    Velocity fixed at 0.3 sounds an octave up and quiet, from both the virtual keyboard and a
    clip. Bypassing Transpose mid-note leaves no hanging note. Moving the Polysynth before
    Transpose leaves no hanging note.
  - _Depends on_: T-006, T-009, T-010, T-011, T-013, T-015, T-016

## Phase 4: Chord, Arpeggiator, Chance (wave 2)

- [x] **T-018** [REQ-018, REQ-019] Chord.
  - _Files_: `Engine/src/audio/devices/note_fx/chord.rs` (new), `Engine/src/audio/devices/factory.rs`
  - _Output_: 6 voices, Play Original, de-duplication, Strum with Up/Down, and strum cancellation
    on an early note-off.
  - _Verify_: `cargo test chord` passes with the REQ-018 and REQ-019 examples (60/64/67 at
    0.8/0.8/0.4, a single 72, strum offsets of 0/2400/4800 at 48 kHz). Conformance passes.
  - _Depends on_: T-008

- [x] **T-019** [REQ-021, REQ-026] `StepClock`.
  - _Files_: `Engine/src/audio/devices/note_fx/clock.rs` (new)
  - _Output_: grid-locked steps while playing (including `tempo_inc`), free-running steps while
    stopped, swing, and the skip-near-grid-point rule.
  - _Verify_: `cargo test note_fx::clock` passes:
    - 1/16 at 120 BPM / 48 kHz is 6000 frames apart;
    - Swing 50 % puts odd steps 1500 frames later;
    - while playing, steps sit on multiples of 240 ticks;
    - a tempo ramp keeps the drift under 1 frame over 4 bars;
    - an anchor 5 frames before a grid point skips that point.
  - _Depends on_: T-002

- [x] **T-020** [REQ-020, REQ-021, REQ-022, REQ-023] Arpeggiator.
  - _Files_: `Engine/src/audio/devices/note_fx/arpeggiator.rs` (new), `Engine/src/audio/devices/factory.rs`
  - _Output_: the four Modes, Octaves, Reverse, Ping-Pong with Repeat Ends, Rate, Gate, Swing,
    immediate start, continuing without a restart when notes change, Latch, and the `note_state`
    stream.
  - _Verify_: `cargo test arpeggiator` passes with every REQ-020 sequence, the REQ-021 timing,
    REQ-022 (output at offset 100, no restart on an added note) and REQ-023 (latch). Conformance
    passes.
  - _Depends on_: T-018, T-019

- [x] **T-021** [REQ-028] Chance.
  - _Files_: `Engine/src/audio/devices/note_fx/chance.rs` (new), `Engine/src/audio/devices/factory.rs`
  - _Output_: per-note-on probability, with note-offs paired to their note-ons.
  - _Verify_: `cargo test note_fx::chance` passes: at 0 % and 100 %, and at 50 % over 10 000 notes
    45–55 % pass with exact pairing. Conformance passes.
  - _Depends on_: T-008

- [x] **T-022** [REQ-037, REQ-039] Arpeggiator view.
  - _Files_: `Godot/devices/builtin/ArpeggiatorDefaultView.gd` / `.tscn` (new),
    `Godot/devices/DeviceViewFactory.gd`, `Godot/devices/simple_view/ParamRules.gd` (Repeat Ends
    rule shared), `Godot/tests/test_arpeggiator_view.gd` (new)
  - _Output_: every parameter, Repeat Ends disabled while Ping-Pong is off, and the held-notes
    strip fed by `note_state` (subscribe in `_on_view_shown`, unsubscribe in `_on_view_hidden`).
  - _Verify_: `Godot/tests/run_all.sh arpeggiator_view` passes. A fake `note_state` blob
    highlights the right key, and Ping-Pong off disables Repeat Ends.
  - _Depends on_: T-020, T-016

- [ ] **T-023** [REQ-010, REQ-018, REQ-020] Wave 2 live check.
  - _Files_: —
  - _Output_: a `STATUS.md` note.
  - _Verify_: Live:
    - a chord held on the virtual keyboard and the same chord from a clip give the same
      Arpeggiator pattern;
    - the highlight walks low to high in Up mode;
    - Chord → Arpeggiator → Chance sounds as expected;
    - stopping the transport during a clip arpeggio stops it, while a held key keeps
      arpeggiating.
  - _Depends on_: T-020, T-021, T-022

## Phase 5: Step Sequencer, Note Echo, Note Length, Latch (wave 3)

- [ ] **T-024** [REQ-024, REQ-025, REQ-026] Step Sequencer.
  - _Files_: `Engine/src/audio/devices/note_fx/step_sequencer.rs` (new), `Engine/src/audio/devices/factory.rs`
  - _Output_:
    - 16 steps with Length;
    - Chord and Mono modes;
    - both Velocity Source modes;
    - per-step Chance;
    - the transport-locked step index while playing, step 1 on the first note while stopped;
    - the `note_state` stream.
  - _Verify_: `cargo test step_sequencer` passes with the REQ-024 to REQ-026 examples (60, 63,
    rest, 72; 0.4 vs 0.5 velocity; Chord 62+66 vs Mono 66; step 1 at tick 960). Conformance
    passes.
  - _Depends on_: T-019

- [ ] **T-025** [REQ-003, REQ-027] Note Echo.
  - _Files_: `Engine/src/audio/devices/note_fx/note_echo.rs` (new), `Engine/src/audio/devices/factory.rs`
  - _Output_: Repeats, synced or ms Time, Decay, Pitch Step, source length kept, and the cutoff
    below 1/127.
  - _Verify_: `cargo test note_echo` passes with the REQ-027 example (60/72/84/96 at
    0.8/0.4/0.2/0.1, 250 ms apart, each 100 ms long), including a repeat that crosses a block.
    Conformance passes.
  - _Depends on_: T-005, T-019

- [ ] **T-026** [REQ-029] Note Length.
  - _Files_: `Engine/src/audio/devices/note_fx/note_length.rs` (new), `Engine/src/audio/devices/factory.rs`
  - _Output_: Fixed and Minimum modes, synced or ms Length, and Legato.
  - _Verify_: `cargo test note_length` passes with the REQ-029 examples (50 ms and 1 s inputs in
    both modes, Legato cut). Conformance passes.
  - _Depends on_: T-005, T-019

- [ ] **T-027** [REQ-012, REQ-030] Latch.
  - _Files_: `Engine/src/audio/devices/note_fx/latch.rs` (new), `Engine/src/audio/devices/factory.rs`,
    `Engine/src/audio/types.rs` (test)
  - _Output_: Chord and Toggle modes, Release All, and release on bypass.
  - _Verify_: `cargo test latch` passes with the REQ-030 examples. New
    `types::tests::latch_keeps_instrument_awake` (10 s simulated, instrument still sounding)
    passes. Conformance passes.
  - _Depends on_: T-008

- [ ] **T-028** [REQ-038] Step Sequencer view.
  - _Files_: `Godot/devices/builtin/StepGrid.gd` (new), `Godot/devices/builtin/StepSequencerDefaultView.gd` / `.tscn` (new),
    `Godot/devices/DeviceViewFactory.gd`, `Godot/tests/test_step_sequencer_view.gd` (new)
  - _Output_: header controls and the 16-column grid with an On / Pitch / Velocity / Chance bar
    each. Drag-paint sets one step per column. Steps beyond Length are dimmed. The current step
    is highlighted from `note_state`.
  - _Verify_: `Godot/tests/run_all.sh step_sequencer_view` passes:
    - dragging from column 1 to 8 sets 8 Pitch values;
    - Length 6 dims steps 7–16;
    - a fake blob highlights step 3.
  - _Depends on_: T-024, T-016

- [ ] **T-029** [REQ-041] Automation, modulation and preset round trip for note effects.
  - _Files_: `Godot/tests/test_note_fx_presets.gd` (new)
  - _Output_: a test that saves a Step Sequencer preset with non-default steps, loads it on a new
    instance, and checks every step value. Every note-effect parameter except momentary ones is
    marked automatable and modulatable in the info.
  - _Verify_: `Godot/tests/run_all.sh note_fx_presets` passes.
  - _Depends on_: T-024, T-012

## Phase 6: note containers (wave 4)

- [ ] **T-030** [REQ-031, REQ-032] `NoteContainerDevice` (Note Layer, Note Selector).
  - _Files_: `Engine/src/audio/devices/note_fx/container.rs` (new), `Engine/src/audio/devices/factory.rs`,
    `Engine/src/audio/devices/chain.rs` (`collects_note_output` flag set on insert),
    `Engine/src/audio/commands.rs` (`SetLayerSlotMute` downcast)
  - _Output_:
    - branch routing: Layer sends to every non-muted branch, Selector to one branch by Index,
      Round Robin or Random, with each note-off following its note-on;
    - per-branch note phase, with an empty branch passing notes through;
    - merged, sounding-tracked output;
    - `note_state` with the branch;
    - it is both a container and a note effect.
  - _Verify_: `cargo test note_fx::container` passes with the REQ-031 and REQ-032 examples (60 →
    60+72, mute A leaves 72; Round Robin A,B,C,A; the Select change keeps the note-off on B).
    Conformance passes for both ids.
  - _Depends on_: T-008, T-003

- [ ] **T-031** [REQ-033, REQ-040, REQ-042, REQ-043] Note containers in Godot.
  - _Files_: `Godot/data/Device.gd` (`container_focuses_one_child`), `Godot/data/NoteFx.gd`,
    `Godot/devices/DeviceDropUtil.gd`, `Godot/data/DeviceInstance.gd` (`sync_slot_to_engine`),
    `Godot/devices/builtin/NoteContainerDefaultView.gd` / `.tscn` (new),
    `Godot/devices/DeviceViewFactory.gd`, `Godot/tests/test_note_container.gd` (new)
  - _Output_:
    - branches are slot chains holding only note effects (a Polysynth is refused);
    - mute is sent and add is capped at 8;
    - the view shows branch rows, Mode and Select, and the last-branch highlight;
    - undo and save/load work.
  - _Verify_: `Godot/tests/run_all.sh note_container note_fx_drop` passes, covering:
    - the REQ-033 refusal;
    - mute sends `slot/{i}/mute`;
    - add/undo/redo;
    - a Note Layer with an Arpeggiator branch and a Chord branch round-trips through save and
      load;
    - a project without note effects round-trips unchanged.
  - _Depends on_: T-030, T-013

- [ ] **T-032** [REQ-013] The Layer separate-output rule in Godot (spec 006 amendment).
  - _Files_: `Godot/devices/container/LayerSlotRow.gd`, `Godot/tests/test_layer_mapping_window.gd`,
    `docs/specs/006-layer-note-mapping/design.md`
  - _Output_: OUT stays enabled when only note effects sit before the Layer. A note in the spec
    006 design.
  - _Verify_: `Godot/tests/run_all.sh layer_mapping_window` passes with the new case (Transpose
    before the Layer: enabled; a Delay before it: disabled).
  - _Depends on_: T-007, T-012

## Phase 7: docs

- [ ] **T-033** [REQ-all] Protocol and architecture docs, ADR and glossary.
  - _Files_: `docs/adr/0019-note-effects-note-phase.md` (new), `docs/subsystems/osc-protocol.md`,
    `docs/subsystems/engine-architecture.md`, `docs/subsystems/godot-device-views.md`,
    `CONTEXT.md`, `AGENTS.md`
  - _Output_:
    - `/project/scale`, `"note_effect"`, the `note_state` format and note-container slot mute are
      documented;
    - the note phase is in the callback flow;
    - the ADR is written;
    - the glossary terms are added and the stale "MIDI goes only to the first device" is fixed;
    - AGENTS.md lists the note effects.
  - _Verify_: every message and stream added by this spec appears in `osc-protocol.md`.
    `grep -n "first device" CONTEXT.md AGENTS.md` shows no stale claim.
  - _Depends on_: T-009, T-020, T-030

## Phase 8: live verification

- [ ] **T-034** [REQ-010, REQ-015, REQ-036, REQ-039, REQ-040, REQ-041, non-functional] Full live
  pass and soak.
  - _Files_: —
  - _Output_: the GitHub issue checklist updated, and `STATUS.md` notes what was and wasn't
    checked.
  - _Verify_: with the engine and Godot running:
    - REQ-015: Transpose following the project scale snaps to D minor after the scale changes.
    - REQ-036: the marker is visible in the light and dark themes.
    - REQ-039: the Arpeggiator highlight walks.
    - REQ-040: the Selector highlight goes A, B, C, A.
    - REQ-041: automating Semitones 0 → +12 over a bar audibly rises.
    - CPU: `cargo test note_fx::host::tests::idle_cost` is within budget.
    - Soak: Arpeggiator → Note Echo → Polysynth at 64-frame buffers for 5 minutes, with no
      xruns and no overflow warnings in `Engine/logs/last_warn.log`.
  - _Depends on_: T-017, T-023, T-028, T-029, T-031, T-032, T-033
