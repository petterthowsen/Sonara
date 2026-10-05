# 021 — Sampler v2

Rework of the built-in Sampler (`sonara.builtin.sampler`): loop modes with crossfade, reverse,
a per-voice filter, fine tune, a proper root-note control, and a custom view with an
interactive waveform (draggable play/loop points and live playheads). Also fixes the
unreliable waveform loading in the current view.

- Engine: `Engine/src/audio/devices/sampler.rs` (today ~1130 lines, half of it `ParamInfo`
  boilerplate).
- Godot: `Godot/devices/builtin/SamplerDefaultView.gd/.tscn`, the shared `WaveformView`
  (`Godot/support/waveform/`) and `AudioSourceInfo`.
- Relevant ADRs: 0002 (audio thread contract), 0005 (normalized parameters), 0008 (device sleep),
  0011/0014 (modulation state). Nothing here contradicts them.

## Checklist

- [ ] Phase 1: Engine
- [ ] Phase 2: Godot UI

Run `cargo test` (from `Engine/`) after each engine task and `Godot/tests/run_all.sh` after each
Godot task. Mark tasks `[x?]` when implemented and `[x]` only once their verify step was run.

## What exists today

| Feature | State |
|---|---|
| Start / End | Params 7/8, normalized over the whole file. **Bug:** `set_parameter` clamps each against the *current* other value, so restoring a state where both move (preset load, undo) is order-dependent. Start 0.5/End 0.6 → load Start 0.7/End 0.9 gives Start 0.599. |
| Speed | Param 2, log 0.25–4×, default 1×. Already stored as log, so switching the display to % keeps saved values valid. |
| Tune | Param 1, ±24 st (coarse). No fine tune. |
| Root | Param 3, a 0–127 Float with no note display. |
| Key Track | Param 4, Bool, default **on**. |
| Play mode | One-shot / Gated. |
| End of sample | The voice calls `gate_off()` at the region end and keeps reading *past* End during release (the clamp in `interpolate_frame` only stops at the file end). |
| Pitch changes | `increment` is computed at note-on only, so Tune/Speed/Root moves don't affect sounding voices. |
| Waveform | The view shows the file through `WaveformView`. Start/End are drawn but not draggable. Loading is unreliable (see task 1.9). |
| Filter, loop, reverse, fine tune | Missing. |

## Decisions

These are my picks. Flag any you want changed before implementation starts.

1. **Keep existing param IDs 0–13 and their normalized mappings.** Saved projects store every
   parameter value by ID (`DeviceInstance._parameter_values_to_json`), so they keep working.
   New params use blocks of ten (`param_table` convention).
2. **Key Track defaults to off** for new instances. Existing projects saved Key Track = 1 and keep
   it, because all values are persisted.
3. **Start/End/Loop points are stored raw and resolved at use time.** `set_parameter` no longer
   clamps one point against another. A `resolve_regions()` step orders and clamps them:
   `start < end`, and the loop is clamped into `[start, end]` with a minimum length of a few
   frames. This fixes the order-dependence bug. The UI enforces the same constraints while
   dragging, so the stored values normally stay consistent anyway.
4. **Reverse doesn't flip the display.** Points stay in file space, so the waveform, handles
   and params all mean the same thing whether or not Reverse is on. In reverse, playheads move
   right to left.
5. **Loop semantics:**
   - *Off:* play from Start to End (or End to Start in reverse). At the boundary the voice
     ends with a ~2 ms declick fade. It no longer reads past the point.
   - *On:* play from Start (End if reversed) into the loop and wrap. In reverse the wrap goes
     from Loop Start to Loop End, so the loop runs backwards ("direction is flipped").
   - *Ping-Pong:* bounce between Loop Start and Loop End. Reverse sets the initial direction.
     Crossfade has no effect here because the bounce point is already continuous.
   - The loop keeps running through the release stage.
   - **With a loop on, note-off always releases**, even in One-shot. Otherwise a looping
     one-shot would ring forever.
6. **Crossfade** is 0–100 % of the loop length, equal-power. It blends the end of the loop with
   the material just *before* Loop Start (forward), or just *after* Loop End (reverse). The
   effective length is capped at `min(xfade, loop_len / 2, frames available outside the loop on
   that side)`, so a loop starting at frame 0 can't crossfade forward. The view draws the
   effective crossfade so this is visible. (The alternative, an in-loop crossfade that shortens
   the loop, can be added later as a mode if this turns out to be limiting.)
