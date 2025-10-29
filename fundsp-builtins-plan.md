# FunDSP PolySynth Device Implementation Plan

## Overview

Build a polyphonic synthesizer device (`PolySynthDevice`) using the FunDSP audio DSP library. The device will integrate with the existing device architecture and provide professional-quality synthesis with the following features:

- **Voice management**: Polyphonic (8-16 voices)
- **Oscillators**: Two oscillators (A & B) with selectable waveforms (sine, saw, square, triangle)
- **Amplitude envelope**: ADSR envelope for volume shaping
- **Filter**: Resonant filter (LPF or HPF) with cutoff and resonance controls
- **Filter envelope**: Dedicated ADSR for filter modulation
- **Master volume**: Final output level control

## Architecture Decisions

### FunDSP Integration Approach

1. **Use `hacker32` prelude**: 32-bit internal state for optimal performance
2. **Static graph composition per voice**: Pre-compile voice DSP graphs at voice initialization for zero-cost abstractions
3. **Voice pooling**: Pre-allocate fixed number of voices (e.g., 16) to avoid runtime allocation
4. **Voice stealing**: Implement note priority when all voices are active (steal oldest/quietest)
5. **Parameter sharing**: Use atomic shared variables for parameters that affect all voices

### Voice DSP Graph Structure

Each voice will have the following signal flow:

```
MIDI Note → frequency
            ↓
    ┌───────────────────────┐
    │   Oscillator A        │ (sine/saw/square/triangle)
    └───────────┬───────────┘
                │ mix
    ┌───────────┴───────────┐
    │   Oscillator B        │ (sine/saw/square/triangle)
    └───────────┬───────────┘
                │
    ┌───────────┴───────────┐
    │   Filter              │ (LPF/HPF + Filter Envelope)
    └───────────┬───────────┘
                │
    ┌───────────┴───────────┐
    │   Amp Envelope        │ (ADSR)
    └───────────┬───────────┘
                │
                ↓ Master Volume → Stereo Output
```

### Real-Time Safety Considerations

Following audio thread rules from CLAUDE.md:

1. **Pre-allocation**: All voice buffers allocated in `activate()`
2. **No blocking**: Use `try_lock()` for parameter access with skip-on-failure
3. **No heap allocation**: Voice graphs constructed at initialization
4. **Fixed-time operations**: Voice processing is O(n) in buffer size

## Phase 1: Foundation & Single Oscillator Voice

**Goal**: Establish basic polyphonic voice management with single oscillator and amplitude envelope.

### Tasks

1. **Add FunDSP dependency**
   - Edit `Engine/Cargo.toml`: Add `fundsp = "0.19.1"`
   - Choose `hacker32` prelude for performance

2. **Create `PolySynthDevice` skeleton**
   - File: `Engine/src/audio/devices/polysynth.rs`
   - Implement `AudioDevice` trait
   - Basic lifecycle methods (`activate`, `deactivate`, `reset`)
   - Stub `process_block` outputting silence

3. **Design Voice struct**
   ```rust
   struct Voice {
       midi_note: u8,
       velocity: f32,
       frequency: f32,
       is_active: bool,
       trigger: f32, // ADSR trigger state (1.0 = note on, 0.0 = note off)
       // FunDSP graph will be added here
   }
   ```

4. **Implement voice allocation/deallocation**
   - Voice pool: `Vec<Voice>` with fixed capacity (16 voices)
   - `find_free_voice()`: Returns first inactive voice index
   - `find_voice_for_note()`: Returns voice playing a given MIDI note
   - `steal_voice()`: Steal oldest or quietest voice when pool exhausted

5. **Build single oscillator + envelope FunDSP graph**
   - Use `sine_hz(freq)` for initial oscillator
   - Connect to `adsr_live(attack, decay, sustain, release)`
   - Apply master volume multiplication
   - Graph structure: `sine_hz(freq) >> adsr_live(...) >> mul(volume)`

6. **Implement MIDI note on/off**
   - `send_midi_event()`: Allocate voice on note-on, set trigger=1.0
   - On note-off: Set trigger=0.0 to start release phase
   - Mark voice inactive after release completes

7. **Implement basic audio rendering**
   - Loop through active voices in `process_block()`
   - Call `voice_graph.get_mono()` for each voice
   - Sum voice outputs into stereo buffer
   - Apply simple panning (center for now)

