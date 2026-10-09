# MIDI CC automation — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine tests run from `Engine/` (`cargo test <name> -- --nocapture`, `cargo fmt`); Godot tests with
`Godot/tests/run_all.sh <word>`. Run at most 2–3 cargo jobs at once.

## Phase 1 — engine foundation

- [ ] **T-001** [REQ-004] 14-bit helpers.
  - _Files_: `Engine/src/audio/midi_types.rs`
  - _Output_: `CC_MAX`, `cc14_from_unit`, `cc14_to_unit`, `cc14_from_cc7`, `cc14_msb`, with tests
  - _Verify_: `cargo test cc14` — 0.5 → 8192, 1.0 → 16383, clamps outside 0–1, cc7 127 → 16383,
    cc7 64 → 8256, msb of 8192 → 64
  - _Depends on_: —

- [ ] **T-002** [REQ-003, REQ-004] Device entry point and chain routing.
  - _Files_: `Engine/src/audio/devices/device.rs`, `Engine/src/audio/devices/note_fx/routing.rs`,
    `Engine/src/audio/devices/containers/chain.rs`, `Engine/src/audio/devices/containers/layer.rs`,
    `Engine/src/audio/channel/chain.rs`
  - _Output_: `AudioDevice::send_cc` / `cc_value` (default no-op / `None`), `route_cc`, container
    forwarding, `Channel::send_cc_to_devices`
  - _Verify_: `cargo test route_cc` — a recording device in the chain, in a Chain child and in a
    Layer slot each receives (cc, value14, offset); a device with no override receives nothing and
    nothing fails; a sleeping instrument is woken, a sleeping effect is not
  - _Depends on_: T-001

- [ ] **T-003** [REQ-001, REQ-002, REQ-003, REQ-012] The CC lane target.
  - _Files_: `Engine/src/audio/automation.rs`, `Engine/src/audio/channel/mod.rs`
  - _Output_: `AutomationTarget::MidiCc { cc }` (`parse` 0–119, `Display` `channel/cc/{n}`),
    `Channel.cc_lane_mask`, `apply_lane_value` arm with the 14-bit dedup
  - _Verify_: `cargo test automation_` — `automation_target_roundtrip` covers `channel/cc/74`
    and rejects `channel/cc/120` and `channel/cc/x`; `automation_cc_lane_delivers_value14` (points
    0.0 at tick 0 and 1.0 at tick 960: the device sees ≈ 8192 at tick 480);
    `automation_cc_lane_dedups_at_14_bits` (a flat lane delivers once across 100 buffers);
    `automation_cc_lane_ignored_by_device_without_cc`
  - _Depends on_: T-002

- [ ] **T-004** [REQ-005, REQ-006] Seek while stopped, base capture and release.
  - _Files_: `Engine/src/audio/automation.rs`
  - _Output_: base captured from the first `cc_value` in the chain on first drive; `release_lane`
    restores it, or sends nothing when there was none; the lane's `cc_lane_mask` bit is cleared
  - _Verify_: `cargo test automation_cc_lane` — `…_applies_while_stopped`,
    `…_restores_known_base_on_bypass` (0.25 → driven to 0.9 → bypass returns 0.25),
    `…_without_base_sends_nothing`, delete behaves like bypass
  - _Depends on_: T-003

- [ ] **T-005** [REQ-011] One lane per controller per track.
  - _Files_: `Engine/src/audio/commands/track.rs`
  - _Output_: `create_automation_lane` refuses a lane whose target equals an existing lane's on
    that track, with a warning
  - _Verify_: `cargo test create_automation_lane` — second create for `channel/cc/1` is refused
    and the first lane is untouched; two different CCs coexist
  - _Depends on_: T-003

## Phase 2 — device delivery and live input

- [ ] **T-006** [REQ-013, REQ-014] Live CC reaches the chain.
  - _Files_: `Engine/src/audio/channel/chain.rs`
  - _Output_: `dispatch_scheduled_midi` handles `ControlChange`: 7→14 bit, `route_cc` at the
    scheduled frame offset, skipped while the controller's `cc_lane_mask` bit is set
  - _Verify_: `cargo test live_cc` — `live_cc_reaches_device_with_frame_offset` (CC1 value 64
    arrives as 8256 at the offset the scheduler computed);
    `live_cc_is_suppressed_while_a_lane_owns_the_controller` and delivered again after bypass
  - _Depends on_: T-003