7. **Filter is per voice**, because key tracking is per note. It is stereo, using
   `dsp::svf::Svf` with two stages for the 24 dB modes. BP24 doesn't exist in `FilterMode` yet.
   It gets added to `svf.rs` as two cascaded BP12 stages, so other devices can use it.
   - Cutoff key tracking is relative to the **Root** note:
     `cutoff * 2^(kt * (note - root) / 12)`, where kt = 0–100 %. At 100 % the cutoff follows the
     pitch exactly. (Polysynth uses note 60 as its reference. For a sampler the root note is the
     natural reference.)
   - Off = bypass with no processing. Default cutoff is 1 kHz, so switching to any type is
     immediately audible.
8. **Pitch is recomputed per block for active voices.** That way Tune, Fine, Speed and Root
   automation affect notes that are already sounding.
9. **Playheads ride the existing device data stream** with type `"playheads"`. This is the same
   mechanism as the compressor's `"dynamics"` stream. Positions are normalized 0–1 over the
   whole file, which sidesteps the playback-rate vs source-rate difference between the PCM
   buffer and the peak file.

## Parameters

| ID | Name | Module | Kind | Default | Note |
|---|---|---|---|---|---|
| 0 | Volume | Amp | existing gain mapping | 1.0 | unchanged |
| 1 | Tune | Pitch | `linear(-24, 24)` st | 0 | unchanged (coarse) |
| 2 | Speed | Playback | `log(25, 400)` % | 100 % | same normalized curve as today's 0.25–4× |
| 3 | Root | Pitch | `linear(0, 127)`, unit `"note"` | 60 (C3) | stepped, shown as a note name |
| 4 | Key Track | Pitch | Bool | **off** | default changed |
| 5 | Play Mode | Playback | Enum One-shot / Gated | One-shot | unchanged |
| 6 | Velocity | Amp | `linear(0, 1)` | 1 | unchanged |
| 7 | Start | Playback | `linear(0, 1)` | 0 | stored raw (decision 3) |
| 8 | End | Playback | `linear(0, 1)` | 1 | stored raw |
| 9–12 | Attack / Decay / Sustain / Release | Amp | unchanged | unchanged | |
| 13 | Voices | Playback | 1–64 integer | 16 | unchanged |
| 14 | Fine | Pitch | `linear(-100, 100)` ct | 0 | new |
| 20 | Reverse | Playback | Bool | off | new |
| 21 | Loop Mode | Loop | Enum Off / On / Ping-Pong | Off | new |
| 22 | Loop Start | Loop | `linear(0, 1)` | 0 | new, raw |
| 23 | Loop End | Loop | `linear(0, 1)` | 1 | new, raw |
| 24 | Crossfade | Loop | `linear(0, 100)` % | 0 | new |
| 30 | Filter Type | Filter | Enum Off / LP12 / LP24 / BP12 / BP24 / HP12 / HP24 | Off | new |
| 31 | Cutoff | Filter | `log(20, 20000)` Hz | 1000 | new, smoothed |
| 32 | Resonance | Filter | `linear(0, 100)` % | 0 | new, via `resonance_to_k` |
| 33 | Filter Key Track | Filter | `linear(0, 100)` % | 0 | new |

`Voices` stays an integer range. Check that `param_table` can express it with the same normalized
mapping as `voices_from_normalized`. If it can't, keep a custom conversion for that one ID.

## Phase 1: Engine

All work is in `Engine/src/audio/devices/sampler.rs` unless noted. Keep it within the audio-thread
contract: no allocation in `process_block` (voice/filter state lives in the fixed `[Voice; 64]`
array), and `set_parameter` stays cheap because it runs under the state lock.

- [x?] **1.1 Move to `param_table`.** Replace the hand-written `parameters()` / `get_parameter` /
  `set_parameter` mapping with a `const SPECS` table (see `utility.rs`). There is no behavior
  change in this task. Add a test that every pre-existing ID 0–13 round-trips the same normalized
  value as before (especially Speed at 0.5 = 1×, Voices, and the ADSR times).
  _Verify:_ `cargo test sampler`, then load an existing project that uses a Sampler and confirm it
  sounds the same.

- [x?] **1.2 Add the new params and defaults** (table above). Fine tune feeds into the pitch:
  `increment = speed * 2^((tune + fine/100 + kt*(note-root)) / 12) * sr_ratio`. Root becomes
  stepped with unit `"note"`. Speed is shown in %. Key Track defaults to off in both `SPECS` and
  the constructor.
  _Verify:_ unit tests for fine tune (+100 ct = +1 st) and the Key Track default.

