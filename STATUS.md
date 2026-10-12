# Sonara DAW - Project Status

## Engine performance and latency compensation (spec 042)

### Working
- T-009 shared-state audit (2026-10-12): `audio/devices`, `audio/modulation` and `audio/dsp` reached from `process_block`/`begin_block`/`finish_block`. **No to-fix items**: no device on one channel mutates state another channel's chain touches.
  - safe: every `static TABLE: ParamTable` / `*_SLOTS: [SlotSpec]` (immutable const data).
  - safe: `dsp/oscillator.rs` `SINE_TABLE` (`LazyLock`, forced in `Oscillator::new` off the audio thread, read-only after).
  - safe: `note_fx/ids.rs` `NEXT_GENERATED` (atomic `fetch_add`, ids stay distinct). With workers the *values* a channel draws depend on scheduling, but nothing compares or orders by id value (only equality matching), so audio output stays deterministic.
  - safe: `subprocess_adapter` `PLUGIN_UNDERRUNS` (relaxed counter), `container.rs` `SERIAL_PLUGIN_DISPATCH` (read-only after startup).
  - safe: plugin `HostSharedMemory` doorbell shared by all instances in one host: `futex::ring` is `fetch_add` + wake-all, and `finish_block` waits re-check their own instance's `done_seq`; block memory (`shared.memory`) is per instance.
  - safe: adapter `param_info_cache`, `saved_state` (`Arc<Mutex>`) — command-thread paths only (reload, state save), not in the process path.
  - safe: `sfizz_device` `Arc<Mutex<…>>` fields are per instance, shared only with that instance's loader thread; process path uses `try_lock`. The sfizz C++ library's internals were not audited; instances are independent by design.
  - safe: test-only `Arc<Mutex<Vec<…>>>` recorders in `note_fx/routing.rs`, `modulation/host.rs`.
  - No global RNG (`thread_rng`/`fastrand`) in device code; no `thread_local!` besides `rt_debug`.