- [ ] **T-007** [REQ-003, REQ-004] SFZ sampler delivery.
  - _Files_: `Engine/src/audio/devices/instruments/sfizz_device.rs`
  - _Output_: `queued_midi` entries become a `Copy` enum of note and CC; `send_cc` queues
    (preallocated, a full queue drops and counts); `process_block` renders up to the CC's offset
    and sends `sfizz_send_hdcc` with `cc14_to_unit`; `cc_value` reads the knob value via
    `try_lock`; the existing `sfizz_release_reaches_binding` test follows the enum
  - _Verify_: `cargo test sfizz` — `sfizz_cc_reaches_synth_at_full_resolution` (a loaded
    `*sine` SFZ with `volume_oncc1`: two values one 14-bit step apart render different levels),
    `sfizz_cc_value_reports_knob_value`, and the earlier sfizz tests still pass
  - _Depends on_: T-002

- [ ] **T-008** [REQ-003, REQ-004] CLAP plugin delivery; VST3 counted as unsupported.
  - _Files_: `Engine/src/audio/ipc/protocol.rs`,
    `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs`,
    `Engine/src/plugin_host/audio_thread.rs`, `Engine/src/plugin_host/vst3/processor.rs`
  - _Output_: `EVENT_MIDI_CC = 6` and `BlockEvent::cc`; adapter `send_cc`; `OwnedEvent::Midi`
    built as `B0 cc msb` (`msb = value14 >> 7`); explicit unsupported arm in `translate_events`
  - _Verify_: `cargo test cc_reaches_the_host` and `cargo test midi_cc` — event carries cc,
    value14 and sample offset; the CLAP event bytes for value14 8192 on CC1 are `B0 01 40`; the
    VST3 translation increments `Dropped.unsupported` and nothing else
  - _Depends on_: T-002

## Phase 3 — Godot

- [ ] **T-009** [REQ-001, REQ-002, REQ-010, REQ-011] The target in Godot.
  - _Files_: `Godot/data/AutomationTarget.gd`, `Godot/tests/test_automation_model.gd`
  - _Output_: `Kind.MIDI_CC = 5`, `midi_cc(cc)`, `channel/cc/{n}` spelling and `parse` (0–119),
    `is_resolvable` true, `display_name` using the instrument's label else `Midi.cc_display_name`
  - _Verify_: `Godot/tests/run_all.sh automation_model` — spelling matches the engine test
    strings; 120 and `x` fail to parse; labels read `CC1 Mod Wheel`, `CC74 …`, `CC3 CC3`-style
    fallback per `Midi.cc_display_name`, and an SFZ label wins; `Track.get_automation_lane_for`
    finds the lane so a second create is refused
  - _Depends on_: —

- [ ] **T-010** [REQ-007] Migrate saved SFZ-parameter lanes.
  - _Files_: `Godot/data/DeviceInstance.gd`, `Godot/data/Project.gd`,
    `Godot/tests/test_cc_automation_migration.gd` (new)
  - _Output_: `DeviceInstance.is_controller_parameter(param)`; `_migrate_cc_automation(project)`
    called after `_migrate_slot_automation`: `device/…/param/N` on an SFZ sampler → `channel/cc/N`,
    points/curves/colour/bypass untouched, a would-be duplicate dropped with `push_warning`
  - _Verify_: `Godot/tests/run_all.sh cc_automation_migration` — `device/0/param/73` becomes
    `channel/cc/73` with identical points; a lane on a non-SFZ device is untouched; two lanes for
    CC1 leave one
  - _Depends on_: T-009

