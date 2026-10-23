# Metronome — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Build-heavy steps run one at a time with `CARGO_BUILD_JOBS=2` (see the "parallel agent limits"
memory). Engine commands run from `Engine/`.

## Phase 1 — engine core (patterns, sound, scheduler)

- [x] **T-001** [REQ-010, REQ-012, REQ-013] Pattern table and step cursor.
  - _Files_: `Engine/src/audio/metronome/pattern.rs`, `Engine/src/audio/metronome/mod.rs` (module stub), `Engine/src/audio/mod.rs`
  - _Output_: `Pattern`, `PatternTable` (32 × 128 fixed), `Pattern::default_for`, `StepCursor::at_or_after` / `advance` over `TimeSignatureMap::segment_at`
  - _Verify_: `cargo test metronome::pattern`: `default_patterns`, `cursor_crosses_signature_change`, `table_replace_and_remove` and a mismatched-steps-falls-back-to-default case pass
  - _Depends on_: —

- [x] **T-002** [REQ-020, REQ-021, REQ-022, REQ-023] Sound mapping onto the Kick and Snare hosts.
  - _Files_: `Engine/src/audio/metronome/sound.rs`, `Engine/src/audio/devices/instruments/drums/kick.rs`, `.../snare.rs` (consts → `pub(crate)`)
  - _Output_: `MetronomeSound` (clamped real values), `SoundKind`, Beep/Wood presets, `apply(host, kind, sound) -> base_note`, `note_for_level`, `velocity_for_level`
  - _Verify_: `cargo test metronome::sound`: `base_note_maps_tune_exactly` (200, 1000 and 4000 Hz, both voices), `emphasis_volume_ratio` (−12 ±0.5 dB), `emphasis_pitch_octave`, `level_floor` (< −55 dBFS) pass. Existing `drum_conformance` still passes
  - _Depends on_: —

- [x] **T-003** [REQ-004, REQ-005, REQ-006, REQ-007] `Metronome` struct and `render`.
  - _Files_: `Engine/src/audio/metronome/mod.rs`
  - _Output_: two hosts from `create_drum`, the pending queue (16), stereo scratch, `set_enabled`, `set_sound`, `set_pattern`, `clear_patterns`, `audition`, `prepare`, `render(...)` mixing into an interleaved hardware buffer at a given pair with a given delay
  - _Verify_: `cargo test metronome::` with `clicks_on_exact_frames_across_block_sizes` (64, 256 and 1024), `loop_wrap_replays_downbeat`, `tempo_ramp_clicks_on_beat_ticks`, `silent_when_stopped_or_disabled_and_tail_rings` and `delayed_by_master_hw_delay`, all driving `render` with hand-built tick lists
  - _Depends on_: T-001, T-002

## Phase 2 — engine wiring (state, callback, commands, OSC)

- [x] **T-004** [REQ-004, REQ-007] Put the metronome on `EngineState` and call it from the callback.
  - _Files_: `Engine/src/audio/state.rs`, `Engine/src/audio/stream.rs`, `Engine/src/audio/command_worker/audio_config.rs`
  - _Output_: `EngineState.metronome`. `run_live_block` calls `render` after the preview, with master's pair and `latency.hw_delay`. A sample-rate change re-prepares it
  - _Verify_: `cargo test` passes, including a new `stream.rs` test `metronome_plays_after_master_and_bypasses_its_fader` (master fader −inf, click present) and the existing `preview_plays_after_the_master_and_is_silent_while_rendering`
  - _Depends on_: T-003

- [x] **T-005** [REQ-007] Export never contains the click.
  - _Files_: `Engine/src/audio/render/worker.rs` (test only)
  - _Output_: test `render_excludes_metronome`
  - _Verify_: `cargo test render_excludes_metronome`: two renders (metronome on and off) are bit-identical
  - _Depends on_: T-004