- Constraints for T-011/T-012 found during the audit (not code changes):
  - Cross-channel writes happen only in the mixer, serially: `copy_extra_outs_to_targets` (aux pass), `forward_device_events`, `feed_taps` (block start) and `SidechainTaps::snapshot` (end). They must stay outside pool jobs.
  - `rt_debug` counters are `thread_local!`, so allocation violations on workers are only seen if each worker runs under `check_callback`/sections and reports (T-011's "rt_debug wrapping").
  - The logger (`logging/mod.rs`) writes through `Arc<Mutex<File>>`; `warn!` from several realtime threads at once contends on it. That's pre-existing on the audio thread and not pool-specific, but avoid logging per block on workers.
  - No FTZ/DAZ denormal flags are set anywhere today. If they are added later, workers need them too (MXCSR is per thread).

### Not Working / To do
- Live observation (user, 2026-10-12, release build after T-014): orchestral project (mostly sfz, some built-ins, one Decent Sampler plugin, Dragonfly Hall Reverb plugin) went from 40% to 38% load. That is far short of REQ-008's < 50% target, but it's not the T-015 benchmark (8 × PolySynth + Reverb). Not yet known: whether the comparison was Processing threads 1 vs Auto (6 threads here), and which channels are on the serial path. Suspects: a reverb bus that every section sends to runs after all its inputs finish, so its plugin round trip is serial; plugin IPC wait counts as callback time; sfizz instances may be cheap enough that the pool's per-pass overhead eats the gain.

## Saturator (spec 031)

### Working
- T-001…T-014 (engine) and T-016…T-018 (Godot view) implemented 2026-10-11 and verified headless: `cargo test saturator` 25 passed, `cargo test effect_conformance` green with no `KNOWN_FAILING`, `cargo test --lib` 1001 passed, `cargo build --release` ok, `Godot/tests/run_all.sh saturator` all passed. CPU bench (release, `saturator_cpu --ignored`): 1× = 1.37× Filter, 4× = 0.68× Filter (limit 1.5×).
- As-built deviations from design.md (recorded there): bias generalizes to all types as `curve(x + b) − curve(b)`; tilt is a two-pole Butterworth split at 1.3 kHz, law `2^(db/4)` (single-pole can't meet REQ-010's −6 dB/±1 dB figures); NOISE encoded `linear(0..50)` with 0 = Off; Quality switch crossfades two prepared `Oversampler`s (backport candidate for filter.rs); head bump confirmed one-pole low shelf at 100 Hz.
- Factory presets (REQ-016 preset half) descoped for v1 (2026-10-11) — no bundled-preset mechanism in `PresetLibrary.gd`.
- `"curve"` stream (584 B = 146 f32: header + 128 curve pts + 16 harmonics dB) documented in `osc-protocol.md`; first poll lags ~0.5 s after subscribing (poll-rate pattern). Status commented on GitHub issue #25.

### Not Working / To do
- T-015 live check (user; ports are hardcoded 7000/7001 so the running pre-031 engine must be restarted first via `./run_release.sh` + `godot --path Godot`): add the Saturator to a channel, a slot chain and Multiband FX band 2 (only that band distorts); automate Drive over two bars (no zipper noise); switch Type and Quality while a drum loop plays (no clicks); 10 s silence then a hit (intact); watch `/engine/load` with several instances at 4× for a minute (no xruns). Not machine-verifiable: all audible/judgement items and pixel fit of the 350 px panel.
- T-021 final pass (user): save/reopen persistence round trip (set Tape + drive 12 dB, save, reopen) — parameter round trip is covered by `effect_conformance` but the project-file round trip was not exercised; then update issue #25 with the results.

## Knob, Sidechain and XY modulators (spec 036)

### Working
- Phase 1 (engine, T-001…T-005): four appended kinds (`knob`, `xyx`, `xyy`, `sidechain`; `COUNT` 12), knob/XY evaluation, `ScState` filters + peak follower (−60…0 dBFS → 0–1), Device In feed from all three call sites, cross-channel `SidechainTaps` (`EngineState.sc_taps`, command-thread rebuild, post-fader snapshot at end of `mix_and_output`, feed at block start in `stream.rs`). `cargo fmt --check` clean, `cargo test` 971 lib + 2 bin tests 0 failed, `cargo build --release` ok.
- Phases 2–3 (Godot, T-006…T-010): `Modulator.is_bipolar()` (Bipolar knob arcs), `XYPad` pair model + `add/remove/duplicate_xy_pad`, `move_modulator_block`, pair-aware pane/tile with X/Y flat colour-coded wire buttons, `XYPadPanel`, sidechain Source channel OptionButton. `tests/run_all.sh modulator` — all 4 scripts pass.
- Phase 4 docs (T-011): kinds + sidechain semantics in `osc-protocol.md`, tap snapshot/feed + `sc_taps` in `engine-architecture.md`, XY pair in `godot-osc.md`.
- Post-implementation fixes (user reports 2026-10-11): (1) the EQ's spectrum visualizer died while a modulator existed: `ModulatedDevice::poll_device_data` answered every poll itself while `modulation` was subscribed, so the wrapped device's own streams (`spectrum`, `dynamics`) were never polled — the wrapper now falls through to the wrapped device unless its `modulation` payload is due. Regression: `host::tests::a_wrapped_device_still_polls_its_own_data_stream`. (2) That multiplex still made the visualizer laggy: one message per block meant a due `modulation` frame masked a due `spectrum` frame in the same block (EQ lost 2 of 10 frames → 24 instead of 30 Hz). `forward_device_events` now drains every due stream, one frame per data type per block (`DATA_FRAMES_PER_BLOCK` = 4; the note-FX `note_state` stream answers every poll, so the per-type dedupe keeps it from spinning the drain or masking the others). Regression: `mixing::tests::every_due_data_stream_is_drained_each_block` (red: spectrum 8 vs baseline 10; green: equal). Both pre-date spec 036: any modulated device with its own data stream has been affected since spec 018 Phase 9. `cargo test` 973 lib + 2 bin, 0 failed; `cargo fmt --check` clean.

### Not Working / To do
- T-012 live check (user): dynamic EQ (EQ on A, sidechain source B, Low Cut 200 Hz / High Cut 2 kHz, band gain −0.5), ducking via Utility gain with transport parked > 3 s, XY pad against two destinations (rename/duplicate/delete/drag/save/reload), knob Bipolar sign flip, `Engine/logs/last_warn.log` clean.

## EQ view controls (spec 035)

### Working
- `CompactSlider` (`Godot/components/CompactHSlider.gd`): text-first slider with the `RotaryKnob` interaction model (vertical drag, Shift FineDrag, Ctrl/Cmd reset, double-click `FloatingValueEditor`, `control_knob` hotkey context), modulation surface and theming. `tests/test_compact_hslider.gd` passes headless.
- EQ footer (`EqDefaultView`) reworked per REQ-007/009 (always-selected band dropdown, solo/enabled toggles, icon type dropdown, CompactSliders for F/G/Q); companion strips gained per-band solo + type dropdown (REQ-008). `test_eq_view.gd` passes headless; `tests/run_all.sh eq compact` — all 4 scripts pass.
- `EqTypeIcon.texture` (cached per type+colour), `EqKnobs.make_compact`/`configure_compact`/`dim_value_control`, gallery card. `CompactSlider` theme keys added in `ThemeBuilder` (`Sonara_Theme.tres` regenerated; freshness test passes).
- Post-live fixes (user report 2026-10-11): `CompactSlider` had no intrinsic minimum size, so the EQ footer's HBox laid it out 90×0 px — text still rendered (no rect clipping) but the control could not receive mouse input. Added `_get_minimum_size()` (text line + bar), centered the label (`HORIZONTAL_ALIGNMENT_CENTER`) and raised `text_font_size` 11 → 13. Regression: `test_eq_view.gd` asserts the footer sliders' laid-out height, `test_compact_hslider.gd` asserts the intrinsic min size.
- Panel width is automatic: `EqDefaultView._get_minimum_size` now returns the built layout's combined minimum width (toolbar vs footer row, floored at the old 420/640) instead of a fixed `Vector2(420, 250)`; regression in `test_eq_view.gd`.
- `CompactSlider` now draws a background (theme key `bg`, the well colour the other sliders use; `bar_bg` moved to the track colour so the bar stays visible on it). Companion strips stack the enabled toggle on top with the solo toggle below it (VBox header) instead of sharing one wide row.

### Not Working / To do
- T-012 live check (user): drag feel and icon crispness in the editor, gallery card visual, theme switch re-colour, and audio check that solo (`LISTEN_BAND` 81) isolates a band (run `./test_osc.sh` then set it).

## Note effects (spec 027, #83)

### Working
- Wave 1 (T-001…T-017): note flow through chains, Transpose, Note Filter, Velocity, plus the Godot category, drop rules, marker, Simple View disable rules and `/project/scale`. `cargo test` and the targeted Godot tests pass. T-017 live check passed (user, 2026-10-08): Transpose then Velocity on a Polysynth from the virtual keyboard and from a clip, bypassing Transpose mid-note and moving the Polysynth before it leave no hanging notes.

### Not Working / To do
- Simple View controls for the note effects show normalized knob values instead of real ones (semitones, %, key). Likely a general Simple View issue, not specific to note effects.
- Wave 2 engine and UI (T-018…T-022): Chord, `StepClock`, Arpeggiator, Chance and the Arpeggiator view (held-keys strip from `note_state`). `cargo test` and the targeted Godot tests pass. Clip arpeggio over a loop region verified live (a loop wrap on a block boundary used to repeat the first step). Rest of the T-023 live check still to do (virtual keyboard vs clip arpeggio, highlight walks low to high in Up mode, Chord → Arpeggiator → Chance, transport stop mid clip arpeggio).
- Waves 3–4 (T-024 onwards) not started.


## Built-in effects UI (spec 012 follow-up)

The engine side of the effects (`docs/specs/012-builtin-effects/plan.md`, phases 1-7) is close to spec. Some of the Godot views need work.

### Not Working / To do
- Compressor: no real-time visual feedback. There seems to be a meter component, but it shows nothing. The design needs more thought; later.


## Working toward DAWproject support

Spec: `docs/dawproject/specification.md`. Full gap checklist: `docs/dawproject/sonara-gaps.md`.

### Next up


### Later
- Key signature changes, root key + scale, together with ruler in arranger.
- Bus tracks in the arranger: shown pinned at the bottom, with a toggle to show/hide them.
- Automation lanes on buses: volume, pan, device parameters

### Working
- DAWproject import/export, core subset (spec `docs/specs/010-dawproject-core/`, docs in `docs/subsystems/dawproject.md`): tasks T-001…T-018 done, headless tests pass (units, export + xmllint schema check, import against the Bitwig fixture, round trip, editor entry points). T-019 live check is still open: import the fixture and play it, export and open in Bitwig, save the import as `.sonara` and reopen, time a 50-track export. The menu items and dialogs have not been clicked through in a running app yet.
- Time signature changes (spec `docs/specs/009-time-signature-map/`): engine map + `/transport/time_signature_map`, Godot `TimeSignatureMap`, segment-based grid and snapping, arranger lane (add, edit, drag, delete, undo). `cargo test` and the Godot tests pass. Verified live by the user (lane UX, MIDI editor ruler, marker size). Details of each T-012 step were not itemised, so playback across a change with a tempo-synced CLAP plugin and save/reopen are covered only by the user's sign-off.
- Tempo automation lane and tempo map playback (spec `docs/specs/008-tempo-map-engine/`). Verified live: the engine clock, MIDI and audio clips follow ramps, the time ruler and tempo field follow the map, and devices and CLAP plugins receive transport info. `cargo test` and `Godot/tests/run_all.sh` pass.
- Modulator panel (spec `docs/specs/033-modulator-panel/`): square column-major panel grid with placeholder + cells, drag-to-reorder (array order persisted, engine sync order-safe), live per-kind displays (LFO/ADSR/generic trace with white dot) from the `modulation` payload's trailing block, and modulator→modulator routing evaluated by the engine — mono and per-voice on PolySynth, one control step of delay, dangling routes cleared on removal. All phases T-001…T-019 done and verified live (user, 2026-10-10); `cargo test --lib` (936 passed) and the Godot modulator suites (incl. `test_modulator_drag.gd`, `test_modulator_panel_live.gd`) pass. Tracking issue #99.

### Not Working / Not verified
- Audio clips now seek and loop on their own recorded-BPM timeline. Clips whose recorded BPM differs from the project tempo sit differently than before (the old seek offset was wrong for them).
- Tempo map is resent on every (re)connect, but that path wasn't tested with a mid-session engine restart.


## Audio thread stalls (shared `Arc<Mutex<EngineState>>`)

The audio callback blocked on `state.lock()` while the command thread held the lock for the whole of `process_command`, so anything slow in a command froze audio.

Phase 1 (done, needs live testing): shared state kept, slow work moved outside the lock in `CommandWorker`, bounded `try_lock` (1 ms, then silence) in the callback, per-buffer allocations and debug logging removed from the callback.
Phase 2 (later): audio thread owns its state, lock-free command queue, removed objects dropped off-thread.

### Stalls that were under the lock
- `ScanPlugins`: dlopens every `.clap` bundle
- `OpenPluginGui` / `ClosePluginGui`: IPC round-trip, 5 s / 2 s timeouts
- `SetDeviceActive`: two IPC round-trips with no timeout
- Dropping a `SubprocessClapAdapter` (remove device, clear devices, remove channel, clear project): GUI close + subprocess shutdown
- `LoadAudioClip`: `samples.clone()` of the whole file plus log formatting
- `AdvertiseBuiltinDevices`: builds temporary devices
- On the audio thread itself: blocking `process.lock()` in `poll_parameter_changes`, which GUI IPC holds for seconds

### Working
- `cargo build --release` passes with no new warnings
- `cargo test --release`: all unit tests pass, including 2 new routing tests. The 2 send tests already failed at HEAD (gain warm-up too short) and are fixed.

- Live: audio plays and routes through master after restarting engine + Godot
- Live: Dragonfly Reverb (CLAP) on a bus, and importing a large audio clip into a new track during playback: stable, no dropouts
- Live: mute and solo; reverb tails on send-fed and routed buses keep ringing after pausing playback
- Live: nested buses (track → bus → bus → master)
- Mixing routes in dependency order (fixes routed-bus tails and double bus processing): 3 new unit tests pass

### Not Working / Not verified
- Live: mute on master now silences output (previously master mute only bypassed its devices)
- Godot doesn't resend the project (init, master channel) when the engine restarts, so restart Godot too
- Stress checks not done yet, while audio plays: remove a CLAP plugin, open/close its GUI, scan plugins. Listen for dropouts.
- Doctest in `ipc/protocol.rs` fails (diagram in a doc comment parsed as Rust). Already broken, file untouched.