8. **Define initial parameters**
   ```
   ParamId 0: Oscillator A Waveform (0-3: sine/saw/square/triangle)
   ParamId 1: Attack time (0.001-2.0s)
   ParamId 2: Decay time (0.001-2.0s)
   ParamId 3: Sustain level (0.0-1.0)
   ParamId 4: Release time (0.001-3.0s)
   ParamId 5: Master Volume (0.0-1.0)
   ```

### Testing Phase 1

- Test note on/off triggers envelope correctly
- Verify polyphony: Play 16 simultaneous notes
- Test voice stealing: Play 17+ notes, verify oldest is stolen
- Measure CPU usage (should be minimal for 16 voices)

---

## Phase 2: Dual Oscillators with Mix Control

**Goal**: Add second oscillator with independent waveform selection and mixing.

### Tasks

1. **Add Oscillator B to voice graph**
   - Create separate oscillator instance with same frequency
   - Stack with Oscillator A using FunDSP `&` (bus) operator
   - Graph: `(osc_a_graph * mix_a) & (osc_b_graph * mix_b)`

2. **Implement oscillator waveform selection**
   - Abstract oscillator creation into `create_oscillator(waveform_type, freq)`
   - Return appropriate FunDSP node: `sine_hz()`, `saw_hz()`, `square_hz()`, `triangle_hz()`
   - Rebuild voice graphs when waveform parameter changes

3. **Add oscillator mix parameters**
   ```
   ParamId 6: Oscillator A Level (0.0-1.0)
   ParamId 7: Oscillator B Level (0.0-1.0)
   ParamId 8: Oscillator B Waveform (0-3)
   ```

4. **Handle parameter changes**
   - Parameters affect voice creation, so require voice graph rebuilding
   - Strategy: Mark voices for rebuild, reconstruct graphs on next process cycle
   - Use atomic flags or command queue to defer graph reconstruction safely

5. **Oscillator detuning (optional enhancement)**
   - Add detune parameter for Oscillator B (±50 cents)
   - Multiply B frequency by `2^(detune_cents / 1200.0)`
   - Creates richer, chorus-like sound
   - ParamId 9: Oscillator B Detune (-50 to +50 cents)

### Testing Phase 2

- Verify each oscillator waveform sounds correct
- Test mixing: Set A=1.0, B=0.0 (only A audible), then reverse
- Test waveform changes during playback
- Listen for aliasing artifacts (especially with square/saw at high frequencies)

---

## Phase 3: Resonant Filter with Cutoff & Resonance

**Goal**: Add filter stage with cutoff and resonance controls.

### Tasks

1. **Add filter to voice graph**
   - Insert between oscillator mix and amplitude envelope
   - Use `lowpass_hz(cutoff, q)` or `highpass_hz(cutoff, q)`
   - Graph: `osc_mix >> lowpass_hz(cutoff, q) >> amp_envelope`

2. **Implement filter type selection**
   - Create `create_filter(filter_type, cutoff, q)` helper
   - Support LPF (lowpass) and HPF (highpass)
   - Return appropriate FunDSP filter node

3. **Add filter parameters**
   ```
   ParamId 10: Filter Type (0=LPF, 1=HPF)
   ParamId 11: Filter Cutoff (20-20000 Hz, logarithmic mapping)
   ParamId 12: Filter Resonance/Q (0.5-10.0, logarithmic)
   ```

4. **Parameter mapping utilities**
   - `param_to_cutoff(value: f32) -> f32`: Map 0.0-1.0 to 20-20000 Hz logarithmically
     - Formula: `20.0 * (1000.0_f32.powf(value))`
   - `param_to_q(value: f32) -> f32`: Map 0.0-1.0 to 0.5-10.0 logarithmically
     - Formula: `0.5 * (20.0_f32.powf(value))`

5. **Implement filter self-oscillation prevention**
   - Clamp Q values to safe range (max 10.0)
   - Monitor for instability (output > threshold)
   - Add soft clipping if needed: `tanh()` waveshaper after filter

### Testing Phase 3

- Sweep cutoff from low to high, verify smooth frequency response
- Test resonance at various cutoff frequencies
- Verify no instability or runaway feedback at max Q
- A/B test LPF vs HPF modes

---