- [x?] **1.3 Raw points and `resolve_regions()`** (decision 3). Store Start/End/Loop Start/Loop End
  unclamped. Cache a `Regions { play: (f64, f64), loop_: (f64, f64), xfade: f64 }` in frames,
  recomputed when a point or Crossfade param changes, or when a sample loads. Tests:
  - the order-dependence case from "What exists today"
  - an inverted Start/End resolves to a valid region
  - a loop outside the play region is clamped into it.

- [x?] **1.4 Voice playback state machine.** Add `direction: f64 (±1)` and `in_loop: bool` to
  `Voice`, and move the advance and wrap logic into one `advance(&mut Voice, &Regions, mode)`
  function so it can be unit-tested without audio:
  - Loop Off, forward and reverse: stop at the boundary with a 2 ms declick, and never read past
    End/Start.
  - Loop On, forward: wrap `pos -= loop_len` once `pos >= loop_end`. Reverse wraps the other
    way.
  - Ping-Pong: reflect around the boundary and flip `direction`.
  - Note-off releases whenever Loop Mode ≠ Off (decision 5).
  - Edge cases: the loop length shrinking under a playing voice (wrap with `rem_euclid`), and a
    voice positioned outside the loop when the loop turns on (it plays into the loop normally).

  Tests for each mode × direction, including the loop continuing through release.

- [x?] **1.5 Loop crossfade** (decision 6). When `in_loop` and within `xfade` frames of the wrap
  point, mix `interp(pos) * cos_gain + interp(pos - loop_len) * sin_gain` for forward (mirrored
  for reverse). Tests:
  - With a ramp sample and Crossfade 0, the wrap is a hard jump.
  - With Crossfade > 0, the output is continuous across the wrap (bounded step).
  - The effective length is capped when Loop Start is at frame 0.
  - Ping-Pong ignores Crossfade.

- [x?] **1.6 Live pitch.** Store the `note` and recompute `increment` for active voices at the start
  of each block (and after any param change in the block) from the current Speed, Tune, Fine,
  Root and Key Track. Test that changing Tune while a note sounds changes that voice's increment.

- [x?] **1.7 `FilterMode::Bp24` in `dsp/svf.rs`.** Two cascaded BP12 stages, gain-normalized so the
  peak is about unity at resonance 0. Update the exhaustive `match`es in `filter.rs`, the
  polysynth and other users (they don't have to expose it). Add a response test next to the
  existing `gain_at` tests: it should have a steeper skirt than BP12 one octave out.

- [x?] **1.8 Per-voice filter.** Each `Voice` holds `[Svf; 2]` per channel (two stages for the 24
  modes). Cutoff and Resonance use `SmoothedParam`. Coefficients are recomputed per voice every
  32 samples from the smoothed cutoff × the key-track factor (decision 7). Reset the filter state
  at note-on. Filter Type Off skips the filter entirely. Tests:
  - LP12 at 200 Hz attenuates a 5 kHz sine.
  - At 100 % key track, a note an octave above Root gets twice the cutoff.
  - Switching the type while voices sound doesn't produce NaN or denormals.
  - Run the 64-voice worst case through `render_scratch`-style timing to check the cost is
    acceptable.

- [ ] **1.9 Waveform loading reliability.** The waveform sometimes never shows. **Reproduce
  first, with logging**: add `info!` in `handle_afs_event` for device requests, and Godot logs in
  `Project._on_audiofile_decode_ready`/`_on_audiofile_waveform_ready` and
  `AudioSourceInfo._set_data`. Then ask the user to reproduce and send `Engine/logs/last_combined.log`
  and `Godot/logs/last.log`. Suspects, from reading the code:
  - **H1 — untracked request.** `DeviceInstance.load_file` only registers the `req_id` with the
    Project when the instance already has a channel (`project.track_device_request`). Otherwise
    it logs a warning and the `/audiofile/*` replies are dropped. Paths that may call it too early
    include drag/drop onto Drum Machine pads (`DeviceDropUtil`), the AI `LoadDeviceFileTool` and
    preset loads.
  - **H2 — duplicate loads.** `Channel._sync_device_tree_to_engine` calls `load_file` on every
    sync. A queued load plus a sync (or an engine reconnect) sends two requests, and the second
    `sample_source.reset()` can land *after* the first request's `waveform/ready`, leaving the
    source empty if the second request's replies go missing.
  - **H3 — one-shot UDP message with no recovery.** `/audiofile/waveform/ready` is sent exactly
    once. If it's dropped, nothing re-requests it. (`DeviceInstance` already has a re-check for a
    missed `loading_state`, the comment at ~line 1369, but not for the waveform.)
  - **H4 — `WaveformData` freed mid-load.** `WaveformRegistry` holds only weak refs, and the
    `WorkerThreadPool` Callable doesn't keep the object alive. If the source is reset during a
    load, the result is dropped. That's harmless on its own, but combined with H2 it can leave a
    view bound to a dead load.

  Fixes, whatever the logs confirm:
  - Track the request even before the channel exists: resolve the Project at send time through
    `Sonara`, or record it when the instance is added.
  - Skip `load_file` in the sync when the same path is already loading or ready.
  - Add a recovery message, `/audiofile/resend [req_id]`. The engine keeps a small bounded map
    (about 256 entries) of the last `DecodeReady` metadata and peak path per `req_id` and re-sends
    `/audiofile/decode/ready` + `/audiofile/waveform/ready`. `DeviceInstance` sends it when its
    `loading_state` is `"ready"` but `sample_source` has no ready waveform after about 1 s, and
    again whenever a view is shown in that state.

  Update `osc/server.rs`, `docs/subsystems/osc-protocol.md` and the "Audio Clip Loading &
  Waveforms" section of `godot-osc.md`.
  _Verify:_ a Godot test that simulates a missed `waveform/ready` and checks that the resend
  restores it, plus a manual test: drop samples onto a Drum Machine pad, reload the project and
  reconnect the engine. The waveform shows every time.

