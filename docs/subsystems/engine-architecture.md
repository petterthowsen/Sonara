# Audio Engine Architecture

### Thread Model

The Rust audio engine keeps slow work off the real-time path:

- **Main Thread**: Owns `OscServer` (`osc/server.rs`), initializes systems, relays OSC commands to the command thread (`osc/routes/` parses each address into an `AudioCommand`), and brokers GUI events. A separate status thread (`osc/status.rs`) turns `EngineStatus` into OSC messages with the pure `osc/encode.rs::encode_status`.
- **Command Thread** (`command_worker/`): `CommandWorker` applies `AudioCommand`s to the `EngineState` (`audio/state.rs`) it shares with the audio callback through `Arc<Mutex<_>>`. It holds the lock only to read or swap state: plugin scans, device construction and teardown, and plugin subprocess IPC (GUI open/close, activation) run with the lock released. It is the only thread that adds or removes channels and devices, which is what makes releasing the lock mid-command safe. `command_worker/mod.rs` has the flat `handle` dispatch; the work lives in `device_tick.rs` (the 100 ms device poll and plugin stats), `plugins.rs`, `devices.rs`, `project.rs`, `render.rs` and `audio_config.rs`. Fast commands go through `commands/mod.rs::process_command` under the lock (`apply_locked`).
  - **`CommandEffects`** (`commands/mod.rs`): `process_command(state, cmd, buffer_size, &mut effects)` never sends and never frees. Statuses go into `effects.statuses` (in the order the command produced them) and objects the command removed (a clip, replaced PCM) into `effects.trash`. `apply_locked` locks, applies, unlocks, then sends the statuses and drops the trash, so a full status channel or a large free can't make the callback miss its `try_lock`. Known exceptions: `SamplerDevice` and `SfizzDevice` send loading states through their own `status_tx` from inside commands, and a few small drops (`unwrap_if_empty`, `clear_modulators`, `remove_zone`) still happen under the lock.
- **Audio Callback Thread**: Real-time audio generation (high priority, no allocations). Takes the state with `lock_state_for_callback` (`stream.rs`): spins on `try_lock` for up to `STATE_LOCK_BUDGET` (1 ms), then outputs silence for that buffer.
- **Stream Thread** (`stream.rs`, "audio-stream"): owns the CPAL output stream (`Stream` is `!Send`) and its watchdog, which reopens the stream when callbacks stall. The command thread drives it through `StreamControl` (`stop`, `resolve`, `start`) to change device, rate or buffer size (Phase 7, see below).
- **PipeWire Monitor** (`pipewire.rs`): every 3 s reads the graph with `pw-top -b`, `pw-dump` and `pw-metadata`, reports quantum/rate changes to the command thread and adds PipeWire errors on the engine's node to the xrun counter. Exits when the tools aren't installed.
- **Render Thread** (`audio/render/`, "engine-render"): runs one offline render at a time (export, stems), started by `AudioCommand::StartRender` on the command thread. It calls `process_audio` and `mix_and_output` with its own clock, locking the state for one block at a time and writing files with the lock released. While `EngineState::rendering` is set the live callback outputs silence without locking, transport commands are ignored and `BlockClock` is in offline mode (below). Wire format: `osc-protocol.md` › Offline Rendering.
- **Window Thread**: Dedicated winit loop (`WindowManager`) that creates/resizes/destroys plugin host windows based on messages from the main thread; required for X11/Wayland event handling.
- **AudioFileService Workers**: Four-thread job pool that performs blocking audio decode, resampling, and peak-file generation off the real-time path. Each job decodes once: native-rate chunks feed `PeakBuilder` (`io/peaks.rs`, peaks in source-sample space) and resampled chunks fill the interleaved playback buffer, the only full copy of the audio. It sends `DecodeReady` with the PCM, then writes the peak file atomically (temp file + rename) and sends `WaveformReady`. A valid cached peak file (`waveform_cache.rs`, keyed by path, size and mtime) skips the peak work. Format: `osc-protocol.md` › Waveform Cache Format. A separate sample thread answers `/audiofile/samples` (raw native-rate samples for deep zoom) from `io/sample_reader.rs`, which seeks in the source file and caches the last decoded window per file; decode jobs register `cache_key → path` for it.
- **Communication**: Crossbeam unbounded MPMC channels carry commands (main → command thread) and statuses (command/audio threads → main), plus `std::sync::mpsc` channels from statuses → main loop → window thread. The command thread and audio callback share `EngineState` through a mutex.

Commands flow: OSC → Main thread → Command thread → `EngineState` → Audio thread.
Status + GUI events flow: Audio/command threads → Main thread → (a) OSC client → Godot, (b) window manager for resize/close handling.

### Audio Processing Pipeline
The audio callback (`Engine/src/audio/processing/`, set up by `engine.rs`) processes audio in this order:
1. Lock the engine state with a bounded `try_lock` (output silence if the command thread still holds it)
2. Clear all channel audio buffers
3. If playing: compute tick boundaries for this block using the device sample rate and update the fractional accumulator
4. Dispatch clip note on/off events to the owning channel with sample-accurate `frame_offset` values so instruments queue MIDI before rendering
5. Render per-frame audio for each track (audio clips + channel device chains) into channel buffers
6. Mix channels: apply gain/pan, route to output channels
7. Output master channel (ID 1) to audio hardware via CPAL
8. Update peak meters for all channels
9. Advance the transport sample counter (`EngineState::advance_sample_position`) and send periodic status updates (playhead, sample position, meters) at ~20 Hz

### OSC Protocol
Uses **resource-based paths** where IDs are embedded in the OSC address (RESTful style).

