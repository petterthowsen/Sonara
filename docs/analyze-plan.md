# Analyze: offline rendering and a mix-analysis tool for the assistant

Implementation plan for the assistant's `analyze` tool. The assistant can't hear the mix. It reads levels, pans and MIDI clips one at a time, but never the arrangement as a whole. `analyze` takes a range, renders it, and returns a per-bar text grid of loudness and frequency-band energy. The grid covers the master and, optionally, individual channels. The idea comes from ISMAIL (https://newsbubbles.github.io/ismail/).

**Offline rendering comes first.** The analysis runs on the output of an offline render and not on live playback. Building the renderer first also delivers the core of issue #49 (export and bounce). It also removes the real-time constraints from the analyzer, because the analyzer runs inside the render loop and not on the audio callback, so it needs no lock-free rings.

## Checklist

- [x] Phase 1: Engine offline render core
- [ ] Phase 2: Export to WAV from Godot (verifies Phase 1 end to end)
- [ ] Phase 3: Engine analyzer
- [ ] Phase 4: Analysis render jobs
- [ ] Phase 5: Godot `analyze` tool
- [ ] Phase 6 (optional): Extras and tuning

Do the phases in order. Run `cargo test` (from `Engine/`) after each engine phase and `Godot/tests/run_all.sh` after each Godot phase. Mark tasks `[x?]` when implemented and `[x]` once verified. Phases 1 and 4 touch the engine's threading and add OSC messages, so read `docs/subsystems/engine-architecture.md`, `engine-audio-thread.md`, `engine-plugin-architecture.md` and ADRs 0002, 0007 and 0009 before starting.

## Decisions (already made)

- **Tool name `analyze`.** It takes a range and returns the analysis as text (`AiTool.ok_text`).
- **Analysis runs offline.** There is no live-playback capture path.
- **Rendering stops live output.** While a render runs, the live callback outputs silence and the transport is unavailable. This is normal DAW behaviour and avoids sharing device state between two clocks.
- **The engine computes numbers, Godot formats text.** The engine writes analysis results to a file and reports the path over OSC. The results can be too large for a UDP packet. The model-facing grid format is owned by the Godot tool, so changing it needs no engine changes.
- **Harmony comes from MIDI, not audio.** The `root` row is derived from the project's MIDI clips in Godot. Detecting it from audio (chroma) is only a possible later fallback for audio clips.
- **Fixed scales.** Every grid value is a digit 0–9 on an absolute scale, so bars and channels can be compared across calls (see Phase 3).

## Phase 1: Engine offline render core

`process_audio` (`audio/processing.rs`) and `mix_and_output` (`audio/mixing.rs`) already take a state, a buffer and a frame count. The audio callback in `audio/stream.rs` is only one caller. The renderer is a second caller with its own clock.

- [x] Add the `hound` crate for WAV writing.
- [x] `RenderJob` type (new `audio/render/mod.rs`) with fields: start tick, end tick, tail length (seconds, or "until silent" with a cap), sample rate, block size, and outputs. Outputs are a master WAV path, optional per-channel stem paths, and an analysis sink (used in Phase 4). The job also has a cancel flag (`AtomicBool`).
  - _Done:_ the analysis sink isn't there yet. `AudioCommand` is `Clone`, so Phase 4 should add it as a plain data spec (taps, resolution, path) that the worker turns into an analyzer. The master path is optional, so an analysis job can write no WAV. Only the engine's sample rate is supported (`sample_rate` 0 or equal to it); other rates would need every device re-prepared.
- [x] Render worker thread. It owns the job and runs the loop below:
  - [x] Set a `rendering` flag in `EngineState`. While the flag is set, the live callback writes silence and skips `process_audio`. Stop the transport and remember the playhead.
  - [x] Wait until every device is ready. Plugins must not be in the Loading state (`PluginLoad`), sfizz must have finished loading, and every audio clip must be decoded. Fail the job with a clear error if a plugin is Failed or Crashed.
  - [x] Call `reset()` on every device so tails from live playback don't leak in. Seek to the start tick.
  - [x] Loop: lock the state, run `process_audio` and `mix_and_output` for one block (e.g. 512 frames) into a scratch buffer, then unlock. Write to the outputs and check the cancel flag between blocks. Releasing the lock every block keeps the command thread responsive.
  - [x] Render the tail after the end tick, with the transport stopped and devices still processing.
  - [x] Reset the devices again, restore the playhead, and clear the `rendering` flag.
- [x] Render clock for plugins. In `subprocess_adapter::wait_for_done`, the deadline comes from the callback's block clock. Offline it must instead wait for the plugin to finish, with a generous safety timeout (e.g. 2 s per block). If the timeout fires, fail the job and don't drop the block, because a dropped block would silently corrupt the render. Pass the render mode through `block_clock` or a flag on the adapter.
- [x] In `plugin_host`, call the CLAP render extension (`clap_plugin_render.set(CLAP_RENDER_OFFLINE)`) when the plugin supports it. Switch back to realtime afterwards.
- [x] Per-channel tap: give `mix_and_output` an optional hook that receives each channel's post-fader, post-pan buffer and the master buffer. When the hook is absent, as on the live path, it costs nothing. The hook feeds the stems and later the analyzer.
  - _Done differently:_ no hook was needed. After `mix_and_output` returns, every channel buffer (master included, before the hardware clamp) already holds that channel's post-fader, post-pan output, so the worker copies the tapped channels straight out of the state after each block (`Render::render_block`). The live path is unchanged.
- [x] Commands and statuses: add `AudioCommand::StartRender(RenderJob)` and `CancelRender`. Add `EngineStatus::RenderProgress { job_id, fraction }`, `RenderDone { job_id, outputs }` and `RenderFailed { job_id, error }`.
- [x] OSC: add `/render/start`, `/render/cancel`, `/render/progress`, `/render/done` and `/render/failed`. Wire them into `osc/server.rs` and `audio/commands.rs`, and document them in `docs/subsystems/osc-protocol.md`.
- [x] Tests (`mod tests`): use a built-in polysynth with a fixed clip. Check that a render produces the expected length including the tail, and that two renders of the same range are bit-identical. Check that a cancelled render stops and restores the playhead. Check that live output is silent while `rendering` is set.
  - _Done:_ `audio/render/worker.rs` tests length, bit-identical renders (with live playback between them), cancel, a note on the end tick not leaking into the tail, the until-silent tail, stems, and failed devices; `stream.rs` tests the silent live callback.

_Verify:_ render an existing project to WAV through `oscsend` and listen to the file. Use a project that contains a CLAP plugin, so the plugin path is covered.

```bash
# job, start, end (4 bars), tail 4 s until silent, master, 24-bit, engine rate, default block, stem of channel 2
oscsend localhost 7000 /render/start siifisiiiis job1 0 15360 4.0 1 /tmp/sonara-mix.wav 24 0 0 2 /tmp/sonara-ch2.wav
oscdump 7001   # watch for /render/progress, /render/done or /render/failed (stop Godot first, it owns the port)
```

## Phase 2: Export to WAV from Godot

This is the user-visible half of issue #49 and the end-to-end check of Phase 1.

- [ ] Add a `RenderService` (or an extension of the `AudioEngineOSC` model layer). It starts jobs, tracks progress and done/failed by job id, and exposes signals. UI code never sends OSC directly.
- [ ] Export dialog. It has range options (whole project, loop region, or selection), a tail setting, a file path, and optional stems by channel. Show a progress bar with a cancel button.
- [ ] Disable transport controls while a render runs.
- [ ] Add a test script that drives `RenderService` against a mocked transport.
- [ ] Update the "Export/rendering" items in `TODO.md` and comment on #49.

_Verify:_ export a project from the UI with stems, and import the stems back into Sonara. They should line up with the original clips.

## Phase 3: Engine analyzer

A pure component, `audio/analysis/mod.rs`. It is fed `(tick_at_block_start, frames, &[f32] stereo)` per channel and the master, plus the tempo and time-signature maps so it can find bar and beat boundaries inside a block. It has no I/O and no locks, so it is fully unit-testable.

- [ ] Per tap, accumulated per bar (and per beat when requested):
  - [ ] Loudness: K-weighted mean square, as in BS.1770 (two biquads), reported as LUFS.
  - [ ] Band energy for six bands: sub 20–60 Hz, bass 60–250 Hz, lowmid 250–800 Hz, mid 800 Hz–2.5 kHz, himid 2.5–6 kHz, air 6–20 kHz. Use a bank of 4th-order band-pass filters with coefficients computed from the render sample rate.
  - [ ] Sample peak in dBFS, with a flag when a sample is above 0 dBFS.
  - [ ] Crest factor (peak over RMS, in dB).
  - [ ] Stereo correlation (−1…1) and side/mid energy ratio.
- [ ] Scales are applied in the formatter, but define and test them here:
  - [ ] Loudness digit = `clamp(round((LUFS + 33) / 3), 0, 9)`, so −6 LUFS → 9 and roughly −33 LUFS → 0. Silence is shown as `.`, not `0`.
  - [ ] Band digit uses the same 3 dB steps, measured relative to a pink-noise tilt. Each band's level is compared to the level pink noise at the same overall loudness would have in that band. A balanced mix then reads roughly flat, so `air` doesn't always look low.
- [ ] Output a serializable `AnalysisResult`: a list of bars, each holding values per tap (master plus channel ids), plus a header with the sample rate, the range and the scale version.
- [ ] Tests with synthetic signals:
  - [ ] A 1 kHz sine lands in `mid` only, with negligible leakage.
  - [ ] Pink noise reads flat across the bands.
  - [ ] A −23 LUFS reference tone reads −23 ±0.5.
  - [ ] Bar boundaries are exact across tempo and time-signature changes.
  - [ ] Splitting the same input into different block sizes gives identical results.

## Phase 4: Analysis render jobs

- [ ] Add an analysis sink to `RenderJob`. It has the taps to analyze (master always, plus a list of channel ids or "all"), a resolution (bar or beat), and an output path. The job writes no WAV.
- [ ] Wire the Phase 1 per-channel tap into the analyzer.
- [ ] Pre-roll: render from project start (or a configurable number of bars before the range) but only accumulate inside the requested range. Held notes, reverb tails, LFO phase and compressor state are then correct at the start of the range. Offline rendering is fast enough that rendering from the start is the default.
- [ ] Write the `AnalysisResult` as JSON to the engine's cache directory, then send `/render/done` with the path. The progress messages are the same as for normal renders.
- [ ] Test: render a two-channel project (bass-only and hat-only) and check that the bass channel's energy is in sub/bass and the hat's is in himid/air. Check that bars outside the range are absent.

## Phase 5: Godot `analyze` tool

- [ ] Add `Godot/ai/tools/AnalyzeTool.gd` and register it in `ToolRegistry.gd`. Parameters:
  - `start`, `end` (required): positions in the same bar.beat.tick format as `move_clips`. A bare bar number is allowed.
  - `channels` (optional): channel names resolved through the existing name lookup (`NameStyle`), or `"all"`. When omitted, only the master is analyzed.
  - `resolution` (optional): `"bar"` (default) or `"beat"`. Refuse beat resolution for ranges longer than 16 bars to keep the output small.
- [ ] Execute: convert the range to ticks with the time-signature map, start an analysis job through `RenderService`, await `/render/done`, then load the JSON. Return `fail()` with the engine's message if the job fails. The tool must handle the await properly; check how other async tools do it, and add support to `AiTool` if none do.
- [ ] Compute `root` per bar from MIDI: the lowest pitch class sounding longest in the bar across non-drum instrument tracks. Show `-` when nothing pitched is playing. Name notes as C3 = 60.
- [ ] Format the result as text: one row per metric, one column per bar, with a bar header and marker names as section labels. Sketch:

  ```
  bars:   17 18 19 20 | 21 22 23 24
  marker: Verse 2     | Chorus
  loud:    6  6  6  7 |  8  8  8  8
  sub:     4  4  4  4 |  6  6  6  6
  bass:    5  5  5  5 |  6  6  7  6
  lowmid:  6  6  6  6 |  7  7  7  7
  mid:     7  7  7  7 |  7  7  7  7
  himid:   6  7  6  7 |  7  7  7  7
  air:     5  5  5  5 |  6  6  6  6
  peak:    .  .  .  . |  .  !  .  .
  root:    A  A  F  G |  A  A  F  G
  ```

  Per-channel blocks follow the same layout. Below them, add a **masking summary**: per band and section, the channels that contribute most when two or more are within 3 dB of each other, e.g. `lowmid bars 21–24: Bass 7, Pad 6, Guitar 6`.
- [ ] Add a one-line legend at the top: the scale, what `.` and `!` mean, and the band edges.
- [ ] Update the system prompt (`Godot/ai/prompt/`) with when to use `analyze`: before giving mixing advice, after changing levels, EQ or arrangement, and to compare sections.
- [ ] Tests (`Godot/ai/tests/test_analyze_tool.gd`): format a fixed `AnalysisResult` fixture and compare against the expected text. Cover range parsing, refusing an oversized beat-resolution request, computing `root` from a fixture project, and the masking summary.

_Verify:_ in the app, ask the assistant to analyze a real project's chorus and give mixing advice. Check that the grid matches what you hear and that the advice refers to specific bars and channels.

## Phase 6 (optional): Extras and tuning

- [ ] Compressor gain reduction per bar. Built-in devices report it through a new optional `AudioDevice` metrics method; CLAP plugins don't.
- [ ] Cache analysis results keyed by a project revision counter and the range, so repeated calls without edits are instant.
- [ ] Add rows for stereo correlation and width (`corr`, `width`) and crest factor (`crest`). Include them only when asked, through an `extras` parameter, to save tokens.
- [ ] Chroma-based `root` fallback for bars where only audio clips play.
- [ ] Tune the scale constants against a few reference mixes, and bump the scale version in `AnalysisResult` when they change.