- [x] **T-006** [REQ-001, REQ-004, REQ-021, REQ-024, REQ-032] Commands and OSC routes.
  - _Files_: `Engine/src/audio/commands/metronome.rs`, `Engine/src/audio/commands/mod.rs`, `Engine/src/osc/routes/metronome.rs`, `Engine/src/osc/routes/mod.rs`
  - _Output_: five `AudioCommand` variants on the fast path. The `/metronome/{enabled,sound,pattern,clear,audition}` routes, with a malformed pattern warned and ignored
  - _Verify_: `cargo test osc::routes::metronome` (each address yields the right command; bad step count ignored; empty pattern removes) and `cargo test` overall; `cargo fmt` clean
  - _Depends on_: T-004

- [x] **T-007** [REQ-004, REQ-020] First live listen through OSC (engine only).
  - _Files_: — (presets in `sound.rs` may be adjusted)
  - _Output_: Beep and Wood presets tuned by ear; the chosen constants committed
  - _Verify_: `./run_release.sh`, then `oscsend localhost 7000 /metronome/enabled i 1` and `/transport/play`. Clicks are heard on the beats with the accent on 1. Switch `/metronome/sound` to Wood. **Ask the user first** (port 7000 may be held by their engine, per the "live check environment" memory)
  - _Depends on_: T-006

## Phase 3 — Godot model

- [x] **T-008** [REQ-030] Register the metronome settings.
  - _Files_: `Godot/settings/Settings.gd`
  - _Output_: eight `metronome/*` settings in `CATEGORY_AUDIO` / "Metronome" with the design's defaults and ranges
  - _Verify_: `Godot/tests/run_all.sh settings` passes. `test_metronome_model.gd` (T-009) asserts the defaults
  - _Depends on_: —

- [x] **T-009** [REQ-010–013, REQ-024, REQ-030–032] `Metronome` model and Project integration.
  - _Files_: `Godot/data/Metronome.gd`, `Godot/data/Project.gd`, `Godot/tests/test_metronome_model.gd`
  - _Output_: grid helpers, per-signature patterns, `set_step` / `reset_pattern` / `set_resolution`, `get_state` / `set_state`, `to_json` / `from_json`, `sync_messages` / `sync_to_engine`, the settings bridge, `audition` with a 150 ms limit. `Project.metronome` is saved, loaded and synced in the handshake
  - _Verify_: `godot --headless --path Godot -s tests/test_metronome_model.gd -- --test` passes: grid shapes, allowed resolutions, isolation and default, JSON round trip, undo via `set_state`, settings defaults, `sync_messages` order, rate limit. `Godot/tests/run_all.sh project` still passes
  - _Depends on_: T-008

## Phase 4 — Godot UI

- [x] **T-010** [REQ-014] StepLane per-level colours and the theme roles.
  - _Files_: `Godot/components/StepLane.gd`, `Godot/core/theme/ThemePalette.gd`
  - _Output_: optional `level_colors`, four `metronome_level_*` roles
  - _Verify_: `Godot/tests/run_all.sh step_lane step_sequencer theme` passes. A new case in `test_step_lane.gd` checks that `_bar_color_for(k)` (helper extracted for testability) returns `level_colors[value]`
  - _Depends on_: —

- [x] **T-011** [REQ-002, REQ-010, REQ-011, REQ-014, REQ-021–024] Metronome popup scene.
  - _Files_: `Godot/editor/metronome/MetronomePopup.tscn`, `Godot/editor/metronome/MetronomePopup.gd`, `Godot/tests/test_metronome_popup.gd`
  - _Output_: header row (signature, resolution, Reset), the StepLane grid, the sound row (Beep/Wood plus six LabeledKnobs), undo capture on `edit_started` / `edit_ended`, the playhead step flash, audition on edits while stopped
  - _Verify_: `godot --headless --path Godot -s tests/test_metronome_popup.gd -- --test` passes (shallow: instantiates, a model step change shows in the lane, the resolution list for 7/8 has 2 entries)
  - _Depends on_: T-009, T-010

