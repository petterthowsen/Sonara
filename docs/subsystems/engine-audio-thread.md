# Audio Thread & Mixing Logic

## Audio Thread Safety (Critical)

The audio callback thread is real-time and must **NEVER**:
- Block on locks (use `try_lock()` and skip the work: output silence or pass audio through)
- Allocate heap memory (`Vec::new()`, `HashMap::new()`, cloning buffers, etc.). Reuse preallocated storage instead: `RenderScratch` on `EngineState` and `MixBuffers` on each `Channel` (`render_scratch.rs`). `std::mem::take` a buffer out and put it back when you need two mutable borrows.
- Call blocking operations (I/O, sleep, channel `recv()`)
- Hold locks across multiple audio operations

**Pattern: Skip on lock failure**
```rust
// Correct: non-blocking, skip the work and retry next buffer
let Ok(mut changed) = self.parameters_changed.try_lock() else {
    return false;
};

// Wrong: blocks the audio thread until the other thread releases the lock
let changed = self.parameters_changed.lock().unwrap();
```

`EngineState` is shared with the command thread (`command_worker.rs`). Anything that thread does with the state lock held must be fast, because the callback gives up after `STATE_LOCK_BUDGET` and outputs silence. Put slow commands (IPC, file or plugin loading, dropping CLAP devices) in `CommandWorker` with the lock released.

## Audio Processing Pipeline

The audio engine processes each callback in this order:

1. **Lock engine state** (`lock_state_for_callback` in `stream.rs`: bounded `try_lock`, silence if the command thread still holds it)
2. **Clear channel buffers** (zero L/R arrays for every channel)
3. **Advance transport & schedule MIDI** (compute tick → `frame_offset` pairs using the real device sample rate, enqueue MIDI on channels)
4. **Render audio** (tracks add clip audio per frame; channel devices consume queued MIDI when their `process_block` runs)
5. **Mix audio** (apply faders/pan, route channels, output hardware)
6. **Meter audio** (peak detection on output)
7. **Send status updates** (20Hz, not every frame)

Location: `Engine/src/audio/processing.rs`

### Audio Clip Loading (Async)
- Heavy lifting (decode, resample, waveform generation) runs in `AudioFileService`, a worker pool created in `main.rs`. Requests arrive via `/clip/{id}/load_audio_file` → `AudioCommand::BeginLoadAudioClip`.
- `osc::server` forwards `AfsEvent::DecodeReady` as `AudioCommand::LoadAudioClip`, which only copies the already-decoded `Vec<f32>` plus metadata into `EngineState`—never invoke Symphonia or Rubato from the audio callback.
- Waveform levels (`AfsEvent::WaveformLevel`) and progress/errors (`AfsEvent::Progress`/`Error`) stay on the main/OSC threads; the audio thread only needs the final PCM buffer and cache key.
- Always guard against stale `req_id`s when handling `LoadAudioClip`; reject outdated events so retries do not clobber newer audio.

## Sample-Accurate MIDI Dispatch

- `process_audio()` builds a `Vec<(Tick, frame_offset)>` so every note on/off from clip instances is tied to an exact sample index inside the upcoming block.
- `Channel::send_midi_event_to_devices()` forwards events to the first device only; instruments must queue and sort them before generating audio.
- `AudioDevice::send_midi_event()` now receives the `frame_offset`; built-ins (`PolySynthDevice`, `SfizzDevice`) and the CLAP adapter honour it to keep envelopes, voice gates, and plugin note-ons aligned with the hardware clock.
- Never translate offsets back to ticks inside devices—use the given `frame_offset` directly against the block you are rendering.

## Mixing Pipeline (`mixing.rs::mix_and_output`)

The mixer now runs five passes to support sends, SIMD-aware devices, and bus effects while keeping the callback allocation-free.

1. **Device Pre-Pass (non-bus channels)**  
   - Calls `Channel::process_device_chain()` on every channel that generates its own audio (instrument/audio/master).  
   - Skips buses so they can process once they hold routed/sent audio.  
   - CLAP/Sfizz adapters flush pending parameter changes to the UI here.

2. **Fader & Pan Pass**  
   - Applies smoothed gain and constant-power pan to each audible channel.  
   - Muted channels, or channels excluded by solo, have their buffers cleared to silence to short-circuit later passes.  
   - This establishes the "post-fader" buffer used for metering and for post-fader sends.

3. **Routing in Dependency Order (routes and sends)**
   - `MixBuffers::pending_inputs` counts each channel's incoming routes and sends. A channel finishes when it reaches 0, so every channel processes exactly once, after all its inputs.
   - Route targets (buses, master) run `process_device_chain()` on finishing, even with no input, so reverb/delay tails ring after playback stops; then they apply their own pan.
   - The finished channel then mixes into its `output_channel_id` and send targets. Pre-fader sends tap `MixBuffers::pre_fader_*` (copied before the device pre-pass) and reapply pan; post-fader sends read the pass-2 buffer.
   - Routes and send returns are scaled by the destination gain (`get_gain()`). Never reapply pan while routing.
   - Solo/mute rules still apply; master never routes onward and is never silenced by solo. Routing cycles are broken at the first unfinished channel.

