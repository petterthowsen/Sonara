# Sonara DAW - Project Status

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