- [x] **T-012** [REQ-001, REQ-002, REQ-003] Transport buttons, popup, hotkey.
  - _Files_: `Godot/editor/Editor.tscn`, `Godot/editor/Editor.gd`, `Godot/input/HotkeyActions.gd`
  - _Output_: `MetronomeToggle` and `MetronomeMenuButton` after `StopButton`. The toggle tracks `metronome/enabled` both ways, its tooltip shows the chord, the chevron opens the popup below itself, and `transport_metronome_toggle` is handled in `_handle_transport_hotkey`. Playhead updates go to the open popup
  - _Verify_: `Godot/tests/run_all.sh hotkeys transport` passes, with a new assertion in `test_hotkeys_registry.gd` for the action and one in `test_transport_actions.gd` that dispatch flips the setting
  - _Depends on_: T-011

- [x] **T-013** [requirements open question] Beats-ruler toggle icon → ruler.
  - _Files_: `Godot/assets/icons/ruler.svg`, `Godot/arranger/Arranger.tscn`
  - _Output_: `BeatsToggle` shows a ruler icon
  - _Verify_: `Godot/tests/run_all.sh arranger` passes; live, the tracklist header shows the ruler icon
  - _Depends on_: —

## Phase 5 — docs

- [x] **T-014** [REQ-all] OSC protocol doc.
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: a "Metronome (Godot -> Rust, spec 053)" section with all five addresses, argument types and validation
  - _Verify_: every `/metronome/*` route in `osc/routes/metronome.rs` appears in the doc (`grep -c "/metronome/" docs/subsystems/osc-protocol.md` ≥ 5)
  - _Depends on_: T-006

- [x] **T-015** [REQ-007] Architecture doc, ADR and changelog.
  - _Files_: `docs/subsystems/engine-architecture.md`, `docs/adr/0026-metronome-outside-channel-graph.md`, `CHANGELOG.md`, `AGENTS.md` (one clause in "Callback and mixing")
  - _Output_: callback order mentions the metronome after the preview; the ADR records the rejected hidden-channel option; an `[Unreleased]` changelog line
  - _Verify_: the files contain the entries; the ADR follows the format of `0025-stage-mic-capsules.md`
  - _Depends on_: T-012

- [ ] **T-016** [REQ-all] Backlog entry.
  - _Files_: — (GitHub Issues; the backlog lives there per AGENTS.md, not `TODO.md`)
  - _Output_: a GitHub issue "Metronome (spec 053)" labelled `engine`, `godot`, with this task list as a checklist
  - _Verify_: `gh issue view <n>` shows it. **Created only after the user confirms** (outward-facing)
  - _Depends on_: —

## Phase 6 — live verification

- [x] **T-017** [REQ-all] Full live check with engine and UI.
  - _Files_: — (`STATUS.md` notes)
  - _Output_: the issue checklist updated; `STATUS.md` records what was and wasn't checked
  - _Verify_: with the user (ask before starting the engine). Each check:
    1. Toggle in the transport, play: clicks with the accent on 1 (REQ-001/004).
    2. Hotkey bound in Settings → Shortcuts toggles it (REQ-003).
    3. Popup opens below the chevron and closes on an outside click (REQ-002).
    4. Paint steps at 1/8 and hear the pattern. Reset restores it. Ctrl+Z undoes a step edit (REQ-011/014/031).
    5. Add a 7/8 change at bar 3 and loop bars 2–4: each bar uses its own pattern and the downbeat comes back on the wrap (REQ-006/012).
    6. Drag every knob during playback with the Load popup open: no xruns (REQ-008/021–023).
    7. While stopped, knob moves play spaced preview clicks (REQ-024).
    8. Master fader down: the click is still heard. Export a WAV: no click in it (REQ-007).
    9. Restart the UI: on/off and sound are kept; reopen the project and its patterns are kept (REQ-030/031).
    10. Kill and restart the engine with the UI open: the click comes back unchanged (REQ-032).
  - _Depends on_: T-007, T-012, T-013, T-014, T-015