## Phase 4: Filter Envelope Modulation

**Goal**: Add dedicated ADSR envelope to modulate filter cutoff.

### Tasks

1. **Add filter envelope to voice graph**
   - Create second `adsr_live(...)` instance for filter
   - Trigger synchronously with amplitude envelope
   - Use as modulation source for filter cutoff

2. **Implement envelope-to-cutoff mapping**
   - Base cutoff from ParamId 11
   - Envelope amount: ParamId 13 (0.0-1.0, controls modulation depth)
   - Modulated cutoff: `base_cutoff * (1.0 + envelope_value * amount * scale_factor)`
   - Scale factor maps envelope range to musical range (e.g., 0.0-1.0 → 1x-10x)

3. **Add filter envelope parameters**
   ```
   ParamId 13: Filter Envelope Amount (0.0-1.0)
   ParamId 14: Filter Attack (0.001-2.0s)
   ParamId 15: Filter Decay (0.001-2.0s)
   ParamId 16: Filter Sustain (0.0-1.0)
   ParamId 17: Filter Release (0.001-3.0s)
   ```

4. **Build modulated filter graph**
   - FunDSP approach: Use `pipe` and `branch` operators
   - Graph structure:
     ```rust
     // Trigger signal feeds both envelopes
     let trigger = var(&trigger_shared);
     let amp_env = trigger >> adsr_live(a, d, s, r);
     let filt_env = trigger >> adsr_live(fa, fd, fs, fr);

     // Filter cutoff modulation
     let modulated_cutoff = constant(base_cutoff) * (constant(1.0) + filt_env * constant(amount * scale));

     // Full graph
     (osc_mix | modulated_cutoff) >> lowpass() >> (amp_env * constant(volume))
     ```

5. **Handle envelope synchronization**
   - Both envelopes must see the same trigger signal
   - Use shared atomic variable updated on note on/off
   - Reset both envelopes when voice is recycled

### Testing Phase 4

- Play note with filter envelope amount at 100%
- Verify cutoff sweeps from base to modulated value during attack/decay
- Test different filter envelope times (fast attack, slow decay, etc.)
- Ensure envelopes stay synchronized (filter + amp)

---

## Phase 5: Optimization & Polishing

**Goal**: Optimize performance, add quality-of-life features, and ensure production readiness.

### Tasks

1. **Voice management refinements**
   - Implement smart voice stealing: Prefer voices in release phase
   - Add voice priority: Louder or more recent notes prioritized
   - Mono mode option: Single voice, legato/portamento
   - ParamId 18: Voice Mode (0=Poly, 1=Mono)

2. **CPU optimization**
   - Profile `process_block()` with realistic voice count
   - Consider SIMD block processing if FunDSP supports it
   - Investigate `BlockRateAdapter` for control-rate parameters
   - Skip inactive voice processing (early exit if voice is silent after release)

3. **Anti-aliasing improvements**
   - FunDSP provides bandlimited oscillators by default
   - Verify square/saw waves don't alias at high frequencies
   - Consider oversampling for non-linear stages (filter at high resonance)
   - Use FunDSP's `oversample()` wrapper if needed

4. **Parameter smoothing**
   - Prevent zipper noise when changing cutoff, volume, etc.
   - Use FunDSP `follow()` filter for parameter smoothing
   - Graph: `var(&param_shared) >> follow(0.01) >> ...`
   - Apply to: Master volume, filter cutoff, oscillator levels

5. **Additional parameters**
   ```
   ParamId 19: Oscillator A Octave (-2 to +2)
   ParamId 20: Oscillator B Octave (-2 to +2)
   ParamId 21: Voice Count (1-16, for CPU management)
   ParamId 22: Pan (0.0-1.0, L-R)
   ```

6. **Stereo enhancement**
   - Add stereo width control
   - Pan voices slightly based on note number or phase
   - Apply slight detune between L/R for unison modes

7. **Preset system integration**
   - Ensure all parameters can be saved/loaded
   - Test parameter recall accuracy
   - Document parameter ranges in `ParamInfo`

8. **Testing & validation**
   - Stress test: 16 voices sustained, measure CPU
   - Latency test: Verify no added latency beyond audio buffer
   - Audio quality: Check for clicks, pops, zipper noise
   - MIDI CC mapping: Test external controller integration

### Performance Targets

