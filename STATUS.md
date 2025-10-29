# Project Status

Implemented (PolySynth + Builtins Wiring)
- Added FunDSP (0.19.1) and implemented `PolySynthDevice` (mono render per voice, 16-voice pool, sine/square/saw/triangle, ADSR amp env, master volume, voice stealing).
- Integrated PolySynth into engine device factory: `sonara.builtin.polysynth`.
- Added OSC builtin advertisement from engine:
  - Request: `/builtin/request`
  - Per-device reply: `/builtin/info [..., param tuples]`
  - Completion: `/builtin/complete [count]`
- Godot `DeviceAssetProvider.gd` now:
  - Listens for `/builtin/info` and `/builtin/complete`.
  - Requests builtins on initialize and on `AudioEngineOSC.engine_connected`.
  - Parses parameters and registers devices dynamically (disabled hardcoded built-ins).
- Guarded `DeviceInstance` init to avoid null device crashes.
- Verified engine builds and PolySynth plays; device shows in browser via advertised builtins.

Known Issues
- Parameter changes during playback cause voices to retrigger/reset audibly.
  - Root cause: current graph rebuild path replaces the voice graph, envelopes/phase re-init.
  - No parameter smoothing yet (cutoff/volume/waveform/etc.).

Next Tasks (Actionable)
1) Parameter smoothing (follow filters)
   - Use `shared()` + `var(&) >> follow(tau)` to smooth master volume and other continuous params.
   - Start with volume and envelope times; then cutoff/resonance when filter lands.

2) Non-disruptive parameter updates
   - Avoid rebuilding voice graphs on live parameter changes where possible.
   - Strategy A: Build graphs using shared vars for levels/ADSR times; update shared values only.
   - Strategy B: For discrete topology changes (waveform/filter type), mark voice `needs_rebuild` and rebuild only on next Note On or after release phase; optionally crossfade old/new graph.

3) Waveform change policy
   - Defer waveform graph rebuild until voice is idle, or perform per-voice crossfade (short 10–20 ms ramp) to prevent clicks.

4) Expose PolySynth params in Godot UI
   - Add simple UI controls (Waveform, ADSR, Master Volume) and bind via OSC.

5) Phase 2/3 milestones
   - Dual oscillators with mix (A/B levels via shared vars; optional detune).
   - Add resonant filter stage (LPF/HPF) with cutoff/Q; map UI 0–1 to Hz/Q logarithmically.

6) Tests and profiling
   - Stress polyphony (16 voices), confirm no XRUns; basic CPU profiling.
   - Validate voice stealing preference (steal oldest or release-phase voices first).

7) Housekeeping
   - Ensure advertised builtin metadata matches device params (names/ranges/defaults) as features grow.
