# Sonara DAW - Project Status

## Parameter automation (docs/specs/003-automation)

Phases 1 and 2 (engine) are in. Lanes live on `Track`, resolve once per buffer in
`audio/automation.rs`, and apply as overrides that never write a base value.

### Phase 5 (arranger UI, T-018 – T-026) implemented, not yet live-verified
All rows share the vertical order from `arranger/AutomationRowOrder.gd` so the tracklist
header and the timeline row stay aligned. Point edits go through `history/AutomationActions.gd`
(one undo step per gesture, drags merge), and `Timeline` routes cut/copy/paste/duplicate/delete to
the automation manager whenever a point selection or range is active, else to the clip path.
Unresolved lanes (REQ-024) are marked and drawn distinctly, stop syncing to the engine but keep
every point (`Track.refresh_automation_resolution`, driven by the linked channel's structure
signals), and log one warning per transition.

- `tests/run_all.sh`: all 32 scripts pass, including the new
  `tests/test_automation_range_ops.gd` (T-025: 1-bar copy → paste at bar 3 lands shifted with
  curves intact, overwrite inside the span, undo restores, anchor priority).
- After adding new `class_name` scripts, run `godot --headless --path Godot --editor --quit` once
  or the whole headless suite fails on the stale `global_script_class_cache.cfg` (22 spurious
  failures this session until regenerated).
- Still open: every "Verify: live" item in tasks.md T-018–T-026 (needs the engine running and a
  human ear), plus phase 6 (T-027 docs) and the phase-7 walk (T-028).

### Working
- `cargo test`: 89 unit tests pass, 15 of them new in `audio/automation.rs`. `cargo fmt` clean.
- Live (OSC only, no UI yet): all seven `/track/{id}/automation/*` addresses dispatch and apply
  against the running engine; an unparseable target logs exactly one warning and is dropped; no
  `PluginParameterValueChanged` echo appears in the log.

### T-010 finding — the 5 ms fader smoothing is acceptable, unchanged
`Channel::get_smoothed_gain`'s one-pole has tau = 5 ms, so a full-scale step on an automated
volume lane reaches 90% in ~11.5 ms and 99% in ~23 ms (measured by
`automation_volume_step_settles_within_the_fader_smoothing`, which pins those numbers). At 120 BPM
a sixteenth note is 125 ms, so a step lane reads as a fast fade rather than a gate, and the
smoothing that prevents zipper noise on a moving lane stays in place. No change made to
`types.rs` or `mixing.rs`. **Still to confirm by ear** — a step lane alternating 0.0/1.0 every
beat should sound soft-edged, not smeared; if it smears, shorten the constant only while
`automation_volume` is `Some`.

### Not verified
- Everything audible: no UI exists yet, so nothing has been heard. The phase-7 walk (T-028)
  covers it.
- Plugin IPC under a moving lane (the dedup is unit-tested, the ring is not).

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