- **CPU Usage**: <5% on modern CPU for 16-voice polyphony at 48kHz
- **Latency**: Zero added latency (sample-accurate voice triggering)
- **Memory**: <1MB for device + all voices

---

## Phase 6: Godot UI Integration (Parallel Development)

**Goal**: Create UI controls for all synthesizer parameters.

### Tasks

1. **Create PolySynth UI scene**
   - File: `Godot/components/device_ui/PolySynthUI.gd`
   - Use existing UI components (RotaryKnob, Slider, etc.)
   - Layout: Sections for Oscillators, Filter, Envelopes

2. **Oscillator section**
   - Osc A: Waveform selector (dropdown/buttons), Level knob, Octave knob
   - Osc B: Same as Osc A, plus Detune knob

3. **Filter section**
   - Filter type selector (LPF/HPF)
   - Cutoff knob (logarithmic)
   - Resonance knob (logarithmic)

4. **Envelope sections**
   - Amp Envelope: 4 knobs (A, D, S, R)
   - Filter Envelope: 4 knobs (A, D, S, R) + Amount knob

5. **Master section**
   - Master Volume slider
   - Voice mode selector (Poly/Mono)
   - Pan knob

6. **OSC parameter binding**
   - Connect knobs to OSC messages: `/channel/{id}/device/{idx}/parameter/{param_id}`
   - Map UI ranges to normalized 0.0-1.0 parameter values
   - Add visual feedback for parameter changes

7. **Preset visualization**
   - Display preset name
   - Save/load preset buttons
   - Reset to default button

---

## Technical Challenges & Solutions

### Challenge 1: Rebuilding Voice Graphs on Parameter Change

**Problem**: FunDSP graphs are type-erased and stack-allocated. Changing waveform or filter type requires rebuilding the entire voice graph.

**Solution**:
- Use parameter versioning: Track when parameters change
- Rebuild voice graphs during initialization or when parameter version differs
- For per-voice rebuilds: Defer until voice is released and reallocated
- Alternative: Use `Net` dynamic system if static graphs become unwieldy

### Challenge 2: Shared Parameter Access from Audio Thread

**Problem**: Audio thread must access parameters without blocking or allocating.

**Solution**:
- Use FunDSP's `shared()` atomic variables for parameters
- Clone `SharedVar` handles into each voice
- Audio thread reads via `value()` (atomic read, no blocking)
- Main thread updates via `set_value()` (atomic write)

### Challenge 3: Envelope Triggering

**Problem**: FunDSP's `adsr_live()` expects continuous input signal (>0 = attack, <=0 = release).

**Solution**:
- Each voice maintains a `trigger` shared variable
- Note on: `trigger.set_value(1.0)`
- Note off: `trigger.set_value(0.0)`
- Feed trigger into ADSR: `var(&trigger) >> adsr_live(...)`

### Challenge 4: Filter Self-Oscillation

**Problem**: High resonance filters can self-oscillate or become unstable.

**Solution**:
- Clamp Q parameter to safe maximum (e.g., 10.0)
- Consider using FunDSP's nonlinear filters (`dlowpass`, `dhighpass`) for softer clipping
- Add output limiter: `>> tanh()` or `>> soft_saturate()`

---

## Dependencies & Resources

### Crate Dependencies

```toml
[dependencies]
fundsp = "0.19.1"  # Core DSP library
```

### Documentation References

- FunDSP GitHub: https://github.com/SamiPerttu/fundsp
- FunDSP Docs: Local file `fundsp_doc_readme.md`
- FunDSP Prelude: `fundsp::hacker32::*`

### Existing Code References

- Device trait: `Engine/src/audio/devices/mod.rs`
- Example device: `Engine/src/audio/devices/oscillator.rs` (monophonic)
- Complex device: `Engine/src/audio/devices/sfizz_device.rs` (async loading patterns)

---

## Testing Strategy

### Unit Tests

- Voice allocation/deallocation logic
- Parameter mapping functions (cutoff, Q, frequency)
- Voice stealing algorithm
- Envelope synchronization

### Integration Tests

- MIDI note on/off handling
- Polyphony (16 simultaneous notes)
- Parameter changes during playback
- Audio output validation (no silence, no clipping)

### Audio Quality Tests

