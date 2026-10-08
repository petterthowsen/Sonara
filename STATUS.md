# Sonara DAW - Project Status


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