- [x?] **1.10 `"playheads"` data stream.** Implement `subscribe_data` / `unsubscribe_data` /
  `poll_device_data` for `"playheads"`, following `compressor.rs`. Every ~33 ms of audio (counted
  in frames, as the compressor does) emit:

  ```
  u32 count
  count × { f32 position   // 0–1 over the whole file
            f32 velocity   // signed, file-fractions per second (direction × rate), for extrapolation
            f32 level }    // envelope × voice gain, 0–1, for playhead opacity
  ```

  - Send one frame with `count = 0` when the last voice ends, so Godot clears the playheads
    promptly.
  - Like the existing streams, `poll_device_data` returns a fresh `Vec` (at most 64 × 12 + 4
    bytes). That's the trait's current shape and outside this spec's scope, but note it.
  - Document the payload in `osc-protocol.md`.
  - Test: subscribe, play two notes and decode two entries with increasing positions. Unsubscribe
    and get no data.

- [x?] **1.11 Housekeeping.**
  - Update the sampler line in `AGENTS.md` if it describes features.
  - Add a one-line `TODO.md` entry pointing here.
  - Make sure the factory conformance test in `factory.rs` (the `("sampler", …)` case) still
    passes.
  - Run `cargo fmt`.
  - OSC smoke test: load a sample with `oscsend`, set Loop Mode / Filter params and listen.

## Phase 2: Godot UI

Rewrite `SamplerDefaultView` around a new interactive display. Follow
`docs/subsystems/godot-device-views.md` and `godot-ui-components.md` (overlays never shift the
layout; use the shared knobs and segmented controls). UI code never sends OSC directly: all
parameter changes go through `DeviceInstance`, and undo goes through `PropertyCommand` +
`HistoryUtil` exactly as `_commit_envelope_param` does today.

### Layout

```
┌──────────────────────────────────────────────────────────────┐
│ ▼S(blue)                                            E(blue)▼ │  play handles at the top
│ ░░░│~~~~~~~~~~~|▒▒▒▒▒ loop overlay (pink) ▒▒▒▒▒|~~~~~│░░░░░░ │  dimmed outside play region
│ ░░░│           |   ▏playheads                   |     │░░░░░░ │
│    ▲LS(pink)                               LE(pink)▲         │  loop handles at the bottom
├──────────────────────────────────────────────────────────────┤
│ Playback: [One-shot|Gated] [Reverse] Speed  Voices  Velocity  │
│ Pitch:    Root(C3)  Tune  Fine  [Key Track]                   │
│ Loop:     [Off|On|Ping-Pong]  Crossfade                       │
│ Filter:   [Off|LP12|LP24|BP12|BP24|HP12|HP24] Cutoff Res Key  │
│ Amp:      envelope graph + A D S R knobs, Volume              │
└──────────────────────────────────────────────────────────────┘
```

Exact grouping and sizing are up to whoever implements it, within the device-view conventions.
Test it at the minimum panel width, and inside Layer and Drum Machine child panels.

### Tasks

- [x?] **2.1 `SampleDisplay` control** (new, `Godot/devices/builtin/sampler/SampleDisplay.gd`). It
  owns a `WaveformView` that always shows the whole file, plus an overlay child drawn on top
  (the waveform renders through a shader, so overlays go in a sibling above it). It exposes plain
  properties: `play_start`, `play_end`, `loop_start`, `loop_end`, `loop_mode`, `xfade`,
  `reverse`, `playheads: PackedFloat32Array`. It emits `point_drag_started(which)`,
  `point_dragged(which, value)` and `point_drag_ended(which)`. It knows nothing about
  `DeviceInstance`, so it's testable on its own and reusable (for example in an audio-clip
  editor later).