- [ ] **T-011** [REQ-001, REQ-002, REQ-008, REQ-009] The picker.
  - _Files_: `Godot/arranger/tracklist/AutomationParameterPicker.gd`,
    `Godot/tests/test_automation_lane_menu.gd`
  - _Output_: a top-level `MIDI CC` submenu (instrument-labelled controllers first, then
    CC0–CC119 named by `Midi.cc_display_name`, searchable, omitting controllers that already have
    a lane); controller parameters no longer listed under their device
  - _Verify_: `Godot/tests/run_all.sh automation_lane_menu` — CC11 and CC74 offered for a
    built-in synth and for an SFZ using only CC1; none of 120–127; an SFZ labelling CC73/CC72
    lists `Attack`, `Release` first; an SFZ contributes no device submenu; a track with a CC1 lane
    no longer offers CC1
  - _Depends on_: T-009, T-010

- [ ] **T-012** [REQ-015] Persistence and undo.
  - _Files_: `Godot/tests/test_automation_history.gd`, `Godot/tests/test_automation_model.gd`
  - _Output_: CC lane cases added to the existing suites
  - _Verify_: `Godot/tests/run_all.sh automation` — create, edit, save, reload; undo and redo
    restore every step
  - _Depends on_: T-011

- [ ] **T-013** [REQ-016] DAWproject export and import.
  - _Files_: `Godot/dawproject/DawProjectExporter.gd`, `Godot/dawproject/DawProjectImporter.gd`,
    `Godot/tests/test_dawproject_roundtrip.gd`
  - _Output_: kind 5 exported as `Target expression="channelController" channel="0"
    controller="N"` (names checked against the DAWproject schema before writing); imported back
    as a `channel/cc/N` lane; other `expression` targets still reported as dropped
  - _Verify_: `Godot/tests/run_all.sh dawproject` — a CC1 lane with three points round-trips
    within 2 % of the range; `test_dawproject_import.gd` still reports other expressions
  - _Depends on_: T-009

## Phase 4 — docs

- [ ] **T-014** [REQ-all] Documentation.
  - _Files_: `docs/subsystems/osc-protocol.md`, `docs/subsystems/engine-plugin-architecture.md`,
    `docs/subsystems/engine-sfz-sampler.md`, `docs/subsystems/dawproject.md`,
    `docs/specs/003-automation/requirements.md`
  - _Output_: the `channel/cc/{n}` target and its 0–119 range; `EVENT_MIDI_CC` and the VST3
    limitation; the SFZ `send_cc` path and that CC lanes no longer go through `set_parameter`;
    the `channelController` mapping; a one-line note under 003 REQ-015 and REQ-017 pointing here
  - _Verify_: every item added by this spec appears in the doc named for it
  - _Depends on_: T-008, T-013

## Phase 5 — gates and live verification

- [ ] **T-015** [REQ-all] Run the gates.
  - _Files_: —
  - _Output_: clean `cargo fmt`, full `cargo test`, full `Godot/tests/run_all.sh`
  - _Verify_: `cd Engine && cargo fmt --check && cargo test`; `Godot/tests/run_all.sh` — no
    failures; report any pre-existing failure separately
  - _Depends on_: T-005, T-006, T-007, T-008, T-012, T-013

- [ ] **T-016** [REQ-all] Verify live with the engine and Godot running (needs sound, the VPO
  libraries, and the user's go-ahead for the engine port and audio setup).
  - _Files_: —
  - _Output_: checklist below marked, `STATUS.md` notes what was and wasn't checked
  - _Verify_: (1) VPO patch + CC1 lane: dynamics follow it; (2) bypass/delete the lane: CC1 returns
    to the knob value; (3) mod wheel changes the patch, and is ignored while a CC1 lane is active;
    (4) CC11 lane on a patch that never mentions CC11 is accepted; (5) an older project with a
    CC73 lane opens as `CC73 Attack`; (6) export the project to DAWproject and import it again,
    the CC lane survives; (7) a CLAP instrument with a CC lane does not glitch or log errors
  - _Depends on_: T-015

- [ ] **T-017** [REQ-all] Track the work and the follow-up.
  - _Files_: —
  - _Output_: a GitHub issue for this spec's checklist and a `ready-for-human` issue for the VST3
    `IMidiMapping` follow-up (AGENTS.md keeps the backlog in GitHub Issues, not `TODO.md`)
  - _Verify_: `gh issue list` shows both. Creating issues is outward-facing, so it waits for the
    user's go-ahead.
  - _Depends on_: T-016