4. **Master Output & Metering**  
   - Channel buffers are mixed in place, so they already hold post-effect, post-pan audio for peak metering.  
   - Clears the interleaved CPAL buffer (CPAL reuses it), then writes master (ID 1) to its output pair (1000 = outputs 1/2, 1001 = 3/4, …; a missing pair plays on 1/2).  
   - Peak detection still scans both channels, and status updates are throttled to ~20 Hz outside the callback.

## Channel Routing Model

**Channel types**:
- `INSTRUMENT`: Generates MIDI synth audio, routes to Bus or Master
- `AUDIO`: Plays samples via Clips, routes to Bus or Master
- `BUS`: Groups/submixes, receives routed audio, routes to other BUS or Master
- Master (channel ID 1, not a separate type): Final mix, always routes to device outputs

**ID allocation scheme**:
- 0 = null/no output
- 1 = Master
- 2-999 = user channels (INSTRUMENT, AUDIO, BUS)
- 1000+ = stereo output pairs on the selected output device (1000 = outputs 1/2)

**Routing stored as**:
- Regular channels: `channel.output_channel_id` (points to Master by default)
- Master channel: `channel.device_output_id` (an output pair, default 1000; set with `Channel.set_device_output`)

**Sends**:
- `Channel.send_channels` holds `Send { target_channel_id, amount_db, pre_fader, muted }`.
- `pre_fader == true` taps the cloned pre-fader buffer; otherwise it taps the post-fader buffer.
- Sends ignore invalid targets (self, IDs ≥1000, muted/solo-blocked buses) to keep the graph acyclic and real-time safe.

**Implementation**:
```rust
// Route track audio to destination
let dest_id = source_channel.output_channel_id;
let dest = channels.get_mut(dest_id)?;
dest.mix_in(&source_channel);  // Routed audio added to destination
```

## Key Data Structures

**Channel**: Holds stereo audio buffer (L/R arrays), device chain, fader (dB), pan, mute, output routing
- `id`: Channel identifier (1-999 for user channels)
- `buffer_l, buffer_r`: Stereo audio (cleared each frame)
- `volume_db`: Current fader level
- `pan`: -1.0 (left) to +1.0 (right)
- `mute`: If true, buffer stays silent
- `output_channel_id`: Where this channel routes to
- `devices`: Ordered `Vec<Box<dyn AudioDevice>>`; the first entry is the MIDI instrument, the rest are audio effects
- `send_midi_event_to_devices(note, velocity, is_on, frame_offset)`: forwards sample-accurate MIDI to the first device only
- `send_channels`: Vec of `Send` definitions (bus sends/post-fader fx). `Send` stores target channel, gain in dB, `pre_fader`, and `muted` state.

**Track**: Holds sequencing data and routes to a channel
- `default_channel_id`: Which channel renders this track
- `clip_instances`: MIDI/audio clip placements that drive sample-accurate scheduling
- `audio_playback_positions`: Fractional sample cursors for stretching audio clips; cleared when clips end or on stop/seek

## Timing & Synchronization

- Audio callback is master clock (driven by audio hardware)
- Playhead advanced tick-by-tick (960 PPQ) using `ticks_per_sample = tempo * ppq / (60 * device_sample_rate)`
- `EngineState::advance_sample_position()` increments the transport sample counter every callback; `EngineStatus::SamplePositionUpdate` forwards it to Godot alongside tick updates.
- Use `ProjectSettings::{ticks_to_samples,samples_to_ticks}` whenever you need explicit conversions (clip offsets, seeks) instead of recomputing math locally.
- Playhead updates sent to Godot at 20Hz (interpolated for smooth UI)
- Audio clips auto-stretch based on project BPM vs. recorded BPM

## Common Pitfalls

1. **Applying pan outside the dedicated passes**: Apply once per audible channel (pass 2) and once per bus after it receives audio (pass 4)
2. **Skipping send destination gain**: Send returns must respect the destination channel fader (`get_gain()`)
3. **Blocking on locks**: Use `try_lock()` with skip-on-failure pattern
4. **Not tracking processed channels**: Audio routed multiple times in hierarchical mixing
5. **Allocating memory**: Pre-allocate all buffers at init time, never in callback
6. **Decoding audio on the callback**: All decode/resample work must happen in `AudioFileService`; the callback should only read ready-to-play PCM.
7. **Allowing invalid routing**: INSTRUMENT→INSTRUMENT creates ambiguous audio source
8. **Forgetting bus device pass**: Buses must process after ingesting routed audio; do not call `process_device_chain()` on them earlier.

## Related Files

- `Engine/src/audio/mixing.rs`: Full mixing implementation (five-pass pipeline)
- `Engine/src/audio/processing.rs`: Callback pipeline orchestration
- `Engine/src/audio/engine.rs`: Engine initialization
- `Engine/src/audio/stream.rs`: Output stream thread, watchdog, config selection and the callback
- `Engine/src/audio/types.rs`: Channel, Track, Voice data structures
- `engine-architecture.md`: High-level architecture overview