**Godot → Rust (port 7000)**:
- Transport: `/transport/play`, `/transport/stop`, `/transport/seek [ticks]`
- Channels: `/channel/{id}/create [name]`, `/channel/{id}/volume [db]`, `/channel/{id}/mute [0|1]`
- Tracks & clips: `/clip/create`, `/clip/delete`, `/clip/{id}/add_note`, `/clip/{id}/load_audio_file`
- Audio file jobs: `/audiofile/decode`, `/audiofile/waveform/start`, `/audiofile/waveform/cancel`, `/audiofile/samples`
- Clip instances: `/track/{id}/add_instance`, `/track/{id}/instance/{instance_id}/set_position`, etc.

**Rust → Godot (port 7001)**:
- Transport status: `/status/playhead [ticks]`, `/status/sample_position [samples]`, `/status/playing [0|1]`
- Meter updates: `/channel/{id}/peak [peak_left, peak_right]`
- Clip lifecycle: `/clip/{id}/load_state [state, req_id, source_path, cache_key, sample_rate, channels, message]`
- Audio file service: `/audiofile/decode/ready`, `/audiofile/waveform/ready`, `/audiofile/samples/data`, `/audiofile/progress`, `/audiofile/error`

Full message catalog: `docs/subsystems/osc-protocol.md`.

### File Structure
```
Engine/src/
  main.rs              # `engine` binary: wires logging, engine, window manager, file service, OSC server
  lib.rs               # The library crate: every module, used by `engine` and `plugin_host`
  logging/             # mod.rs (log files, subscriber setup), rotate.rs (session rotation), forwarder.rs (WARN/ERROR to Godot via /log)
  window_manager.rs    # winit thread hosting plugin GUI windows
  bin/plugin_host.rs   # `plugin_host` binary (CLAP subprocess entry point)
  plugin_host/         # Subprocess host implementation (see engine-plugin-architecture)
  audio/
    mod.rs             # Module declarations and re-exports (Channel, Clip, Track, ...)
    engine.rs          # AudioEngine: builds the state, opens the default stream, starts the command thread
    state.rs           # EngineState (shared with the callback), DeviceLookupError, device_mut/device_as_mut
    stream.rs          # Stream thread + watchdog, device enumeration, config selection, the audio callback
    pipewire.rs        # PipeWire graph monitor (quantum, rate, errors) and the buffer-vs-quantum rule
    command_worker/    # Command thread: mod.rs (struct, run, handle dispatch, apply_locked), device_tick.rs,
                       # plugins.rs, devices.rs, project.rs, render.rs, audio_config.rs (reconfiguring the stream)
    commands/          # mod.rs (AudioCommand enum, process_command dispatcher, CommandEffects), status.rs (EngineStatus),
                       # and one file per domain: transport, channel, track, clip, device, sampler, layer,
                       # modulation, plugin, device_data
    processing/        # Audio callback stages: mod.rs (process_audio), live_midi.rs, timeline.rs, clip_midi.rs, clip_audio.rs
    mixing/            # mix_and_output: mod.rs (passes, master output), routing.rs (routes, sends, aux sources), solo.rs
    channel/           # Channel: mod.rs, chain.rs (device chain, notes), meter.rs, pan.rs, send.rs
    clip.rs            # Clip, ClipInstance, AudioPlayback (time-stretch maths)
    track.rs           # Track
    project.rs         # ProjectSettings
    types.rs           # ID aliases (Tick, ChannelId, ...) and ParamSetValue
    automation.rs      # Automation lanes applied once per block
    tempo_map.rs, time_signature_map.rs, transport.rs # Tempo and time signature maps, the per-block Transport snapshot
    render_scratch.rs  # Preallocated scratch lists and per-channel mix buffers for the callback
    analysis/          # Mix analyzer (spec: docs/analyze-plan.md): per-bar loudness/band/peak/stereo metrics, scale.rs digit scale
    render/            # Offline rendering: RenderJob, the render thread (worker.rs), WAV output (wav.rs)
    midi_types.rs      # MidiEvent, lock-free MidiEventQueue, MidiRouting
    modulation/        # Device modulators (spec 018): kinds.rs (kind tables), state.rs (per-instance
                       # runtime), lfo.rs/envelope.rs (shared DSP), matrix.rs (route matrix),
                       # host.rs (ModulatedDevice wrapper, mono path), voice.rs (VoiceModSpec)
    devices/
      mod.rs             # Module list and re-exports only
      device.rs          # AudioDevice trait, DeviceVariant, ports, FileLoadingSupport, DefaultModulator
      params.rs          # ParamInfo, ParamType, norm/real conversions
      sleep.rs           # DeviceSleepState, has_audio_signal
      factory.rs         # DeviceFactory: builds devices by type/ID, built-in device metadata;
                         # EFFECT_IDS + create_effect for the built-in effects (spec 012)
      param_table.rs     # Static parameter tables (ParamSpec, flatten, slot_table, ParamValues)
      effects/           # effect.rs (pass_through, TailSleep), chorus, compressor, delay, eq, filter, multiband,
                         # phaser, reverb, utility (spec 017), spectrum_analyzer, effect_conformance.rs
      instruments/       # polysynth/ (mod.rs device, voice.rs, params.rs), sampler/ (mod.rs device, params.rs,
                         # regions.rs, voice.rs, multisample.rs, playback.rs, zones.rs, tests.rs),
                         # sfizz_device.rs + sfizz_keys.rs, drums/ (DrumHost and the four voices), drum_conformance.rs
      containers/        # container.rs (DevicePath, run_chain), chain.rs, layer.rs, drum_machine.rs
      note_fx/           # Note effects (spec 027)
      clap_host/         # CLAP subprocess adapter and plugin scanner
    dsp/
      mod.rs             # Shared DSP primitives (oscillators, envelopes, SIMD helpers)
      delay_line.rs      # Ring buffer with linear/Hermite fractional reads
      denormal.rs        # flush_denormals_to_zero (called at the top of every callback)
      env_follower.rs    # Peak/RMS envelope follower (attack/release)
      gain.rs            # dB helpers, DcBlocker, dry/wet Mix laws
      interleave.rs      # Stereo interleave/deinterleave (AVX/SSE/NEON)
      linear_svf.rs      # Linear SVF: EQ responses (bell, shelves, cuts, notch) + exact magnitude_db
      one_pole.rs        # TPT one-pole: LP/HP (6 dB/oct) and all-pass (phaser stage)
      oscillator.rs      # PolyBLEP oscillators; process_block_ramped glides the pitch across a block
      oversampler.rs     # 2x/4x polyphase IIR half-band oversampling (no reported latency)
      smoothing.rs       # SmoothedParam
      spectrum.rs        # Windowed FFT → smoothed dBFS spectrum (analyser, EQ)
      svf.rs             # ZDF state-variable filter, drive, resonance compensation (synth filter)
      tempo_sync.rs      # Shared sync choice list (Off, 4/1 … 1/32 straight/dotted/triplet)
      test_util.rs       # Test-only signals and measurements (tone amplitude, spectrum, T60)
    ipc/
      mod.rs             # Shared-memory IPC for out-of-process plugin hosting
      protocol.rs
      process/           # ProcessManager (mod.rs), PluginProcess (process.rs), launch.rs, crash.rs, routing.rs, connection.rs
      shared_memory.rs
      platform_shm.rs
    io/
      mod.rs                 # IO module declarations
      audio_file_service.rs  # Async decode + peak file coordinator
      decoder.rs             # Symphonia-based streaming decoder + resampler (native and resampled chunk callbacks)
      peaks.rs               # Streaming PeakBuilder: min/max/RMS + 3 band energies per block, nested levels
      waveform_cache.rs      # Peak file format v2 (texture-shaped RGBA16F planes), cache key, validation
      sample_reader.rs       # Raw native-rate sample windows for deep-zoom waveforms
  osc/
    mod.rs           # Module declarations
    server.rs        # OscServer: receive loop, GUI events, AFS polling, send_message
    status.rs        # Status thread: EngineStatus → OSC, heartbeat, engine stats
    encode.rs        # encode_status: EngineStatus → OSC messages (pure, unit-tested)
    gui.rs           # GuiEvent and applying it to the WindowManager
    audio_files.rs   # Audio file service events and pending clip/device sample loads
    parse.rs         # Args/ArgError (typed OSC argument reader) and shared parsers
    routes/          # One file per address area: transport, project, channel, track, clip, device,
                     # device_slots, plugin, audio, render, audiofile; mod.rs dispatches on the first segment

Godot/              # Godot 4.7 UI App
```