- Frequency response verification (oscillators, filter)
- THD (Total Harmonic Distortion) measurement
- Aliasing analysis (especially square/saw waves)
- Envelope curve accuracy (ADSR attack/decay slopes)

### Performance Tests

- CPU profiling with 16 voices
- Memory usage measurement
- Latency measurement (note-on to audio-out)

---

## Success Criteria

### Functional Requirements

- ✅ Polyphonic (8-16 voices)
- ✅ Dual oscillators with selectable waveforms
- ✅ Amplitude ADSR envelope
- ✅ Resonant filter (LPF/HPF)
- ✅ Filter envelope modulation
- ✅ Master volume control
- ✅ All parameters controllable via OSC
- ✅ No audio dropouts or glitches

### Performance Requirements

- ✅ <5% CPU for 16 voices at 48kHz
- ✅ Zero added latency
- ✅ No memory allocations in audio thread
- ✅ Sample-accurate note triggering

### Quality Requirements

- ✅ Bandlimited oscillators (no aliasing)
- ✅ Smooth parameter changes (no zipper noise)
- ✅ Stable filter at high resonance
- ✅ Musical-sounding envelopes

---

## Future Enhancements (Post-MVP)

1. **Modulation Matrix**: Route envelopes/LFOs to multiple destinations
2. **LFOs**: Low-frequency oscillators for vibrato, tremolo, filter wobble
3. **Unison/Detune**: Stack multiple oscillators per voice for thickness
4. **Effects**: Built-in chorus, reverb, delay (using FunDSP components)
5. **Wavetable Oscillators**: Beyond basic waveforms
6. **Filter Types**: Add more filter models (Moog, SVF morph, comb)
7. **Modulation Envelopes**: Additional envelopes for pitch, pan, etc.
8. **Velocity Sensitivity**: Map velocity to filter cutoff, amplitude, etc.
9. **Aftertouch/MPE**: Support for expressive MIDI controllers
10. **Preset Browser**: Categorized preset system with tagging

---

## Appendix: Code Structure

### File Organization

```
Engine/src/audio/devices/
├── mod.rs                   # Device trait and exports
├── oscillator.rs            # Existing monophonic oscillator
├── polysynth.rs             # NEW: PolySynth implementation
└── polysynth/
    ├── mod.rs               # Re-exports
    ├── voice.rs             # Voice struct and management
    ├── parameters.rs        # Parameter definitions and mapping
    └── dsp_graph.rs         # FunDSP graph construction utilities
```

### Key Structs

```rust
// polysynth/mod.rs
pub struct PolySynthDevice {
    sample_rate: f32,
    voices: Vec<Voice>,
    parameters: PolySynthParameters,
    is_active: bool,
    is_enabled: bool,
}

// polysynth/voice.rs
pub struct Voice {
    midi_note: u8,
    velocity: f32,
    frequency: f32,
    is_active: bool,
    note_on_time: u64, // For voice stealing priority
    // FunDSP graph (type-erased)
    dsp_graph: Box<dyn AudioUnit>, // Or static type if using An<...>
    trigger: Shared<f32>, // Envelope trigger
}

// polysynth/parameters.rs
pub struct PolySynthParameters {
    osc_a_waveform: AtomicU8,
    osc_b_waveform: AtomicU8,
    osc_a_level: Shared<f32>,
    osc_b_level: Shared<f32>,
    filter_type: AtomicU8,
    filter_cutoff: Shared<f32>,
    filter_resonance: Shared<f32>,
    // ... (all parameters as atomics or shared vars)
}
```

---

## Timeline Estimate

- **Phase 1**: 2-3 days (foundation + single osc + envelope)
- **Phase 2**: 1-2 days (dual oscillators)
- **Phase 3**: 1-2 days (filter)
- **Phase 4**: 2-3 days (filter envelope, more complex graph)
- **Phase 5**: 2-3 days (optimization + polish)
- **Phase 6**: 2-3 days (Godot UI, parallel with Phases 3-5)

**Total Estimated Time**: 10-16 days (assuming serial development, ~4-6 hours/day)

---

## Conclusion

This plan provides a structured, incremental approach to building a professional polyphonic synthesizer using FunDSP. Each phase builds on the previous one, allowing for testing and validation at every step. The final result will be a performant, high-quality software synthesizer fully integrated with the DAW's device architecture and Godot UI.