- [x?] **2.2 Drawing.**
  - Dim outside `[play_start, play_end]` (black at about 45 %, as today).
  - When the loop is on, draw a faint pink overlay across the loop region (about 12 %) and the
    effective crossfade as a ramp before Loop End (after Loop Start when reversed).
  - Play markers are blue vertical lines with a downward triangle handle at the top. Loop markers
    are pink with an upward triangle at the bottom, hidden when Loop Mode is Off.
  - Hovered or dragged handles get brighter.
  - Take colors from the theme or shared constants rather than inline literals, per "One visual
    system".
  - Show the "Drop an audio file" / "Loading…" placeholder as today.

- [x?] **2.3 Handle interaction.**
  - Hit-test the triangle plus a ±5 px band around the line. Play handles win at the top half,
    loop handles at the bottom.
  - Use the move cursor on hover.
  - Drag constraints match the engine's `resolve_regions`: `start < end`. When the loop is on,
    loop handles stay inside the play region, and play handles can't cross the loop handles.
  - Shift gives fine drag (reuse `FineDrag.gd`). Double-click resets to the default.
  - Show a tooltip with the time position (`mm:ss.mmm` from `AudioSourceInfo` duration) while
    dragging.

- [x?] **2.4 Playheads.**
  - Subscribe `"playheads"` in `_on_view_shown` and unsubscribe in `_on_view_hidden`.
  - Decode `AudioEngineOSC.device_data_received` when `osc_path == device.osc_path()`.
  - Between packets, extrapolate each playhead with its velocity at frame rate, clamped to the
    play region. Snap to the new packet values when they arrive.
  - Draw thin light lines with alpha from `level`.
  - Clear all playheads if no packet arrives for 250 ms, in case the `count = 0` frame is lost.
  - Only `queue_redraw` the overlay while playheads exist.

- [x?] **2.5 Rewrite `SamplerDefaultView`** to use `SampleDisplay` plus the control rows.
  - Bind params by name via `get_parameter_id_by_name`, as today.
  - Handle drags commit through one mergeable `PropertyCommand`, so a drag is one undo step.
  - Root shows note names (C3 = 60, matching `SimpleUnits` `"note"`), Speed shows %, Fine shows
    ct.
  - Disable the Crossfade knob when Loop Mode is Off or Ping-Pong, and dim the Cutoff, Resonance
    and Filter Key Track knobs when Filter Type is Off.
  - Keep the envelope graph and ADSR knobs, including the `ModAssign.attach` calls. Attach
    modulation to the new knobs too, where the param is modulatable.
  - Update `SamplerDefaultView.tscn` and `_get_minimum_size()`.

- [x?] **2.6 Waveform hookup.** _(Rebinding on `sample_source` replacement is done; the 1.9 resend call is not wired because 1.9 isn't implemented yet.)_ Replace the ad-hoc `_ensure_waveform`/`_connect_waveform` logic
  with one bind/unbind pair that follows `device.sample_source` being replaced, not just
  refilled. When the view is shown in the "ready but no waveform" state, trigger the 1.9 resend.

- [x?] **2.7 Tests** (`Godot/tests/test_sampler_view.gd`, extending `TestBase`):
  - `SampleDisplay` hit-testing and drag constraints (play can't cross loop; loop clamped into
    play).
  - A drag produces exactly one undo step and the expected normalized values.
  - Playhead payload decoding, extrapolation and the 250 ms clear.
  - The loop overlay and handles are hidden when Loop Mode is Off.
  - The view shows the waveform once `waveform_ready` fires, including when `sample_source` is
    swapped after binding.
  - Run the existing `test_waveform_view`, `test_device_presets` and `test_device_drop` (sampler
    drops) unchanged.

- [x?] **2.8 Docs.**
  - Add a Sampler section to `godot-device-views.md` covering `SampleDisplay`, the playheads
    stream and the handle colors.
  - Mark the `TODO.md` entry `[x?]`.

## Out of scope / follow-ups

- Zooming and scrolling inside the sample display, and snapping points to zero crossings.
- Slicing, warping and multi-sample zones (that's what the SFZ sampler is for).
- Making Cutoff and Resonance targets for per-voice modulation (spec 018 voice modulation),
  plus filter envelope and velocity → cutoff.
- Higher-quality interpolation than linear (cubic/Hermite) for heavy repitching.
- Declicking voice steals (currently a hard cut when the pool is full).