## Key Implementation Details

### Timing and Synchronization
- Audio engine is the **master clock** (driven by audio callback)
- Tick-based sequencing with fractional accumulation for sub-sample accuracy
- 960 PPQ (pulses per quarter note)
- Playhead updates sent to Godot at 20Hz, interpolated in Godot UI smoothness
- `EngineState` maintains both `current_tick` and `current_sample_position`; the latter is incremented per callback and exposed to Godot via `/status/sample_position`.
- **Tempo map.** `EngineState.tempo_map` (`audio/tempo_map.rs`, set by `/transport/tempo_map`, empty = static `settings.tempo`) drives the clock. `process_audio` fills `RenderScratch.frame_tick_rates` (ticks per sample for every frame, walking the map with a `TempoCursor`) once per buffer; MIDI tick collection and the audio-clip loop both read that slice. Seconds use the closed-form ramp integral, matching Godot's `TempoMap.gd`.
- **Transport snapshot.** `audio/transport.rs` builds a `Transport` (tempo, tempo change per sample, playing, beats, seconds, bar start/number, time signature) at the block's first frame and `devices::apply_transport` pushes it to every device, nested ones included, before the not-playing early return.
- Constant-tempo `ProjectSettings::{ticks_to_samples,samples_to_ticks}` are only valid when no tempo map is active; clock advance goes through the tempo map, and audio-clip source positions use `AudioPlayback::clip_source_frame` (the clip's recorded-BPM timeline).

### Offline Rendering
- `render::run_render` takes the engine over (sets `rendering`, stops the transport, remembers the playhead), waits until no device is loading and the range's audio clips are decoded, resets every device, switches CLAP plugins to offline mode and seeks to the start tick.
- The range ends on the frame before the end tick's MIDI would be dispatched: `processing/timeline.rs::frames_before_tick` runs the same tick arithmetic as `process_audio`, so a note on the end tick never leaks into the tail. The tail then renders with the transport stopped (fixed length, or until the master stays below −90 dBFS for 1 s).
- Each block drains live MIDI, wakes every device (polysynth and sampler sleep on wall-clock time, which would make two renders of the same range differ), and publishes an offline plugin deadline. After `mix_and_output` every channel buffer holds that channel's post-fader, post-pan output, which is what stems are copied from.
- Analysis jobs (`RenderJob::analysis`, `/render/analyze`) feed the same blocks to an `Analyzer`. The worker copies the tapped channels' buffers out each block, passing the block's start tick (`current_tick` plus the fractional accumulator). The render starts at `render_start_tick()` (tick 0 or a pre-roll) while the analyzer accumulates only inside the requested range, and the tail isn't analyzed. The JSON result is written as `<path>.part`, then renamed.
- `end` always runs: reset devices, plugins back to realtime, playhead restored, `rendering` cleared. Two renders of the same range are bit-identical for built-in devices.

### Sample-Accurate Scheduling
- `processing/mod.rs::process_audio()` precomputes `(tick, frame_offset)` pairs for the current buffer so note events line up with the physical device sample rate (never the project setting).
- Each channel forwards MIDI to the first device in its chain via `Channel::send_midi_event_to_devices()`; instruments must respect the provided `frame_offset` inside their next `process_block`.
- `AudioDevice::send_midi_event()` is the single contract point—builtins (PolySynth, Sfizz) and the CLAP adapter queue events and sort them before rendering so envelopes and plugin voices line up exactly with buffer boundaries.
- `PolySynthDevice` renders spans between queued MIDI offsets, reprocessing active voices for each segment so note-on/note-off transitions land on the exact sample; keep `queued_midi` offsets relative to the upcoming block and sorted by insertion.

### Live MIDI Input
- Godot's `MidiManager` autoload routes physical `InputEventMIDI` and virtual-keyboard events to armed channels, sending `/channel/{id}/midi_event [channel_id, message, midi_channel, pitch, velocity, timestamp_us]` (channel setup via `/channel/{id}/midi_input_device` and `/channel/{id}/record_armed`).
- The OSC server stamps each event with `received_at` (an `Instant`), and `AudioCommand::MidiEvent` pushes it onto the channel's lock-free `midi_queue` (`midi_types::MidiEventQueue`, a crossbeam `SegQueue`).
- At the start of each callback `processing/live_midi.rs::schedule_live_midi_events` drains every queue into `Channel::scheduled_midi_events`. Live input plays with a fixed latency of one buffer: an event that arrived `dt` before the callback lands `dt` before the end of the buffer, and events older than one buffer play at frame 0. Queue order is arrival order, so no sort is needed.

### Device Sleep
- Each device carries a `DeviceSleepState` (`devices/sleep.rs`): after `DEFAULT_SLEEP_TIMEOUT` (3 s) with no signal above `SLEEP_THRESHOLD` and no MIDI/parameter activity, the device sleeps and `Channel::process_device_chain` skips its processing.
- MIDI input wakes a device immediately (`mark_activity`), and so does audio reaching a sleeping device's input (`containers/container.rs::run_chain` checks the input before skipping it).
- Effects with tails use `effects/effect.rs::TailSleep`: they sleep only after 3 s plus their tail of quiet, and never while the tail is infinite (freeze, feedback ≥ 100 %).
- Sleep transitions become `EngineStatus::DeviceSleepStatus`, forwarded as `/channel/{id}/device/{pos}/sleep [0|1]`.

### Built-in Device Advertisement
- Godot requests built-in metadata with `/builtin/request`; the engine replies via `AudioCommand::AdvertiseBuiltinDevices` by instantiating each builtin at runtime (`sonara.builtin.polysynth`, `.delay`, `.sfizz`, `.spectrum_analyzer`) and emitting `/builtin/info` messages.
- Metadata includes channel counts, MIDI capability, file-loading support, and parameter descriptors so the Godot browser can build device assets without hardcoding names or parameters.
- `PolySynthDevice` is the default polyphonic instrument built on the in-house DSP module (`audio::dsp`) with SIMD-accelerated block mixing. (The old FunDSP prototype has been removed; the `fundsp` dependency in `Cargo.toml` is legacy.)
- `UtilityDevice` (`sonara.builtin.utility`, spec 017) is a plain effect in `EFFECT_IDS`. Its path is phase invert → bass mono → width → balance → gain × mute, and it passes through bit-exact while every control sits at its default.
  - Width works in M/S (M = (L+R)/2, S = (L−R)/2). Up to 100 % only the side is scaled (mid = 1, side = w), so narrowing never changes the mono sum. Above 100 %, mid = 1/n and side = w/n with n = √((1 + w²)/2). That keeps the level of uncorrelated M/S constant: 200 % is mid −4 dB, side +2 dB. Mono forces w = 0.
  - Pan is a balance law. The near side stays at unity, and the far side follows cos(|p|·π/2) to silence at ±100 %.
  - Bass Mono is a one-crossover `MultibandSplitter` (LR4). The low band is summed to mono and added back to the high band. It fades in and out over the 20 ms ramp, and the splitter runs only while it is on or fading. Phase invert is a smoothed ±1 gain, and Gain's −60 dB floor is silence.
- `SpectrumAnalyzerDevice` is a stereo utility that mirrors its input to output while queueing FFT frames; it only performs analysis when Godot holds an active `"spectrum"` subscription to keep the audio callback light.

### Device Data Streams
- `AudioDevice` now exposes `subscribe_data`, `unsubscribe_data`, and `poll_device_data`; built-ins default to no-op but visualization-capable devices override these hooks to stream binary payloads without allocations in the hot path.
- Godot issues `/channel/{id}/device/{pos}/data/subscribe|unsubscribe` (`AudioCommand::{Subscribe,Unsubscribe}DeviceData`) so the audio thread knows which payloads to produce.
- During `mixing/mod.rs` pass 1 and post-routing bus processing the engine calls `device.poll_device_data()`; any yielded `(data_type, Vec<u8>)` becomes `EngineStatus::DeviceData`, which `osc/encode.rs` forwards as `/channel/{id}/device/{pos}/data` with `[String data_type, Blob payload]`.

### DSP Utilities
- `Engine/src/audio/dsp` centralizes real-time safe building blocks (`Oscillator`, `AdsrEnvelope`) so instruments and effects share optimized code paths.
- SIMD variants (AVX/SSE/NEON) live alongside scalar fallbacks; callers never branch on CPU features—the helpers detect support internally.
- DSP helpers must remain allocation-free during audio callbacks; any scratch buffers are pre-sized by the caller (e.g., `PolySynthDevice` reuses `voice_buffer`/`temp_buffer`).

### Audio Clip BPM-Based Time Stretching
Audio clips automatically time-stretch and pitch-shift based on project BPM:

**Key concepts:**
- Each `Clip` (audio) stores `recorded_bpm: f32` = BPM the audio was originally recorded at
- `ClipInstance` playback position is tracked per-instance in `Track.audio_playback_positions: HashMap<ClipInstanceId, f64>`
- Stretch factor calculated as: `stretch = project_bpm / clip.recorded_bpm`
- Example: Audio recorded at 120 BPM playing in a 200 BPM project → stretch = 1.667x (faster + pitched up)

**Implementation details:**
- Audio playback position advances per-frame with fractional sample tracking (not per-tick) to maintain smoothness
- Advance amount per frame: `(stretch_factor × device_sample_rate) / clip_sample_rate`
- Linear interpolation handles fractional sample positions smoothly across any stretch factor
- Looping respects stretch factor: loop points are converted to clip samples and scaled by stretch
- Positions reset on Stop/Seek commands, and removed when clips finish playing
- **Critical**: Position must be tracked continuously frame-by-frame, not recalculated from tick position (which causes aliasing at high stretch factors)

### Audio Mixing Implementation
**`mixing/mod.rs::mix_and_output` orchestrates four passes, keeping the audio thread real-time safe:**

0. **Route counting**
   - `count_route_inputs` counts each channel's incoming routes and sends (`MixBuffers::pending_inputs`). Channels with inputs, and master, are route targets.

1. **Device Pre-Pass (channels that are not route targets)**
   - Instruments/effects render via `Channel::process_device_chain()` before any fader math.
   - CLAP/Sfizz adapters flush pending parameter changes to the UI here.
   - Route targets (buses, master) are skipped; they process in pass 3.

2. **Fader & Pan Pass**
   - Applies smoothed gain and pan to every audible channel (muted or solo-excluded channels are cleared).
   - This establishes the "post-fader" buffer used for metering and post-fader sends.

3. **Routing in Dependency Order**
   - A channel finishes once `pending_inputs` reaches 0, so each channel processes exactly once per buffer, after everything routing into it (bus → bus → master).
   - Finishing a route target runs its device chain **even with no input** (reverb/delay tails keep ringing), then applies its pan. Silenced targets are cleared.
   - Finishing any channel routes it onward (`route_channel`): output and post-fader sends read the buffer; pre-fader sends tap the pre-pass copy with pan reapplied. Only the destination fader gain is applied, never pan.
   - A routing cycle is broken at the first unfinished channel; already finished targets receive nothing.

4. **Master Output**
   - The CPAL buffer is cleared, then master (ID 1) is written to its output pair: 1000 = outputs 1/2, 1001 = 3/4, … on the running device. A pair the device lacks plays on 1/2. Peaks are computed by the callback afterward.

**Invariants:**
- Never allocate during any pass; all temporary buffers are pre-sized at initialization.
- Pan occurs once per audible channel in pass 2 and once per route target in pass 3.
- Routes and sends ignore invalid targets (none, self, IDs ≥1000, missing channels). Master never routes onward and is never silenced by another channel's solo.

### Channel Routing and IO
**Channel Types:** `INSTRUMENT`, `AUDIO`, `BUS` (Godot `Channel.ChannelType`); the master is channel ID 1 rather than a separate type

**Routing Hierarchy:**
- Tracks target channels via `Track.default_channel_id`.
- Channels forward audio with `output_channel_id` (default = 1 = Master).  
- Master channel (ID 1) routes to hardware outputs (ID ≥ 1000).  
- ID allocation: 0 = null/no output, 1 = Master, 2-999 = user channels/buses, 1000+ = stereo output pairs on the selected output device (`HARDWARE_OUTPUT_BASE`).

### Output device, sample rate and buffer size (Phase 7)
- Godot sends `/audio/config/set <device> <rate> <buffer>` (Settings › Audio › Output). `CommandWorker::apply_audio_config` stops the stream, resolves the config on the stream thread (the device may not support the rate), prepares every device for a new rate with `AudioDevice::prepare(rate, max_frames)` while no callback runs, updates `device_sample_rate`, and starts the stream. A device that won't open falls back to the default device, then to 48 kHz/1024.
- The buffer size is the ALSA **period** (frames per callback); cpal 0.15 sets the period to a quarter of `BufferSize::Fixed`, so the engine asks for `ALSA_PERIODS` (4) periods. cpal's callback can deliver the whole buffer at once, so the period is capped at 2048 to fit the 8192-frame preallocation (`MAX_BLOCK_FRAMES`). Buffer-only changes never reallocate.
- CLAP plugins are re-activated at the new rate (the host deactivates first); a plugin that finishes loading at the old rate is caught by the device tick (`needs_reactivation`). Clips keep playing at the right pitch (playback compensates for `Clip::audio_sample_rate`); `/audio/config/changed` makes Godot reload them at the new rate.
- PipeWire: when the graph quantum is larger than the ALSA buffer (4 periods), the engine reopens with the smallest power-of-two period whose buffer holds it, and goes back to the requested period when the quantum drops. It never writes PipeWire's settings.

**Sends:**  
- `Channel.send_channels` holds `Send { target_channel_id, amount_db, pre_fader, muted }`.  
- Pre-fader taps run before fader smoothing; post-fader taps run after.  
- Send returns respect the destination channel's gain so buses behave consistently with direct routes.

**UI:** Mixer menus only list valid targets (Master + BUS for regular channels, hardware outputs for Master). Routing changes propagate via OSC + Godot signals.

### Lock-Free Design
The audio callback **never blocks**:
- Uses `try_recv()` instead of blocking `recv()`
- Uses `Mutex` with immediate failure if lock is contested (skip buffer on failure)
- No heap allocations in audio thread
- Pre-allocated channel buffers (sized at initialization)

## Command classification (input for #1 phase 2)

Issue #1 phase 2 removes `Arc<Mutex<EngineState>>`. This section is the map it starts from: what each `AudioCommand` does to the state, and which `EngineState` fields each callback stage touches. Nothing here changes behavior; the engine cleanup (`docs/engine-architecture-cleanup-plan.md`) only prepared the ground: `CommandEffects` already keeps status sends and frees out of the locked section, and the callback stages take only the fields they use.

Classes:

- **graph edit**: a pure state change that could become a message to audio-thread-owned state. Most are one field assignment. Some grow a `Vec` or send a lock-free queue entry; the note says so. Those allocate today and would need pre-reserved capacity or a build step off the audio thread.
- **build/teardown**: needs allocation or slow work off the audio thread (channels, tracks, clips, PCM, devices, maps, wrappers). The object is built on the command thread and handed over, and what it replaces is dropped on the command thread. "Done under the lock today" marks the ones that still allocate or free while the state lock is held.
- **query**: answers Godot; may need IPC or instantiate devices. No audio-thread state needed beyond a read.
- **command thread only**: plugins, the stream and renders. They never need to reach the audio thread.

| Command | Class | Handled in | Notes |
|---|---|---|---|
| `InitProject` | graph edit | `commands/transport.rs` | Sets the settings; creates the master channel the first time (allocates). |
| `ClearProject` | build/teardown | `command_worker/project.rs` | Detaches channels, tracks and clips under the lock, drops them after it. |
| `Play` | graph edit | `commands/transport.rs` | Sets `is_playing`, asks for a playhead MIDI dispatch. |
| `Pause` | graph edit | `commands/transport.rs` | Releases clip notes on every channel. |
| `Stop` | graph edit | `commands/transport.rs` | Resets the playhead and positions, releases notes. |
| `Seek` | graph edit | `commands/transport.rs` |  |
| `SetLoop` | graph edit | `commands/transport.rs` |  |
| `StartRender` | command thread only | `command_worker/render.rs` | Spawns the render thread. |
| `CancelRender` | command thread only | `command_worker/render.rs` |  |
| `SetTempo` | graph edit | `commands/transport.rs` |  |
| `SetTempoMap` | build/teardown | `command_worker/project.rs` | Map built outside the lock, swapped in; the old one is dropped after. |
| `SetTimeSignatureMap` | build/teardown | `command_worker/project.rs` | Same as `SetTempoMap`. |
| `SetTimeSignature` | graph edit | `commands/transport.rs` |  |
| `SetProjectScale` | graph edit | `commands/transport.rs` |  |
| `CreateChannel` | build/teardown | `commands/channel.rs` | `Channel::new` allocates its buffers; done under the lock today. |
| `RemoveChannel` | build/teardown | `command_worker/project.rs` | Removes the channel and its devices, dropped after the lock. |
| `SetChannelVolume` | graph edit | `commands/channel.rs` |  |
| `SetChannelPan` | graph edit | `commands/channel.rs` |  |
| `SetChannelPanMode` | graph edit | `commands/channel.rs` |  |
| `SetChannelPanWidth` | graph edit | `commands/channel.rs` |  |
| `SetChannelMute` | graph edit | `commands/channel.rs` |  |
| `SetChannelSolo` | graph edit | `commands/channel.rs` |  |
| `SetChannelRoute` | graph edit | `commands/channel.rs` | Routing to the master (id 1) goes through `command_worker/mod.rs::set_master_route`, which also touches the stream. |
| `SetAuxOut` | graph edit | `commands/channel.rs` |  |
| `SetMidiInputDevice` | graph edit | `commands/channel.rs` |  |
| `SetRecordArmed` | graph edit | `commands/channel.rs` |  |
| `MidiEvent` | graph edit | `commands/channel.rs` | Pushes onto the channel's lock-free `midi_queue`; could skip the state entirely. |
| `AddSend` | graph edit | `commands/channel.rs` | Grows `send_channels` (a `Vec` push). |
| `RemoveSend` | graph edit | `commands/channel.rs` |  |
| `SetSendAmount` | graph edit | `commands/channel.rs` |  |
| `SetSendPreFader` | graph edit | `commands/channel.rs` |  |
| `SetSendMute` | graph edit | `commands/channel.rs` |  |
| `CreateTrack` | build/teardown | `commands/track.rs` | Allocates the track and its maps. |
| `SetTrackRoute` | graph edit | `commands/track.rs` |  |
| `CreateAutomationLane` | graph edit | `commands/track.rs` | Grows the lane list; answers with a status. |
| `DeleteAutomationLane` | graph edit | `commands/track.rs` |  |
| `SetAutomationLaneBypass` | graph edit | `commands/track.rs` |  |
| `AddAutomationPoint` | graph edit | `commands/track.rs` | `Vec` insert. |
| `UpdateAutomationPoint` | graph edit | `commands/track.rs` |  |
| `RemoveAutomationPoint` | graph edit | `commands/track.rs` |  |
| `ClearAutomationLane` | graph edit | `commands/track.rs` |  |
| `CreateClip` | build/teardown | `commands/clip.rs` | Allocates the clip. |
| `RemoveClip` | build/teardown | `commands/clip.rs` | Moves the clip into `effects.trash`. |
| `AddNoteToClip` | graph edit | `commands/clip.rs` | `Vec` push into the clip's notes. |
| `RemoveNoteFromClip` | graph edit | `commands/clip.rs` |  |
| `UpdateClipNote` | graph edit | `commands/clip.rs` |  |
| `BeginLoadAudioClip` | build/teardown | `commands/clip.rs` | Marks the clip loading and trashes old PCM. |
| `LoadAudioClip` | build/teardown | `commands/clip.rs` | Installs PCM decoded by the `AudioFileService`; the replaced PCM goes to `effects.trash`. |
| `FailAudioClipLoad` | build/teardown | `commands/clip.rs` | Clears the PCM (trash). |
| `CreateClipInstance` | graph edit | `commands/clip.rs` | `Vec` push on the track. |
| `RemoveClipInstance` | graph edit | `commands/clip.rs` |  |
| `UpdateClipInstancePosition` | graph edit | `commands/clip.rs` |  |
| `UpdateClipInstanceTranspose` | graph edit | `commands/clip.rs` |  |
| `UpdateClipInstanceGain` | graph edit | `commands/clip.rs` |  |
| `UpdateClipInstanceMute` | graph edit | `commands/clip.rs` |  |
| `UpdateClipInstanceLoop` | graph edit | `commands/clip.rs` |  |
| `UpdateClipInstanceReverse` | graph edit | `commands/clip.rs` |  |
| `AddDeviceToChannel` | build/teardown | `command_worker/devices.rs` | Device (or plugin load) built outside the lock, inserted under it. |
| `RemoveDeviceFromChannel` | build/teardown | `command_worker/devices.rs` | Device detached under the lock, dropped after it. |
| `MoveDevice` | graph edit | `commands/device.rs` | Reorders a chain. |
| `ClearChannelDevices` | build/teardown | `command_worker/devices.rs` | Detaches the chain, drops it after the lock. |
| `SetDeviceParameter` | graph edit | `commands/device.rs` | The hottest command; plugins also get it via `PluginIpcHandle`. |
| `AddModulator` | build/teardown | `commands/modulation.rs` | Wraps the device in a `ModulatedDevice` (allocates) on first use. |
| `RemoveModulator` | build/teardown | `commands/modulation.rs` | May unwrap an empty `ModulatedDevice` (drop under the lock). |
| `SetModulatorParameter` | graph edit | `commands/modulation.rs` |  |
| `SetModulatorRoute` | graph edit | `commands/modulation.rs` |  |
| `ClearModulators` | build/teardown | `commands/modulation.rs` | Drops the modulators and the wrapper under the lock. |
| `SetDeviceActive` | graph edit | `commands/device.rs` | A subprocess plugin goes through `command_worker/plugins.rs::set_device_active` (IPC). |
| `SetDeviceEnabled` | graph edit | `commands/device.rs` |  |
| `LoadDeviceFile` | build/teardown | `commands/device.rs` | Loads an SFZ file into the device; slow, done under the lock today. |
| `BeginLoadDeviceSample` | graph edit | `commands/sampler.rs` | Sets the loading state. |
| `LoadDeviceSample` | build/teardown | `commands/sampler.rs` | Installs decoded PCM in a Sampler zone. |
| `FailDeviceSampleLoad` | graph edit | `commands/sampler.rs` |  |
| `SetSamplerMode` | build/teardown | `commands/sampler.rs` | Reserves or drops the zone and group capacity. |
| `SetSamplerZone` | graph edit | `commands/sampler.rs` |  |
| `RemoveSamplerZone` | build/teardown | `commands/sampler.rs` | Drops the zone's PCM under the lock today. |
| `SetSamplerZoneGroup` | graph edit | `commands/sampler.rs` |  |
| `RemoveSamplerZoneGroup` | graph edit | `commands/sampler.rs` |  |
| `SetSamplerFocus` | graph edit | `commands/sampler.rs` |  |
| `AuditionDevice` | graph edit | `commands/device.rs` | Sends a note to the device. |
| `DeviceReady` | graph edit | `commands/device.rs` | Applies restored values after a device finished loading, then reports its parameters. |
| `ScanPlugins` | command thread only | `command_worker/plugins.rs` | Scans the plugin directories (slow). |
| `AdvertiseBuiltinDevices` | query | `command_worker/devices.rs` | Instantiates each built-in to report its metadata. |
| `GetPluginParameters` | query | `commands/device.rs` | Answers with the parameter list. |
| `GetDeviceState` | query | `commands/device.rs` | Answers with parameters, zone states and modulators. |
| `SavePluginState` | command thread only | `command_worker/plugins.rs` | Plugin IPC. |
| `LoadPluginState` | command thread only | `command_worker/plugins.rs` | Plugin IPC. |
| `ReloadDevice` | build/teardown | `command_worker/plugins.rs` | Reloads a plugin device (crashed or changed hosting). |
| `SetPluginHosting` | command thread only | `command_worker/plugins.rs` | Changes the `HostingPolicy`. |
| `SetAudioConfig` | command thread only | `command_worker/audio_config.rs` | Stops, resolves and restarts the stream. |
| `RequestAudioConfig` | query | `command_worker/audio_config.rs` |  |
| `RequestAudioDevices` | query | `command_worker/audio_config.rs` |  |
| `PipeWireGraph` | command thread only | `command_worker/audio_config.rs` | From the PipeWire monitor; may reopen the stream. |
| `OpenPluginGui` | command thread only | `command_worker/plugins.rs` | Plugin IPC. |
| `ClosePluginGui` | command thread only | `command_worker/plugins.rs` | Plugin IPC. |
| `SetPluginGuiVisible` | command thread only | `command_worker/plugins.rs` | Plugin IPC. |
| `SetPluginGuiSize` | command thread only | `command_worker/plugins.rs` | Plugin IPC. |
| `SubscribeDeviceData` | graph edit | `commands/device_data.rs` |  |
| `UnsubscribeDeviceData` | graph edit | `commands/device_data.rs` |  |
| `ConfigureDeviceData` | graph edit | `command_worker/devices.rs` | Done on the command thread only because it needs the device handle. |
| `SetLayerSlotVolume` | graph edit | `commands/layer.rs` |  |
| `SetLayerSlotMute` | graph edit | `commands/layer.rs` |  |
| `SetLayerSlotSolo` | graph edit | `commands/layer.rs` |  |
| `SetDrumSlotNote` | graph edit | `commands/layer.rs` |  |
| `SetDrumSlotChokeTargets` | graph edit | `commands/layer.rs` |  |
| `SetLayerSlotNoteMap` | graph edit | `commands/layer.rs` |  |
| `SetLayerSlotSeparateOut` | graph edit | `commands/layer.rs` |  |
| `AuditionLayerSlot` | graph edit | `commands/layer.rs` |  |

Totals: 69 graph edit, 22 build/teardown, 5 query, 12 command thread only (108 commands). "Handled in" is where the logic lives; commands in `command_worker/` are matched in `CommandWorker::handle`, everything else reaches `commands/mod.rs::process_command` through `apply_locked`.

### Stage read/write map

What each audio-callback stage reads and writes. `EngineState` fields: `channels`, `tracks`, `clips`, `settings`, `device_sample_rate`,
`tempo_map`, `time_signature_map`, `loop_region`, `render_scratch`; the atomics `is_playing`, `current_tick`, `fractional_tick_accumulator`,
`dispatch_playhead_tick`; `rendering` is read by the callback before these stages and `block_clock` by plugin adapters.

`process_audio` (`processing/`):

| Stage | Reads | Writes |
|---|---|---|
| live MIDI scheduling (`live_midi`) | `channels[*].midi_queue` (pops), callback start time, `sample_rate` | `channels[*].scheduled_midi_events` |
| automation (`automation::apply_automation`) | `current_tick`; `tracks[*].automation_lanes`, `tracks[*].channel_id` | lane cursors/`last_applied`/`captured_base`; the targeted channel parameters (volume, pan, send amounts, device parameters) |
| transport to devices (inline) | `tempo_map`, `time_signature_map`, `settings`, `is_playing`, `current_tick`, accumulator | `channels[*].devices` (`set_transport`, containers recursively) |
| tick rates (`tempo_map::fill_tick_rates`) | `tempo_map`, `settings`, tick, accumulator | `render_scratch.frame_tick_rates` |
| tick events (`timeline::collect_tick_events_looped`) | tick rates, `loop_region`, `dispatch_playhead_tick` (taken, cleared) | `render_scratch.tick_events`, `render_scratch.loop_wraps`; then `current_tick`, accumulator |
| clip MIDI (`clip_midi`) | `tracks[*].clip_instances`, `tracks[*].channel_id`, `clips[*].midi_notes`, tick events, loop wraps | `render_scratch.note_events`; `channels[*].active_notes` and the devices' note input (`send_clip_note`, `release_clip_notes_at`) |
| audio clip render (`clip_audio`) | `clips[*]` PCM and recorded BPM, `settings.tempo/ppq`, `device_sample_rate`, tick rates, `loop_region`, `tracks[*].channel_id` | `tracks[*].clip_instances[*].playback_position`; `channels[*].buffer_left/right` (added to) |

`mix_and_output` (`mixing/`); `channels` is the only `EngineState` field besides `render_scratch` (`channel_ids`, `parked`, `ready`):

| Stage | Reads | Writes |
|---|---|---|
| route counting (`routing::count_route_inputs`) | `channels[*].output_channel_id`, `send_channels` (ids), `id` | `mix.pending_inputs`, `mix.done`, `mix.is_route_target` |
| solo roles (`solo::assign_solo_roles`) | `mute`, `solo`, `output_channel_id`, `send_channels` (target, muted), `mix.solo_*` | `mix.solo_up`, `mix.solo_down`, `mix.solo_role` |
| aux source marking (`routing::mark_aux_sources`) | `extra_out_targets` | `mix.has_aux_source` |
| aux source pass (`routing::process_aux_sources`) | `mix.has_aux_source`, `extra_out_buffers` | the source channel's device chain, buffers, `sleep_changes` (drained), `extra_out_targets`/`extra_out_buffers` (taken and put back); the child channels' `buffer_left/right` (overwritten); statuses via `try_send` |
| device pre-pass (`device_prepass`) | `mix.is_route_target`, `mix.has_aux_source` | non-target channels' device chains and `mix.cursor`/`chain_start`, buffers, `sleep_changes`; `render_scratch.parked`; statuses via `try_send` |
| pre-fader copy (`routing::copy_pre_fader`) | `send_channels`, `buffer_left/right` | `mix.has_pre_fader_copy`, `mix.pre_fader_left/right` |
| fader and pan (`apply_fader_and_pan`) | `mix.solo_role`, `volume_db`, `pan*`, `automation_*`, `pan_mode`, `mute` | `buffer_left/right` (cleared if silenced), gain smoothing state, `current_gain` |
| routing sweeps (`route_in_dependency_order`: `begin_finish`, `drain_parked`, `route_finished`, `route_channel`) | `mix.pending_inputs`, `mix.done`, `mix.is_route_target`, `mix.solo_role`, `output_channel_id`, `send_channels`, source buffers and pre-fader copies, target fader gain | route targets' device chains, `mix.done`, `mix.pending_inputs`, `mix.pre_fader_*`; target `buffer_left/right` (added to); `render_scratch.ready`/`parked`; statuses via `try_send` |
| master output (`write_master_output`) | `channels[1]` buffers and `output_channel_id` | the device output buffer only |

Not covered here: what the callback does around these stages (state lock, rendering guard, meters) lives in `audio/engine.rs`/`stream.rs`.

## Finding Documentation

- Get docs on Clack via context7 (`/prokopyl/clack`)
