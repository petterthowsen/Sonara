# Engine architecture cleanup

Implementation plan for issue #67 (codebase audit: module layout, oversized files, duplicated
logic, dead code, unused dependencies). It also prepares for issue #1's "Remove shared
`Arc<Mutex<EngineState>>` (phase 2)", but it does not make that change.

This is a **refactor**. Behavior, the OSC protocol, persisted formats and audio-thread behavior
stay the same, except for the changes listed under **Allowed behavior changes**. Do the phases in
order. When a phase has to deviate from this plan, update this file first.

## Checklist

- [x] Phase 0: Baseline
- [x] Phase 1: Unused dependencies and dead code
- [x] Phase 2: `main.rs` uses the library crate; logging module
- [x] Phase 3: Split `audio/types.rs`
- [x] Phase 4: Split `audio/commands.rs`; `EngineState` gets its own module
- [x] Phase 5: Command effects: statuses and drops after the lock is released (prep for #1)
- [x] Phase 6: Device lookup helpers
- [x] Phase 7: Split `audio/command_worker.rs`
- [x] Phase 8: Split `osc/server.rs`
- [x] Phase 9: OSC argument reader
- [x] Phase 10: Split `audio/processing.rs` and `audio/mixing.rs`
- [x] Phase 11: Group `audio/devices/`
- [x] Phase 12: Split `audio/ipc/process_manager.rs` and `audio/devices/sampler.rs`
- [x] Phase 13: Docs, command classification for #1, close-out (live checks done 2026-10-09)

## Before you start

- Work in the worktree `/home/peter/work/sonara-refactor` on branch `refactor/engine-architecture`
  (created from `master` after spec 027 merged). Never switch branches in `/home/peter/work/sonara`:
  that is the user's checkout.
- Build with `CARGO_BUILD_JOBS=6` and commit work-in-progress regularly.
- Read `AGENTS.md`, `docs/subsystems/rust-code-style.md`, `docs/subsystems/engine-architecture.md`
  and `docs/subsystems/engine-audio-thread.md`, plus ADRs 0002 (audio thread contract), 0006 and
  0007.
- Run cargo builds one at a time. Don't start parallel agents or worktrees for this: several
  parallel cargo builds have frozen this machine before.
- The user's engine may already be running on port 7000. Check
  (`ss -lunp | grep 7000`) before you start one, and ask rather than kill it. Don't change PipeWire
  settings.

## Working rules

1. **Move first, then change.** Every split is two commits:
   - (a) a pure move: code is cut and pasted into new files, with only the `use`, `mod`,
     visibility (`pub(super)`/`pub(crate)`) and path edits needed to compile;
   - (b) improvements on top.

   Reviewers can then diff (a) with `git diff --color-moved` and see that nothing changed.
2. When a file becomes a directory, `git mv foo.rs foo/mod.rs` first, then cut pieces out of
   `mod.rs`. This keeps `git blame` on the biggest piece.
3. Tests move with the code they test. A `mod tests` block that covers several new files is split
   so each file keeps its own tests. Shared test fixtures go in a `#[cfg(test)] mod test_support`
   next to them. Don't delete or weaken a test to make a move compile.
4. Keep every `///` doc comment, and add one to each new type, module (`//!`) and function, as the
   style guide asks.
5. Update imports at their call sites. Don't leave compatibility re-exports in the old location.
   The exception is a parent `mod.rs` that re-exports its children's public types (as
   `audio/mod.rs` and `devices/mod.rs` already do). Use `pub(crate)` or `pub(super)` for anything
   that isn't used outside the engine.
6. Use the domain terms from `CONTEXT.md` for new module and function names.
7. Don't change code on the audio thread except as stated here. Moving a function between files
   is fine; changing what it allocates, locks or calls is not.

### After every phase

From `Engine/`:

```bash
cargo fmt
cargo build --release 2>&1 | grep -c '^warning'   # must not grow; 0 once Phase 1 is done
cargo test 2>&1 | grep 'test result'              # count must match the Phase 0 baseline (see below)
```

Record the test count in the **Log** table at the end of this file. If the count drops, find the
missing tests before you go on. Commit at the end of each phase (at least one commit per phase)
with a message that starts `Engine cleanup phase N:`.

During research for this plan, one test failed once in the `--bin engine` run and passed in the
library run. If a test fails intermittently, write its name into the **Log** and carry on. Don't
change the test.

### Allowed behavior changes

Only these. Each one goes in its own commit and must be named in the commit message.

- Phase 1: the dead in-process CLAP adapter's downcast leaves the audio callback (it never
  matched, so this saves a type check per device per block).
- Phase 5: statuses that fast commands produce are sent after the state lock is released, not
  while holding it. Objects that commands remove are dropped after the lock is released.
- Phase 9: a malformed OSC message logs a WARN naming the address and the expected arguments,
  instead of being dropped silently.

---

## Phase 0: Baseline

1. From `Engine/`, record:
   - `cargo test 2>&1 | grep -E 'Running|test result'`. Today the library crate has 804 passed
     and 14 ignored, and `src/main.rs` runs the same tests a second time (see Phase 2).
   - `cargo build --release 2>&1 | grep -c '^warning'` (138 at the time of writing).
2. Save the full warning output to the scratchpad. Phase 1 works through it:

   ```bash
   cargo build --release 2>&1 > /dev/null | tee <scratchpad>/warnings-before.txt
   cargo test --no-run 2>&1 | tee <scratchpad>/warnings-test-before.txt
   ```

   Capture it now. Phase 2 turns many of these items into `pub` library items, and `rustc` stops
   reporting them as unused.
3. Fill in the first row of the **Log**.

## Phase 1: Unused dependencies and dead code

### 1a. `Cargo.toml`

Check each with `grep -rn '<crate>' Engine/src` before you remove it. If `cargo build` fails
afterwards, put it back and note why in the **Log**.

| Dependency | Action |
|---|---|
| `byteorder` | Remove (no uses). |
| `libloading` | Remove (no direct uses; clack brings its own). |
| `tracing-appender` | Remove (no uses; logging uses its own `RotatableWriter`). |
| `tempfile` | Move to `[dev-dependencies]` (only used in tests). |
| `once_cell` | Replace its one use (`audio/dsp/oscillator.rs`, `Lazy`) with `std::sync::LazyLock`, then remove it. |

### 1b. The in-process CLAP adapter

`audio/devices/clap_host/adapter.rs` says "this is the in-process CLAP plugin adapter, currently
not used". ADR 0001 puts plugins out of process, and the stability plan skipped the "within
engine" hosting mode. Remove it:

- Delete `clap_host/adapter.rs` and `clap_host/host_impl.rs`. Before you delete `host_impl.rs`,
  confirm with grep that `SonaraHost*` is used only by `adapter.rs`. The plugin host subprocess has
  its own `plugin_host/host.rs`.
- Remove the re-exports in `clap_host/mod.rs` and `devices/mod.rs`.
- `audio/mixing.rs` `forward_device_events`: remove the `downcast_mut::<ClapDeviceAdapter>()`
  block. It runs on the audio callback for every device in every block. This is an allowed
  behavior change; give it its own commit.
- `audio/commands.rs`, `AudioCommand::OpenPluginGui` / `ClosePluginGui`: these arms only handle
  the in-process adapter. `CommandWorker::handle` sends a command there only when
  `plugin_handle` finds no subprocess plugin. Replace both arms with one `warn!` saying the device
  isn't a CLAP plugin. Keep `PluginGuiClosed` behavior for subprocess plugins unchanged.
- Remove `PluginError` variants or the whole type only if nothing else uses them. `discovery.rs`
  may.
- Update `subprocess_adapter/mod.rs`'s module doc, which mentions `ClapDeviceAdapter`.

### 1c. Compiler warnings

Work through `warnings-before.txt` and `warnings-test-before.txt`:

- Unused imports, variables and `mut`: remove them.
- A function, constant or field that is unused everywhere: delete it. Before you delete, grep
  `docs/specs/` and open issues (`gh issue list --search <name>`) for the name. If it's mentioned
  as planned work, keep it with `#[allow(dead_code)] // spec NNN: <why>` instead.
- Used only by tests: move it into the `mod tests` block, or mark it `#[cfg(test)]`.
- Known items: `multiband.rs` `band_*_id` and `DEFAULT_EDGES`, phaser constants (`PHASER`, `LFO`,
  `ENVELOPE`, `TONE`, `OUTPUT`), `active_jobs`, `wait_for_events`, `source_frames`, `frames`,
  `read_texel`, `device_vendor`, `pending_main_thread_callback`. Check each one.

### 1d. Small dead code

- `impl Clone for EngineState` (`audio/commands.rs`) panics when called. Delete it, and fix
  whatever stops compiling (there should be nothing).
- The commented-out playhead logging at the end of `process_audio` (`audio/processing.rs`,
  "disabled for real-time safety"): delete it.
- `CommandResponse` (`audio/commands.rs`): delete it if nothing constructs it.

Done when: `cargo build --release` and `cargo test --no-run` produce **0 warnings**, and the test
count only drops by tests that covered deleted code (list them in the **Log**).

## Phase 2: `main.rs` uses the library crate; logging module

`src/main.rs` declares `mod audio; mod osc; mod window_manager; mod log_forwarder;` while
`src/lib.rs` declares the same modules. So the engine compiles everything twice, and `cargo test`
runs every test twice (once as `src/lib.rs`, once as `src/main.rs`).

1. Add `log_forwarder` to `lib.rs` (Step 2 moves it).
2. `main.rs`: delete the `mod` lines and import from the library instead
   (`use engine::audio::...`, `use engine::osc::OscServer`, and so on). The library crate is
   called `engine`, as `src/bin/plugin_host.rs` already uses. Keep the `#[global_allocator]` for
   `rt-debug` in `main.rs`: it must be in the binary.
3. New `src/logging/` module in the library:
   - `logging/mod.rs`: `RotatableWriter` and `LogWriters` (now in `osc/server.rs`), and a
     `pub fn init(status_tx) -> Result<LogWriters>` that holds the subscriber setup now in
     `main()`.
   - `logging/rotate.rs`: `rotate_log_files` and `enforce_retention`, moved out of
     `OscServer`.
   - `logging/forwarder.rs`: the old `log_forwarder.rs`.
4. `main()` should end up at about 50 lines: logging, the `SONARA_SERIAL_PLUGIN_DISPATCH` switch,
   plugin log pruning, engine, window manager, file service, OSC server.

Verify: `cargo test` now runs the library tests once, and the `src/main.rs` test binary runs 0
tests. Record the new baseline count. Every later phase is compared to it. Start the engine with
`./run_release.sh` (check port 7000 first) and confirm `logs/last_info.log` and
`logs/last_warn.log` are written, and that `/project/init` rotates them into
`session_<timestamp>_*.log`.

## Phase 3: Split `audio/types.rs` (1,850 lines)

Today it holds SIMD helpers, pan, ID aliases, clips, the whole `Channel`, `Track`,
`ProjectSettings` and `AudioPlayback`.

| New file | Contents |
|---|---|
| `audio/dsp/interleave.rs` | `interleave_stereo`, `deinterleave_stereo` and their AVX/SSE/NEON versions (`pub(crate)`), with tests. |
| `audio/channel/mod.rs` | `Channel` struct, `new`, sample rate, buffers, `mix_into`, `set_aux_out`, device lookup (`device_at_path*`, `set/get_device_parameter`, `chain_list_mut`). |
| `audio/channel/pan.rs` | `PanMode`, `PanCoefficients`, `get_pan_coefficients`, `dual_matrix`, `effective_pan`. |
| `audio/channel/meter.rs` | `RMS_WINDOW_SECONDS`, `update_peaks`, `take_meters`, gain smoothing (`gain_smoothing_alpha`, `get_gain`, `get_smoothed_gain`). |
| `audio/channel/chain.rs` | Device chain and note processing: `process_device_chain*`, `begin/resume_device_chain`, `complete_chain_step`, aux source, `dispatch_scheduled_midi`, `dispatch_notes`, `send_clip_note`, `release_*`, `stop_clip_notes`, `send_note_event_to*`. |
| `audio/channel/send.rs` | `Send`. |
| `audio/clip.rs` | `ClipNote`, `ClipType`, `ClipLoadState`, `Clip`, `ClipInstance`, `AudioPlayback` and its time-stretch maths. |
| `audio/track.rs` | `Track`. |
| `audio/project.rs` | `ProjectSettings`. |
| `audio/types.rs` (kept) | Only the ID aliases (`Tick`, `ChannelId`, `TrackId`, `NoteId`, `ClipId`, `ClipInstanceId`, `MidiNote`) and `ParamSetValue`. |

The `channel/*.rs` files are `impl Channel` blocks: Rust allows several, in child modules. Private
fields need `pub(super)`. `audio/mod.rs` re-exports `Channel`, `Clip` and the rest, so
`crate::audio::Channel` keeps working. Change `use super::types::Channel`-style imports to the
new paths.

Improvements (commit b):
- `mixing.rs` has its own `db_to_gain` with a −60 dB floor, and `processing.rs` writes the same
  formula inline for instance gain. Add `pub(crate) fn fader_gain(db: f32) -> f32` (keeping the
  −60 dB floor) in `channel/meter.rs`. Use it in `mixing.rs` and wherever `Channel::get_gain`
  computes the same thing. The clip instance gain in `processing.rs` has no floor: use
  `dsp::gain::db_to_gain` there. Don't change any floor.
- Check whether `mixing.rs` `deinterleave_extra` and `devices/container.rs` `copy_interleaved`
  can call `dsp::interleave`. Change them only where the semantics are identical.

## Phase 4: Split `audio/commands.rs` (3,971 lines)

`process_command` alone is about 2,000 lines, one `match` over 109 commands.

Target:

```
audio/state.rs               EngineState + impl (moved from commands.rs)
audio/commands/
  mod.rs                     AudioCommand enum; process_command = rendering guard + dispatch match
  status.rs                  EngineStatus + impl, BuiltinParamInfo, AudioConfigReport
  transport.rs               InitProject, ClearProject, Play/Pause/Stop/Seek, loop, tempo,
                             time signature, scale
  channel.rs                 Create/RemoveChannel, volume/pan/mute/solo/route/aux out, sends,
                             MIDI input, record arm, MidiEvent
  track.rs                   CreateTrack, SetTrackRoute, automation lanes and points
                             (automation_lane_mut)
  clip.rs                    clips, notes, audio clip loading, clip instances
  device.rs                  add/remove/move/clear devices, parameters, active/enabled, file and
                             sample loading, DeviceReady, GetDeviceState, ReloadDevice,
                             send_parameter_list
  sampler.rs                 SetSampler* / RemoveSampler* / focus / audition (with_sampler)
  layer.rs                   SetLayerSlot*, SetDrumSlot*, AuditionLayerSlot (with_layer)
  modulation.rs              modulator commands, ensure_modulated, unwrap_if_empty,
                             resend_modulators, modulator_kind_infos
  plugin.rs                  plugin parameters/state/GUI/hosting commands that end up here
  device_data.rs             Subscribe/Unsubscribe/ConfigureDeviceData
```

Keep `AudioCommand` as one flat enum. Nesting it per domain would touch every match in the
server and worker for little gain. #1 will put a separate audio-thread message type behind the
command thread anyway (Phase 13).

Each domain file exposes plain functions:

```rust
/// Set a channel's fader level in dB.
pub(super) fn set_volume(state: &mut EngineState, id: ChannelId, db: f32) { ... }
```

The dispatcher in `mod.rs` has one arm per variant that destructures it and calls the domain
function. That's about 250 lines; the compiler still checks that every command is handled. Don't
replace it with a chain of "try this module, else the next" handlers.

`EngineStatus` and `AudioCommand` are imported all over the engine. Re-export them from
`audio/commands/mod.rs` (`pub use status::*;`) so `crate::audio::commands::EngineStatus` keeps
working, and `audio/mod.rs` keeps `pub use engine::{AudioCommand, AudioEngine, EngineStatus}`.

Commit (a) moves the arms verbatim into the domain functions, (b) cleans them up (Phase 6 does
the lookup helpers). Split the 600 lines of tests by domain.

## Phase 5: Command effects (prep for #1)

Today `process_command` gets a `&Sender<EngineStatus>` and calls `status_tx.send(...)` about 23
times **while the command thread holds the state lock**. The channel is bounded (8,192). If it
ever fills, the command thread blocks with the lock held, and the audio callback outputs silence
(lock misses) until the OSC thread drains it. Removed channels, clips and devices are also
dropped under the lock, apart from the device drops `CommandWorker` already moves out.

#1 phase 2 needs exactly this split anyway: whoever applies a change to the audio graph must not
send blocking statuses or free memory.

1. Add to `audio/commands/mod.rs`:

   ```rust
   /// What applying a command produced, handled by the caller after it releases the state lock.
   #[derive(Default)]
   pub struct CommandEffects {
       /// Statuses for Godot, in order.
       pub statuses: Vec<EngineStatus>,
       /// Objects the command removed from the state, dropped after the lock is released.
       pub trash: Vec<Box<dyn std::any::Any + Send>>,
   }
   ```

2. `process_command(state, cmd, buffer_size, effects: &mut CommandEffects)`. It no longer returns
   `Option<EngineStatus>` and no longer takes `status_tx`. Every `status_tx.send(x)` becomes
   `effects.statuses.push(x)`, and the old return value is pushed too.
3. Wherever a command removes a `Channel`, `Clip` (PCM), `Track` or device from the state, push
   the removed value into `effects.trash` instead of letting it drop in place.
4. `CommandWorker::apply_locked`: build the effects, lock, apply, **unlock**, then send the
   statuses and drop the trash. Add a `///` comment explaining why.
5. Update the tests: helpers that read statuses from a channel read `effects.statuses` instead,
   which is simpler.

This is an allowed behavior change. Status order stays the same. Statuses may arrive a few
microseconds later.

## Phase 6: Device lookup helpers

`commands/*.rs`, `command_worker.rs` and `osc` repeat this nested pattern many times: "channel
exists? device at path exists? is it a `T` (downcast)? otherwise `warn!` with a slightly
different message". `with_layer`, `with_sampler`, `plugin_handle` and `with_plugin` are local
versions of the same thing.

1. In `audio/state.rs`:

   ```rust
   /// Why a command couldn't reach its device. `Display` gives the log message.
   pub enum DeviceLookupError { NoChannel(ChannelId), NoDevice(ChannelId, DevicePath), WrongType { .. } }

   impl EngineState {
       pub fn device_mut(&mut self, channel_id: ChannelId, path: &DevicePath)
           -> Result<&mut Box<dyn AudioDevice>, DeviceLookupError>;
       pub fn device_as_mut<T: AudioDevice + 'static>(&mut self, channel_id: ChannelId, path: &DevicePath)
           -> Result<&mut T, DeviceLookupError>;
   }
   ```

   `WrongType` holds `std::any::type_name::<T>()` and the device's `device_id()`.
2. Replace the hand-written lookups in `commands/*` (12 downcasts there), `command_worker` and
   `render/worker.rs` with these, followed by `warn!("{cmd_name}: {err}")`. Remove
   `with_layer`/`with_sampler` if they become one-liners.
3. Leave the downcasts inside `modulation/host.rs` alone: they look at its own wrapper types,
   not at state lookups.

Add unit tests for the three error cases and a successful typed lookup.

## Phase 7: Split `audio/command_worker.rs` (1,453 lines)

It already has `command_worker/audio_config.rs`. Make `command_worker.rs` into
`command_worker/mod.rs` and move `impl CommandWorker` blocks out:

| File | Contents |
|---|---|
| `mod.rs` | `CommandWorker` struct, `new`, `run`, `handle` (dispatch), `lock_state`, `send_status`, `apply_locked`. |
| `device_tick.rs` | `poll_devices`, `PolledPlugin`, `mark_plugin_crashed`, `PluginStatsLog`/`PluginStatsReport`, `record/report/log_plugin_stats`. |
| `plugins.rs` | `scan_plugins`, `reload_device`, `set_plugin_hosting`, `move_plugin`, `save/load_plugin_state`, `plugin_handle`, `with_plugin`, `set_plugin_active`, `open/close_plugin_gui`, the GUI visible/size arms of `handle` (as methods), `collect_sfizz_*`. |
| `devices.rs` | `advertise_builtin_devices`, `add_device`, `remove_device`, `clear_devices`, `configure_device_data`. |
| `project.rs` | `remove_channel`, `set_tempo_map`, `set_time_signature_map`, `clear_project`. |
| `render.rs` | `start_render`, `cancel_render`. |

After the move, `handle` should be a flat dispatch with no inline logic: each arm calls one
method.

## Phase 8: Split `osc/server.rs` (4,185 lines)

Target:

```
osc/
  mod.rs
  server.rs        OscServer, new, run (receive loop, GUI events, AFS polling, close events),
                   send_message
  status.rs        status thread: forwards EngineStatus, heartbeat, EngineStatsSummary,
                   decode-rate update
  encode.rs        EngineStatus -> Vec<OscMessage> (today's send_status_update, ~550 lines),
                   push_param_args, sfz_key_info_args, audio_config_args, osc_count
  gui.rs           GuiEvent, applying it to WindowManager, parse_embed_args, send_gui_embedded
  audio_files.rs   PendingClip, PendingDevice, begin_device_sample_load, handle_afs_event,
                   send_afs_event, request id helpers, is_audio_sample_path
  routes/
    mod.rs         handle_packet, handle_message: split the address, dispatch on its first
                   segment; device-path addresses go to device.rs
    transport.rs   /transport/*
    project.rs     /project/*
    channel.rs     /channel/<id>/* (without devices)
    track.rs       /track/<id>/* incl. automation and clip instances
    clip.rs        /clip/*
    device.rs      handle_device_message, /channel/<id>/add_device|remove_device|move_device|
                   clear_devices, parse_add_device_command
    device_slots.rs  sampler zones/groups, layer and drum slots (the device sub-routes)
    plugin.rs      /plugin/*, /plugins/*, /builtin/*
    audio.rs       /audio/devices/*, /audio/config/*
    render.rs      /render/*
    audiofile.rs   /audiofile/*
  parse.rs         the parse_* helpers that aren't owned by one route file, osc_int, osc_float,
                   osc_arg_types
```

Notes:
- `encode.rs` should be a pure function `fn encode_status(status: EngineStatus) -> Vec<OscMessage>`
  so it can be unit-tested without a socket. `status.rs` sends what it returns. Add a few tests
  (playhead, channel peaks, a modulator status, a parameter info) that pin the address and
  argument types. Godot depends on them.
- Route functions take a small context instead of `&self` plus four arguments:

  ```rust
  /// What a route handler needs: where to send commands and how to answer Godot directly.
  pub(super) struct RouteCtx<'a> { commands: &'a Sender<AudioCommand>, server: &'a OscServer, log_writers: &'a LogWriters, windows: &'a mut WindowManager }
  ```

  Each `routes/<area>.rs` has `pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool>`,
  returning `false` for an address it doesn't know. `routes/mod.rs` keeps today's handling of
  unknown addresses exactly (check what it does now before you move it).
- Existing parser tests move to the file that owns the parser.

## Phase 9: OSC argument reader

Most route arms are boilerplate like
`if let (Ok(id), Some(OscType::Float(db))) = (id_str.parse::<usize>(), args.first())`, and a
malformed message is dropped without a trace.

1. Add to `osc/parse.rs`:

   ```rust
   /// Reads typed OSC arguments by position; errors name the address and what was expected.
   pub(super) struct Args<'a> { addr: &'a str, args: &'a [OscType] }
   impl Args<'_> {
       fn int(&self, i: usize) -> Result<i32, ArgError>;
       fn float(&self, i: usize) -> Result<f32, ArgError>;   // keep today's int/float leniency where an arm had it
       fn bool(&self, i: usize) -> Result<bool, ArgError>;   // Int != 0
       fn string(&self, i: usize) -> Result<&str, ArgError>;
       fn blob(&self, i: usize) -> Result<&[u8], ArgError>;
       fn opt_float(&self, i: usize) -> Option<f32>;
   }
   /// Parse a path segment such as a channel or slot id.
   fn segment<T: FromStr>(addr: &str, part: &str) -> Result<T, ArgError>;
   ```

   `ArgError`'s `Display` gives `"/channel/3/volume: argument 0: expected f, got (i)"` (use
   `osc_arg_types`).
2. Rewrite the route arms to use it. Each arm becomes a few lines:

   ```rust
   ["channel", id, "volume"] => send(AudioCommand::SetChannelVolume { id: segment(addr, id)?, db: a.float(0)? }),
   ```

3. `routes/mod.rs` logs `ArgError` at WARN. This is the allowed behavior change. Keep any
   leniency that exists now: if an arm accepts both `Int` and `Float`, the reader must too.
   Compare each arm before and after.
4. Afterwards, run `Godot/tests/run_all.sh` and start the app against the engine
   (`./run_release.sh`, then `godot --path Godot`). Open a project, play, move a fader, add a
   device. Then check `Engine/logs/last_warn.log` for new argument warnings. A new warning means
   Godot is sending something malformed. File it as an issue with `gh issue create` (labels
   `engine`, `godot`, `needs-triage`). Don't silence it in the engine. If you can't run Godot,
   say so and ask the user to do this check.

## Phase 10: Split `audio/processing.rs` and `audio/mixing.rs`

`process_audio` is one 430-line function made of `rt_debug::section` blocks. Give each section a
function, and pass only the `EngineState` fields it uses (disjoint borrows such as
`&mut state.channels`, `&state.clips`, `&state.tempo_map`). That shows which data each stage
touches, which is the map #1 needs.

```
audio/processing/
  mod.rs        process_audio: the order of the stages, the playing check, tick update
  live_midi.rs  schedule_live_midi_events
  timeline.rs   tick events: frames_before_tick, frame_rate_at, collect_tick_events(_looped),
                advance_tick (+ the loop/tempo tests)
  clip_midi.rs  the "clip MIDI" section
  clip_audio.rs the "audio clip render" section
audio/mixing/
  mod.rs        mix_and_output, write_master_output, forward_device_events
  solo.rs       is_silenced, output_reaches_soloed, any_output, spread_solo_up,
                assign_solo_roles (+ solo tests)
  routing.rs    output_target, is_valid_route, add_scaled, apply_pan, count_route_inputs,
                route_channel, copy_pre_fader, begin_finish, route_finished, drain_parked,
                aux sources, extra outs (+ routing/send/async tests)
```

Audio thread rules apply strictly here:
- No new `Vec`, `String`, `Box`, `format!` or closures that capture by move into allocating
  types.
- Each `rt_debug::section` keeps its name, so `rt-debug` output stays comparable.
- Mark the new functions `#[inline]` only if profiling shows a need. Don't add it by default.

Verify, in addition to the usual checks:
- `SONARA_FEATURES=rt-debug ./run_release.sh` with a project playing clips through a CLAP
  plugin and a bus. It must report no allocations other than the known `poll_device_data` one.
  If you can't run it, ask the user.
- The engine stats INFO line (load avg/peak) is no worse than before the phase in the same
  project.

Leave `stream.rs` `run_live_block` and `render/worker.rs` `render_block` separate. They share
only three calls, and the render does extra work around each one.

## Phase 11: Group `audio/devices/`

`audio/devices/` holds 29 entries at one level, mixing effects, instruments, containers and
infrastructure. `devices/mod.rs` (774 lines) mixes the `AudioDevice` trait with parameter maths
and sleep state.

```
audio/devices/
  mod.rs            module list and re-exports only
  device.rs         AudioDevice trait, DeviceVariant, DeviceCategory, ports, FileLoadingSupport,
                    DefaultModulator
  params.rs         ParamInfo, ParamType, enum_to_norm, norm_to_real, real_to_norm, norm_to_enum
  sleep.rs          DeviceSleepState, has_audio_signal
  factory.rs        (unchanged)
  param_table.rs    (unchanged)
  effects/          effect.rs, chorus, compressor, delay, eq, filter, multiband, phaser, reverb,
                    utility, spectrum_analyzer, effect_conformance.rs
  instruments/      polysynth/, sampler (+ sampler_zones), sfizz_device (+ sfizz_keys), drums/
                    (+ drum_conformance.rs)
  containers/       container.rs, chain.rs, layer.rs, drum_machine.rs
  note_fx/          (unchanged)
  clap_host/        (unchanged, minus Phase 1 deletions)
```

This is a pure move: `devices/mod.rs` re-exports every public type, so paths outside
`devices/` such as `crate::audio::devices::DevicePath` and `ParamInfo` keep working. Inside
`devices/`, fix the `super::` paths. Do it in one commit, with no other changes.

## Phase 12: Split `ipc/process_manager.rs` and `devices/sampler.rs`

These two are large but cohesive, so do them last. Skip either one if the split isn't clean.
Note that in the **Log**.

`audio/ipc/process_manager.rs` (1,242 production lines) becomes `audio/ipc/process/`:
- `launch.rs`: `HostLaunch`, `split_command`, `plugin_log_dir`, `prune_plugin_logs`,
  `spawn_program`, `move_fd_to`
- `crash.rs`: `HostExit`, `HostCrash`, `signal_name`, `open_pidfd`, `wait_for_exit`, stderr draining
- `routing.rs`: `Routing`, `run_reader`
- `process.rs`: `PluginProcess`
- `connection.rs`: `InstanceConnection`
- `mod.rs`: `ProcessManager`

`audio/devices/sampler.rs` (1,781 production lines, 1,170 test lines) becomes
`instruments/sampler/`. Read the file first and split it along its existing sections, following
`polysynth/` (`mod.rs` device, `voice.rs`, `params.rs`), with `zones.rs` from today's
`sampler_zones.rs`.

## Phase 13: Docs, command classification for #1, close-out

1. Update the paths and descriptions in:
   - `AGENTS.md`: Engine threads section (`main.rs`, `osc/server.rs` →
     `osc/routes/`, `audio/commands/`, `audio/command_worker/`), the "When you add an OSC
     message" sentence, and the built-in device paths.
   - `docs/subsystems/engine-architecture.md`: the file tree and the command thread paragraph,
     including `CommandEffects`.
   - `docs/subsystems/engine-audio-thread.md`: file references.
   - `docs/subsystems/osc-protocol.md`: the "source of truth" line → `osc/routes/` and
     `osc/encode.rs`.
   - `docs/subsystems/engine-plugin-architecture.md`: the in-process adapter is gone.
2. Add a **Command classification** section to `engine-architecture.md`: one table row per
   `AudioCommand` with its class:
   - **graph edit**: a pure state change that could become a message to an audio-thread-owned
     state;
   - **build/teardown**: needs allocation or slow work off the audio thread (devices, clip PCM,
     channels);
   - **query**: answers Godot, may need IPC;
   - **command thread only**: plugins, stream, render.

   Include which `EngineState` fields each `processing/` and `mixing/` stage reads and writes
   (from Phase 10). This is the input #1 phase 2 starts from. Add a link to it in issue #1 with
   `gh issue comment 1`.
3. Comment on issue #67 with a summary: phases done, lines before and after for the files listed
   below, deleted dead code, dependencies removed, anything skipped and why. Don't close the issue
   yourself. The user decides after a live check.

### File sizes before (production lines, excluding `mod tests`)

| File | Total | Production |
|---|---|---|
| `osc/server.rs` | 4,185 | 3,709 |
| `audio/commands.rs` | 3,971 | 3,385 |
| `audio/devices/sampler.rs` | 2,955 | 1,781 |
| `audio/types.rs` | 1,850 | 1,411 |
| `audio/command_worker.rs` | 1,453 | 1,453 |
| `audio/ipc/process_manager.rs` | 1,707 | 1,242 |
| `audio/mixing.rs` | 1,743 | 715 |
| `audio/processing.rs` | 1,191 | 579 |
| `audio/devices/mod.rs` | 774 | 774 |
| `audio/devices/clap_host/adapter.rs` + `host_impl.rs` (dead) | 1,097 | 1,097 |

### File sizes after (production lines, excluding `mod tests`)

Measured at the end of Phase 13 with the same rule as the table above (lines before the `#[cfg(test)] mod tests {` block; separate `tests.rs` and `test_support.rs` files count as 0).

| Before | After | Files | Production total | Largest file |
|---|---|---|---|---|
| `osc/server.rs` (3,709) | `osc/` (`server`, `status`, `encode`, `gui`, `audio_files`, `parse`, `routes/*`) | 19 | 3,834 | `encode.rs` 620 |
| `audio/commands.rs` (3,385) | `audio/commands/` + `audio/state.rs` | 13 | 4,314 | `commands/mod.rs` 1,288 (the `AudioCommand` enum plus the dispatcher) |
| `audio/devices/sampler.rs` (1,781) | `instruments/sampler/` (without `zones.rs`) | 7 | 1,854 | `mod.rs` 417 |
| `audio/types.rs` (1,411) | `audio/channel/`, `clip.rs`, `track.rs`, `project.rs`, `dsp/interleave.rs`, `types.rs` | 10 | 1,394 | `channel/chain.rs` 319 |
| `audio/command_worker.rs` (1,453) | `audio/command_worker/` (with the older `audio_config.rs`) | 7 | 1,931 | `plugins.rs` 599 |
| `audio/ipc/process_manager.rs` (1,242) | `audio/ipc/process/` | 6 | 1,315 | `launch.rs` 331 |
| `audio/mixing.rs` (715) | `audio/mixing/` | 4 | 790 | `routing.rs` 354 |
| `audio/processing.rs` (579) | `audio/processing/` | 5 | 731 | `clip_audio.rs` 259 |
| `audio/devices/mod.rs` (774) | `devices/{mod, device, params, sleep}.rs` | 4 | 767 | `device.rs` 510 |
| `clap_host/adapter.rs` + `host_impl.rs` (1,097) | deleted | 0 | 0 | |

The totals grow a little: every new file has its own `use` block, `//!` header and doc comments, and `encode.rs`, `parse.rs` and `routing.rs` gained code in Phases 8 and 9.

Goal: no production file over ~800 lines outside `devices/` DSP code, and no function over ~150
lines except the two dispatch matches (`commands/mod.rs`, `command_worker/mod.rs`) and
`encode_status`.

Goal check at the end: the exceptions are `commands/mod.rs` (1,288: the plan allows the dispatch match, and the 580-line
`AudioCommand` enum sits in the same file), `audio/modulation/host.rs` (1,203), `window_manager.rs` (878), `audio/stream.rs` (855)
and `plugin_host/audio_thread.rs` (825), which were not in this plan, and the device DSP files (`reverb`, `compressor`, `eq`,
`filter`, `sfizz_device`, `polysynth/mod`, `clap_host/subprocess_adapter/mod`, `note_fx/host`). `command_worker::device_tick::poll_devices`
is still about 170 lines (Phase 7). Function lengths were not re-measured beyond the ones named in the phase notes.

## Out of scope

- Removing `Arc<Mutex<EngineState>>` and the lock-free command queue: that's #1 phase 2. This plan
  only prepares for it (Phases 5, 10 and 13).
- Plugin latency compensation, RT priority and CPU affinity (#1).
- Changes to OSC addresses or arguments, and Godot code other than fixing bugs Phase 9 finds
  (those go into issues).
- Rewriting device DSP. Large effect files (`compressor.rs`, `reverb.rs`, `eq.rs`) stay as they
  are apart from the Phase 11 move.
- The `plugin_host/` subprocess modules. They're already split by concern.

## Log

| Phase | Date | Tests (passed / ignored) | Warnings | Notes |
|---|---|---|---|---|
| 0 | 2026-10-09 | lib 804 / 14; bin engine 789 / 14 (duplicate run) | release 138; test build 117 | Baseline. No flaky test seen. Port 7000 held by user's engine (live checks pending). |
| 1 | 2026-10-09 | lib 804 / 14; bin engine 789 / 14 (unchanged) | lib crate 0; `engine` bin 58 (was 138) | See notes below. |
| 2 | 2026-10-09 | lib 804 / 14; bin engine 0 / 0 | release 0; test build 0 | New baseline: 804 passed, 14 ignored. Live check pending (see notes). |
| 3 | 2026-10-09 | lib 807 / 14 (804 + 3 new tests) | release 0; test build 0 | Commits `Engine cleanup phase 3` (a) pure move, (b) improvements. See notes below. |
| 4 | 2026-10-09 | lib 807 / 14 | release 0; test build 0 | Commits `Engine cleanup phase 4` (a) move, (b) improvements. See notes below. |
| 5 | 2026-10-09 | lib 810 / 14 (807 + 3 new tests) | release 0; test build 0 | Allowed behavior change, own commit. See notes below. |
| 6 | 2026-10-09 | lib 814 / 14 (810 + 4 new tests) | release 0; test build 0 | See notes below. |
| 7 | 2026-10-09 | lib 814 / 14 | release 0; test build 0 | Commits `Engine cleanup phase 7` (a) pure move, (b) handle arms as methods. See notes below. |
| 8 | 2026-10-09 | lib 823 / 14 (814 + 9 new encode tests) | release 0; test build 0 | Commits `Engine cleanup phase 8` (a) pure move, (b) RouteCtx, `encode_status`, `GuiEvent::apply`. See notes below. |
| 9 | 2026-10-09 | lib 842 / 14 (823 + 8 `Args` tests + 1 device test + 10 routing tests) | release 0; test build 0 | Allowed behavior change: malformed messages log a WARN. Live Godot check pending. See notes below. |
| 10 | 2026-10-09 | lib 842 / 14 | release 0; test build 0 | Commits `Engine cleanup phase 10` (a) pure move of `processing.rs`, (a) pure move of `mixing.rs`, (b) stages over disjoint fields. Live `rt-debug` and load check pending. See notes below. |
| 11 | 2026-10-09 | lib 842 / 14 | release 0; test build 0 | One pure-move commit. See notes below. |
| race fix | 2026-10-09 | lib 842 / 14 | release 0; test build 0 | `crash_info` no longer races the exit watcher (own commit). See notes below. |
| 12 | 2026-10-09 | lib 842 / 14 | release 0; test build 0 | Two pure-move commits (`ipc/process/`, `sampler/`); no (b) commits. See notes below. |
| 13 | 2026-10-09 | lib 842 / 14 | release 0; test build 0 | Docs, command classification, size table. Comments for #67 and #1 are drafts in `.scratch/`, not posted. Live checks open (see Phase 13 notes). |

Phase 1 notes:

- Deviation: the `engine` bin build still reports 58 warnings. All of them are closed-world artifacts of
  `main.rs` declaring its own copy of the modules: `pub use` re-exports and `pub` items that only the
  library, `plugin_host` or tests use (`DeviceVariant`, `AudioPort`/`MidiPort`/`PortType`, `from_fd`,
  test-only helpers such as `magnitude_db`, `set_sleep_timeout`, ...). Deleting those would break
  `plugin_host` or tests, so they stay and Phase 2 (one crate, no duplicate module tree) removes the
  warnings. The library crate itself is at 0 warnings. Phase 2 re-checks for 0 across all targets.
- Dependencies: `byteorder`, `libloading`, `tracing-appender`, `once_cell` removed (`LazyLock` instead);
  `tempfile` moved to `[dev-dependencies]`.
- Deleted: in-process CLAP adapter (`adapter.rs`, `host_impl.rs`, 1,097 lines) and the
  `downcast_mut::<ClapDeviceAdapter>` block in `forward_device_events` (own commit);
  `dsp/simd.rs` (only `mix_blocks`, never called); `CommandResponse`; `EngineStatus::DeviceReady`
  (never constructed; `AudioCommand::DeviceReady` stays); `AudioEngine::{new, send_command,
  status_sender, is_playing, current_tick}` and its `status_tx` field; `Channel::{resize_buffers,
  mix_into, process_device_chain_from, set_device_parameter, get_device_parameter}`;
  `AudioPlayback` fields/`new`/`advance_and_get_sample`/`calculate_stretch_factor`/`lerp` (it stays as a
  namespace for `clip_source_frame` and friends); `ProjectSettings::{ticks_per_sample, ticks_per_second,
  seconds_per_tick, samples_to_ticks, ticks_to_samples}`; `AudioFileService::active_jobs` (worker handles
  were only stored, never joined); `DecodedInfo::source_frames`; `PluginDescriptor::url`;
  `PluginError::{NotFound, InitializationFailed, ActivationFailed}`; the unreachable `_ =>` arm in
  `plugin_host::process_command`; the plugin scanner's `get_plugin`/`plugin_count`/`clear`; the `has_gui`
  chain; phaser module-id constants; `ParamValues::{table, norm_at}`, `ModParams::{kind, norm_at}`,
  `AdsrEnvelope::{set_decay, set_sustain, set_release, process_block}`, `Ladder/LinearSvf/PinkNoise::reset`,
  `Waveform` enum, `SweepOsc::phase`, `EnvFollower::set_detection`, `MultibandSplitter::crossover_count`,
  `PluginProcess/InstanceConnection::{log_path, host_key}`, `ProcessManager::shutdown_all`,
  `load_audio_file`, `clamped_count`, `MidiEvent::{note_off, control_change}`, `PeakBuilder::frames`,
  `WindowManager::get_window_handle`, `ChainDevice::volume`, `StreamInfo::buffer_frames`.
- `multiband.rs` `band_*_id` and `DEFAULT_EDGES`, `AudioFileService::wait_for_events` and `read_texel` are
  now `#[cfg(test)]` (tests use them). `PeakHeader` fields read only by tests carry `#[allow(dead_code)]`.
- Fixed: `EventLoopBuilder::new()` (deprecated) -> `EventLoop::builder()`; `unsafe` around the safe
  `HostSharedMemory::from_fd` in `plugin_host.rs`; `did_process` flag in `mixing.rs` (always true).
- Flaky: `audio::ipc::process_manager::tests::stderr_tail_keeps_only_the_last_lines` failed once in the
  `--bin engine` run and passed on rerun.
- Docs mentioning deleted names remain in older design notes (`docs/specs/008`, `010`, `waveform-plan.md`
  mention `calculate_stretch_factor`); they are historical and were left alone.

Phase 2 notes:

- `main.rs` is 69 lines (was 187) and imports from the `engine` library. `logging/` holds
  `RotatableWriter`, `LogWriters`, `init(&status_tx)` (takes a reference and clones for the forwarder),
  `rotate.rs` (`rotate_log_files`, `enforce_retention`, now top-level functions) and `forwarder.rs`
  (moved with `git mv` from `log_forwarder.rs`). `lib.rs` declares `logging` directly instead of the
  intermediate `log_forwarder` step.
- Warnings are 0 in `cargo build --release` and `cargo test --no-run`. The Phase 1 residue (58 bin-view
  warnings) disappeared with the duplicate module tree, so the pub items and re-exports listed in the
  Phase 1 notes stayed as library API.
- Live check (engine on port 7000, `last_*.log` written, `/project/init` rotation) is pending: the
  user's engine held port 7000 while this was done, so no engine was started.

Phase 3 notes:

- Layout: `audio/channel/{mod 203, chain 516, meter 185, pan 251, send 10}`, `audio/clip.rs` 201,
  `audio/track.rs` 33, `audio/project.rs` 61, `audio/dsp/interleave.rs` 300, `audio/types.rs` 39 (aliases and
  `ParamSetValue`). Line counts include tests.
- `types.rs` became `channel/mod.rs` with `git mv`; a new `types.rs` holds the aliases. `audio/mod.rs` re-exports
  `Channel`, `PanMode`, `PanCoefficients`, `Send`, the clip types, `ProjectSettings` and `Track` so `crate::audio::X`
  paths are unchanged. Imports of `audio::types::<moved item>` were updated at their call sites.
- Child modules see `Channel`'s private fields, so no `pub(super)` on fields was needed. Only
  `gain_smoothing_alpha` is `pub(super)`.
- Improvements: `channel::fader_gain` (the -60 dB floor) replaces `mixing.rs` `db_to_gain` and the inline formula in
  `Channel::get_gain`; the clip instance gain in `processing.rs` uses `dsp::gain::db_to_gain` (no floor, as before);
  `mixing.rs` `deinterleave_extra` now calls `dsp::interleave::deinterleave_stereo` (same clamping, so same output).
  `devices/container.rs` `copy_interleaved` is a plain slice copy, not an interleave, so it was left alone.
  New tests: `fader_gain` floor, interleave/deinterleave round-trips over SIMD and tail lengths.
- Flaky: one `cargo test` run in the (b) commit failed one lib test (name not captured); the rerun passed 807.

Phase 4 notes:

- Layout (lines include tests): `audio/state.rs` 130, `audio/commands/{mod 1230 (the 580-line `AudioCommand` enum plus a
  600-line dispatcher), status 386, transport 138, channel 369, track 223, clip 595, device 539, sampler 291,
  layer 221, modulation 577, plugin 124, device_data 69}`. `commands.rs` became `commands/mod.rs` with `git mv`.
- Each of the 89 handled commands is now a `pub(super) fn` in its domain module taking the destructured fields
  (plus `state`, `buffer_size` and `status_tx` only where the body uses them). Bodies moved verbatim; `super::` paths
  became `crate::audio::`. A function returns `Option<EngineStatus>` only when the old arm had `return Some/None`;
  the dispatcher writes `return module::f(..)` for those and a plain call for the rest, so the match still
  evaluates to `()` and `None` follows it, as before. The dispatcher is about 600 lines after `rustfmt` (the plan
  estimated 250): multi-field arms wrap.
- Deviations from the table: the sampler sample-loading commands (`BeginLoadDeviceSample`, `LoadDeviceSample`,
  `FailDeviceSampleLoad`) are in `sampler.rs` because they use `with_sampler`; `AuditionDevice` is in `device.rs` (it
  is not sampler-specific). `SetPluginGuiVisible | SetPluginGuiSize` share one function,
  `plugin::plugin_gui_unavailable`. The `other @ (...)` arm for worker-only commands stays inline in the dispatcher.
  `EngineStatus`, `BuiltinParamInfo` and `AudioConfigReport` are re-exported from `commands/mod.rs`, so
  `crate::audio::commands::EngineStatus` still works; `EngineState` is imported from `audio::state` everywhere
  (no re-export in `commands`; `audio::engine` still re-exports it).
- Tests moved to the domain they cover (device 4 + 1 helper, modulation 5, channel 1, clip 1, sampler 1, plugin 1);
  fixtures stayed with their only users, so no shared `test_support` module was needed.
- Improvements: deleted `impl Clone for EngineState` (Phase 1 listed it but it was still there; nothing used it);
  merged the generated `use` lines; every new function has a doc comment.

Phase 5 notes:

- `CommandEffects { statuses, trash }` (plus `discard(value)` and a test-only `next_status`) lives in `commands/mod.rs`.
  `process_command(state, cmd, buffer_size, &mut effects)` returns `()`: it wraps a private `dispatch` that still
  returns `Option<EngineStatus>`, and pushes that value after everything the command pushed itself. That keeps the
  old order exactly (channel sends first, returned status last) without touching the 100 dispatcher arms.
  `status_tx: &Sender<EngineStatus>` parameters became `effects: &mut CommandEffects` in `transport`, `device`,
  `modulation`, `plugin` and `clip`.
- `CommandWorker::apply_locked` locks in an inner block, then sends the statuses in order and drops `trash`.
- Trash: a removed `Clip` (`remove_clip`) and clip PCM that is replaced or cleared (`load_audio_clip`,
  `begin_load_audio_clip`, `fail_audio_clip_load`; `Vec::clear` used to keep the allocation, now the buffer is taken
  and freed after the unlock) and the incoming `samples` of a stale or orphaned `LoadAudioClip`. Channels, devices,
  the tempo maps and `clear_project` were already detached under the lock and dropped after it in `CommandWorker`,
  and there is no `process_command` arm that removes a track or channel, so nothing else needed `trash`.
  Left under the lock: the `ModulatedDevice` wrapper dropped by `unwrap_if_empty`, modulators dropped by
  `clear_modulators`, and sampler zones dropped by `remove_zone` (small, and the device APIs don't return them).
- Deviation (same pattern): `SamplerDevice::resend_zone_states` sent through the device's own `status_tx`
  inside `GetDeviceState`. It is now `zone_state_statuses() -> Vec<EngineStatus>` and the command queues the result,
  so those statuses keep their place between the parameter list and the modulators instead of jumping ahead.
- Lock-held sends that remain, listed rather than fixed: `SamplerDevice` (`emit_loading`, `emit_zone_loading`) and
  `SfizzDevice` (loading state) send through their own `status_tx` from inside commands, with the lock held. They
  can now arrive before the same command's `CommandEffects` statuses. The audio callback and `mix_and_output`
  use `try_send` (non-blocking) under the lock. `render/worker.rs` sends outside the lock everywhere
  (`try_send` for progress). `CommandWorker` sends nothing with the lock held (`poll_devices`, `add_device` and the
  rest collect first).
- Flaky: `audio::ipc::process_manager::tests::watcher_records_exit_code_and_stderr` failed once in a full
  `cargo test` run and passed in 3 reruns.

Phase 6 notes:

- `audio/state.rs` has `DeviceLookupError { NoChannel, NoDevice, WrongType { channel_id, device_path, expected, found } }`
  (`Display` + `Error`; `expected` is `type_name::<T>()`, shown without its module path, `found` is `device_id()`),
  `EngineState::device_mut` and `device_as_mut::<T>`. Deviation: `device_mut` returns `&mut dyn AudioDevice` (what
  `Channel::device_at_path_mut` gives), not `&mut Box<dyn AudioDevice>`.
- `commands/mod.rs` has `with_device::<T, R>(state, cmd, channel_id, path, apply) -> Option<R>`, which logs
  `"{cmd}: {err}"` on a miss. It replaces `with_sampler` (removed). `with_layer` stays as a thin wrapper that adds
  the "slot not found" warning; the Drum Machine commands use `with_device` directly.
- Converted: `layer.rs` (all 8, so a missing or wrong device now warns in every command, not only some), `sampler.rs`,
  `device.rs` (set parameter, active, enabled, load file, audition, get parameters, get state, device ready),
  `device_data.rs`, `CommandWorker::configure_device_data`, `with_plugin` and the poll's `cache_parameter_value`.
  `with_plugin`, the poll and the apply-data-build swap use `.ok()` / `Err(_)`: a miss there is normal (the device was
  removed meanwhile) and must stay quiet. `plugin_handle` is still `with_plugin`.
- Not converted on purpose: `modulation.rs` (its messages go to Godot's `/log` and mention what was being modulated),
  `plugin.rs::save_plugin_state` (an existence check that must always answer), the `visit_devices_mut` walks in
  `command_worker` / `audio_config` / `render/worker.rs` (they scan every device, not one path), `add_device`'s
  container lookup, and `modulation/host.rs`. `osc/` has no state lookups.
- Phase 5 leftover fixed on the way: `load_device_sample` now takes `CommandEffects`, so the PCM of a sample that
  finds no Sampler is freed after the lock instead of inside the closure.
- New tests (4, in `state.rs`): missing channel, missing device, wrong type (including message), typed lookup.
- Flaky: `audio::ipc::process_manager::tests::watcher_records_exit_code_and_stderr` failed again in one full run
  (passes alone and on rerun).

Phase 7 notes:

- Layout (lines): `command_worker/{mod 277, device_tick 386, plugins 599, devices 213, project 69, render 37, audio_config 350}`.
  `command_worker.rs` became `mod.rs` with `git mv`. `mod.rs` keeps the struct, `new`, `run`, `handle`, `lock_state`,
  `send_status`, `apply_locked` (and `DEVICE_POLL_INTERVAL`, `AudioSettings`); `device_tick.rs` also owns `PolledPlugin`,
  `PluginStatsLog`, `PluginStatsReport` and the two stats intervals.
- Commit (a) verification: the sorted removed and added lines of the commit, compared after dropping the `pub(super) `
  prefix, differ only in `use` lines, `mod` lines, the new `//!` headers and `impl CommandWorker {` wrappers, three
  signatures that `rustfmt` re-wrapped (`save_plugin_state`, `load_plugin_state`, `remove_device`) and the three
  `PolledPlugin` fields made `pub(super)`. Every moved method became `pub(super)` (callers are now in sibling files).
- Commit (b): the inline `handle` arms became methods in `plugins.rs` (`set_device_active`, `open_gui`, `close_gui`,
  `set_gui_visible`, `set_gui_size`) and `set_master_route` in `mod.rs`; `handle` is now a flat dispatch (about 95 lines,
  one call per arm). `collect_sfizz_*` live in `plugins.rs` as the plan says although only `poll_devices` calls them.
- `device_tick::poll_devices` is still about 170 lines, over the ~150 goal. Left for later: it is one pass in three
  stages (collect under the lock, service without it, send), and splitting it was not part of this phase.

Phase 8 notes:

- Layout (lines, tests included): `osc/{mod 9, server 181, status 223, encode 935 (about 620 production), gui 209, audio_files 383,
  parse 52 before phase 9}`, `osc/routes/{mod, transport, project, channel, track, clip, device, device_slots, plugin, audio, render,
  audiofile}.rs`. `server.rs` stays as the file with `OscServer`, `new`, `run` and `send_message`; the receive loop is unchanged.
- Unknown addresses: before and after, `handle_message` logs `warn!("Unknown OSC address: {addr}")` and returns `Ok(())` (the message is
  dropped, a bundle goes on). A well-formed device address (`/channel/{id}/device/{path}/...`) with an action nobody knows logs
  `Unhandled device OSC action {action:?} on channel {id} path {path}` and returns `Ok(())`. A device address that fails
  `parse_osc_device_addr` falls through to the first-segment dispatch and ends as an unknown address, as before.
- Commit (a) verification: the sorted, whitespace-normalised lines of the old `server.rs` and of the new files compared as multisets.
  59 lines (distinct) disappear and about 214 distinct lines appear. Everything else is the same text. The differences are: `use`
  and `mod` lines and the new `//!` headers; `pub(super)` on the fields of `OscServer`, `Pending*`, and on moved functions; the
  per-area route method signatures (`&self, parts, args, command_tx` and `-> Result<bool>`), `match parts {`, `_ => return Ok(false)`
  and `Ok(true)`; the first-segment dispatch in `routes/mod.rs`; `status::spawn(...)` replacing the closure in `run` (its body moved
  into `status.rs` with `Self::send_status_update` renamed); `GuiEvent` moved out of `run` (de-indented); `args.as_slice()` -> `args`
  in `/transport/loop`; `super::` prefixes dropped from moved tests and re-wrapped `rustfmt` lines. Stray doc comments were
  re-attached to the items they belonged to (`send_gui_embedded`, `parse_automation_point`, `parse_tempo_map_args`, `ClipNoteArgs`;
  the comment above `/render/start` that described `/audio/config/set` moved to that arm).
- Deviation: the sampler/slot sub-routes of a device address are tried from the `_` arm of `device::handle_device_message`
  (`device_slots::route`), not from `routes/mod.rs`; the plan's `route` signature takes the device ids too, so `device_slots::route` has
  its own. `device::route` handles the channel-level `add_device`/`remove_device`/`move_device`/`clear_devices` and `device::handle_device_message`
  the device-path ones. `RouteCtx` also carries `addr` (needed by a few warnings). `audiofile::route` only needs `&RouteCtx`.
- Commit (b): `RouteCtx`, free `route` functions, `GuiEvent::apply` (the window part of the main loop), `encode::encode_status`
  (pure; the socket part is `status::send_status`), nine new tests pin address and OSC types of the playhead, playing state, channel
  peaks, device-path statuses, the five modulator statuses, `/builtin/modulator_kind`, `param/info`, `/builtin/info`, engine stats and the
  render/clip statuses. No address, argument order or type changed.
- Goal check: no production file in `osc/` is over 800 lines. `encode_status` is about 520 lines (the plan allows it).

Phase 9 notes:

- `parse.rs`: `ArgError` (`Arg`, `Segment`, `Invalid`), `segment::<T>`, `Args` with plain readers (`int`, `float`, `bool`, `string`,
  `blob`, `non_negative`, `unsigned`), the lenient ones that keep the wider acceptance some arms had (`lenient_int` = `osc_int`: `i`,
  `h` or `f`; `float_or_int`: `f` or `i`), the `opt_*` readers (absent or mistyped -> `None`, for arguments with a default), `exactly`
  and `mismatch`. `osc_float` stays as the helper `parse_zone_set` uses. Deviation from the plan: it names more readers than the
  plan's list because the arms differ in what they accepted. `ArgError`'s text is `"{addr}: argument {i}: expected {tag}, got ({all type
  tags})"`, `"{addr}: path segment '{part}': expected {type}"` or `"{addr}: {message}"`.
- `routes/mod.rs::warn_on_arg_error` downcasts the route's `anyhow` error: an `ArgError` is logged at WARN and counts as handled
  (so it is not also reported as an unknown address and does not abort the rest of a bundle); any other error (a closed command
  channel) goes up as before.
- Arm-by-arm review. Same acceptance as before: floats stay `f`-only (volume, pan, pan_width, tempo, instance gain, slot volume, modulator
  values), flags stay `i`-only (`!= 0`), `send/.../amount` stays `f` or `i`, `send/.../add` keeps its defaults (-12 dB, post-fader) for an
  absent or mistyped optional value, `pan`'s right value is still ignored unless it is an `f`, `add_device` keeps `active`/`enabled`
  (default true), `type` (default `builtin`) and `file` (default empty), `/audiofile/samples` keeps `i`/`h` non-negative,
  `gui/visible`, `gui/size`, `multisample`, `focus_zone` and the sampler `audition` keep `osc_int` (`i`, `h` or `f`), `slot/N/note`
  keeps `i` or `f`, `data/configure` keeps `f`, `i` or `d`, `/transport/loop` still needs exactly three `i`. Casts are unchanged
  (`as usize`, `as u8` ...), so a negative int still wraps the way it did.
- Cases that now warn although they were silent: a wrong type, a missing argument or a bad path segment in every converted arm;
  `aux_out` with a negative index; `modulator/add` with an id outside 0..=255; an unknown `modulator/...` action; the nested
  `add_device` with a missing id or position; `param/N` with a value that is neither `f` nor `i`; `/render/cancel` and the
  `gui/*`, `multisample`, `focus_zone`, `audition`, `/project/*`, `/data/configure` messages that already warned now log the
  `ArgError` text instead of their old text. Left as they were (they already warned in their own words): `gui/open|embed|bounds`,
  `zone/N/set`, `zone/N/load_file`, `zone_group/N/set`, the clip note messages, `/plugins/hosting`, `/audio/config/set`,
  `/render/start|analyze` (these answer `RenderFailed`), the automation target parse, and the tempo and time signature maps.
- Possible differences to be aware of: the nested and channel-level `add_device` share one parser (the channel-level arm still logs
  `Add device ...`); `midi_event`/`midi_cc` read their arguments after taking `Instant::now()`, as before; `gui/size` with a
  non-positive size still warns with its old text.
- Tests: 8 `Args`/`segment`/`ArgError` tests, `add_device` defaults, the modulator parser moved to `Result` (same cases), and 10 routing
  tests through `handle_packet` (strictness, leniency, defaults, bundle not aborted, WARN text captured).
- Godot tests: `Godot/tests/run_all.sh -j2` in the worktree (after `godot --headless --path Godot --import`, which a fresh worktree needs
  for the class cache): 200 of 201 scripts pass. `tests/test_grid_levels.gd` prints `ALL PASSED` but is flagged failed by a compile error
  (`Identifier not found: AudioEngineOSC` in `data/Project.gd` when `GridHelper` loads standalone); no Godot code was changed here.
  Live check (engine plus app, `last_warn.log`): pending, port 7000 was held by the user's
  engine. A static read of every `AudioEngineOSC.send` call in `Godot/` found no argument type that the engine rejects.

Phase 10 notes:

- Layout (lines, tests included): `audio/processing/{mod 202, live_midi 86, timeline 301, clip_midi 437, clip_audio 348}`,
  `audio/mixing/{mod 344, solo 364, routing 1021, test_support 120}`. Production code in `routing.rs` is about 350 lines; the rest of its
  size is the routing, send and async-plugin tests. `processing.rs` and `mixing.rs` became `mod.rs` with `git mv`.
- Commit (a), processing: the sorted, whitespace-trimmed lines of the old file and the new files compared as multisets. The only
  differences are `use`/`mod` lines, the new `//!` headers, `pub(super)` on `advance_tick`, `collect_tick_events_looped`, `frame_rate_at`
  and `schedule_live_midi_events`, a `pub use timeline::frames_before_tick`, and one `rustfmt` re-wrap of two signatures. Tests moved
  with the code they cover (live MIDI tests to `live_midi.rs`, loop and tempo tests to `timeline.rs`); the clip tests waited in `mod.rs`
  for commit (b).
- Commit (a), mixing: same comparison. Differences are `use`/`mod` lines, `//!` headers, `pub(super)` on moved functions, re-wrapped
  signatures, and the test fixtures: `TestDevice`, `add_test_device`, `test_channel`, `state_with`, `mix`, `track_bus_master_state`,
  `send_to` and the three constants moved to `test_support.rs` (`pub(super)`, fields of `TestDevice` too). The `soloed_*` tests went to
  `solo.rs`, the master output tests stay in `mod.rs`, everything else (routing, sends, aux sources, async plugins) is in `routing.rs`.
- Commit (b), processing: `schedule_live_midi_events(&mut channels, ..)`, `dispatch_clip_midi(&tracks, &clips, &mut channels, &tick_events,
  &loop_wraps, &mut note_events)`, `render_audio_clips(&mut tracks, &clips, &mut channels, &settings, device_sample_rate, &tick_rates,
  BufferSpan { .. })` and `automation::apply_automation(&mut tracks, &mut channels, tick)` (signature changed from `&mut EngineState`; it already
  split the borrow itself; its tests were updated). The `rt_debug::section` names are unchanged: "live MIDI scheduling", "automation",
  "tick events", "clip MIDI", "audio clip render". The two long section bodies are split further (`collect_instance_note_events`,
  `mix_instance_frame`) so no function is over 150 lines; bodies are verbatim apart from `continue` -> `return` where the early exit
  now leaves the extracted function, and `sample_left`/`sample_right` becoming `&mut f32` (the mono case still adds the accumulated left
  sample, as before).
- Changes on the audio thread beyond moving code: (1) `clip MIDI` read `state.tracks.get_mut(&id)` only to read `channel_id`; it is now
  `tracks.get(&id)` on a shared reference (no behavior change). (2) The automation tick is read with `get_current_tick()` just before the
  section instead of inside it (same atomic load, one statement earlier). Nothing allocates, locks or boxes that did not before; no
  `#[inline]` added. `BufferSpan` is a small `Copy` struct on the stack.
- Commit (c), mixing: `mix_and_output` is split into `device_prepass`, `apply_fader_and_pan` and `route_in_dependency_order` (private
  functions in `mixing/mod.rs`, bodies verbatim). It already took only `channels` and `render_scratch` from `EngineState`.
- No stage still takes `&mut EngineState`, except `process_audio` and `mix_and_output` themselves, which destructure it.
  `apply_transport` and `fill_tick_rates` calls stay inline in `process_audio` (they are not `rt_debug` sections).
- Live check (`SONARA_FEATURES=rt-debug ./run_release.sh` with clips through a CLAP plugin and a bus; engine stats load average/peak):
  pending. Port 7000 was held by the user's engine, so nothing was started.
- Flaky: `audio::ipc::process_manager::tests::stderr_tail_keeps_only_the_last_lines` and `watcher_records_exit_code_and_stderr` failed in
  several full `cargo test --lib` runs and passed on rerun and when run alone (`cargo test --lib process_manager`).

Stage map for #1 (what each stage reads and writes). `EngineState` fields: `channels`, `tracks`, `clips`, `settings`, `device_sample_rate`,
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

Phase 11 notes:

- Layout: `devices/{mod, device, params, sleep, factory, param_table}.rs`, `devices/effects/` (chorus, compressor, delay, effect, eq,
  filter, multiband, phaser, reverb, spectrum_analyzer, utility, `effect_conformance`), `devices/instruments/` (`polysynth/`, `drums/`,
  `sampler`, `sampler_zones`, `sfizz_device`, `sfizz_keys`, `drum_conformance`), `devices/containers/` (chain, container, layer,
  drum_machine), `note_fx/` and `clap_host/` unchanged. Each group has a `mod.rs` with the module list and its public re-exports.
- `device.rs` (the former `mod.rs`, moved with `git mv`, 510 lines with the `AudioDevice` trait), `params.rs` (`ParamId`, `ParamValue`, `ParamType`,
  `ParamInfo`, the norm/real helpers and their `curve_tests`), `sleep.rs` (`DeviceSleepState`, `has_audio_signal`). `devices/mod.rs` re-exports all of
  them with `pub use device::*; pub use params::*; pub use sleep::*;`, plus every device type and the modules outside code reaches by path:
  `container`, `sampler_zones`, `sfizz_keys`, `compressor`, `effect`, `eq` (the last three kept public so their pub helpers stay library API).
  No path outside `audio/devices/` changed.
- Path edits inside `devices/`: `use super::<root item>` became `use crate::audio::devices::<item>` in the moved files, `super::param_table`,
  `super::note_fx` and `super::container` (from `multiband`) became `crate::audio::devices::...`, `factory.rs` reaches `effects::eq`,
  `effects::compressor` and `instruments::drums`, `instruments` declares `pub mod drums` (was `mod drums`; `factory` needs the voice modules).
  Sorted-line comparison of all of `audio/devices/**/*.rs` before and after: only `use`/`mod` lines, `//!` headers, re-wrapped imports and
  the path edits above differ. `AGENTS.md` line 67 now says `audio/devices/instruments/drums/`; `factory.rs` and the conformance file names stay valid.

Race fix notes (between Phase 11 and Phase 12):

- Cause confirmed: `PluginProcess::is_alive()` calls `child.try_wait()` itself. When it saw the child's exit before the watcher thread had stored
  `routing.exit`, `crash_info()` saw `exit == None` on a connected, not-hung host, judged it not "suspicious" and returned `None` at once. In
  production the command thread's device tick could then report a dead plugin without exit code or stderr.
- Change (one line plus a comment, `crash_info`): `suspicious = !self.is_alive() || self.is_hung()` instead of `!connected || is_hung()`. A dead
  child now waits up to `CRASH_STATUS_GRACE` (250 ms) for the watcher. `std::process::Child` caches the status once reaped, so the watcher's own
  `try_wait` still returns it and records the exit. A connected, living, not-hung host still returns `None` immediately. Alternative not taken:
  recording the exit from `is_alive()` would put a second writer on `routing.exit`.
- `stderr_tail_keeps_only_the_last_lines` failed at its `crash_info().expect("crash info")` lines, which is the same race, so the same fix covers it.
- Verification: `cargo test --lib process_manager` 10 times (16 passed each time; it also passed before the fix because the race shows up under
  the load of a full run) and `cargo test --lib` 4 times (842 passed each time). Before the fix roughly 1 full run in 3 failed.

Phase 12 notes:

- `ipc/process_manager.rs` became `ipc/process/` (lines, tests included): `mod.rs` 580 (`ProcessManager`, `lock`, timeouts, 9 tests and the `fake_host` helpers), `launch.rs` 406
  (`HostLaunch`, `split_command`, log dir and pruning, `move_fd_to`, and the `spawn`/`spawn_program`/`connect` methods of `PluginProcess` as a second
  `impl` block; 3 tests), `process.rs` 268 (`PluginProcess` struct, requests, `is_alive`, `crash_info`, `kill`, `shutdown`, `Drop`), `crash.rs` 340
  (`HostExit`, `HostCrash`, `signal_name`, `open_pidfd`, `wait_for_exit`, the stderr drain, `start_supervision` as an `impl PluginProcess` block; 4 tests),
  `routing.rs` 134 (`Routing`, `run_reader`), `connection.rs` 80 (`InstanceConnection`). `ipc/mod.rs` declares `pub mod process` and re-exports the same
  names as before (`ProcessManager`, `PluginProcess`, `HostCrash`, ...). Deviation from the plan's list: `spawn_program` is a method, so it sits in
  `launch.rs` as an `impl PluginProcess` block, as does `start_supervision` in `crash.rs`. The tests that need the `fake_host` fixture stayed in `mod.rs`.
- `devices/instruments/sampler.rs` became `instruments/sampler/` (lines, tests included): `mod.rs` 417 (header, `SamplerDevice`, its constructor and loading methods,
  `impl AudioDevice`), `params.rs` 383 (parameter ids, tables, `PlayMode`, `LoopMode`, `Params`), `regions.rs` 245 (`SampleBuffer`, `Regions`, `resolve_regions`,
  `Zone`, `zone_at`, `interpolate_frame`), `voice.rs` 250 (`Voice`, loop and read functions, `render_active_voices`), `multisample.rs` 254 (the multisample-mode `impl
  SamplerDevice` block), `playback.rs` 305 (the voices `impl SamplerDevice` block), `zones.rs` 566 (`git mv` of `sampler_zones.rs`), `tests.rs` 1,199.
  `instruments/mod.rs` now has `pub mod sampler` and `devices/mod.rs` re-exports `sampler` instead of `sampler_zones`; call sites use
  `crate::audio::devices::sampler::zones::...` (no compatibility re-export). Deviation: the 1,170 test lines are device-level behaviour tests sharing fixtures
  (`device()`, `render()`, `multi()`...), so they live together in `tests.rs` instead of being split per file.
- Move verification: for both splits, the sorted, trimmed lines (after dropping `pub(super)`/`pub(crate)`) of the old file and of the new files compared as
  multisets. Differences are only `use` and `mod` lines, `//!` headers, the `impl ... {` wrapper lines of the extra impl blocks, re-wrapped `rustfmt` lines (the
  `send` signature, `read_voice`, one status match arm) and, for the sampler, the two `// === ... ===` section comments, which became the file headers.
  The process split also changed `super::protocol::log_file_name` to `crate::audio::ipc::protocol::log_file_name`. Items and fields used across the new files
  became `pub(super)`.
- No (b) commits: the pieces are cohesive after the move and the plan says to improve only if needed.

Phase 13 notes:

- Docs updated: `AGENTS.md` (engine threads, device paths, the "adding an OSC message" sentence), `docs/subsystems/engine-architecture.md` (thread model including
  `CommandEffects`, file tree, stale file references, new Command classification section with the stage read/write map), `engine-audio-thread.md`,
  `osc-protocol.md` (source of truth is `osc/routes/` and `osc/encode.rs`; `DevicePath::to_osc_addr` path; polysynth params path), `engine-plugin-architecture.md`
  (`ipc/process/`, no in-process adapter), `engine-sfz-sampler.md` (paths) and ADR 0003 (the file list in Consequences). Every `.rs` path and directory written in
  those files was checked against the tree.
- Command classification: 108 `AudioCommand`s, 69 graph edit, 22 build/teardown, 5 query, 12 command thread only. The classes are judgements from reading the handlers;
  the note column marks the commands that still allocate or free under the state lock.
- Comments for #67 and #1 are drafts, not posted: `.scratch/issue-67-comment.md` and `.scratch/issue-1-comment.md` (git-excluded).
- Live checks, run by the user on 2026-10-09 (all passed):
  - [x] Phase 2: start the engine with `./run_release.sh`; `logs/last_info.log` and `last_warn.log` are written and `/project/init` rotates them into `session_<timestamp>_*.log`.
  - [x] Phase 9: run Godot against the engine (open a project, play, move a fader, add a device) and check `Engine/logs/last_warn.log` for new argument warnings. File any as issues, don't silence them.
  - [x] Phase 10: `SONARA_FEATURES=rt-debug ./run_release.sh` with clips through a CLAP plugin and a bus (only the known `poll_device_data` allocation may show), and compare the engine stats load average/peak with `master`.
  - Results: rotation into `session_*` files works on every `/project/init`. Godot session (devices, sends,
    volume) logged no argument warnings. rt-debug, 2 minutes of a track with Dragonfly Hall on a bus:
    0 allocations during playback; the only 22 were `poll_device_data` while a view subscribed at project
    load (known, #1). 0 xruns, lock misses and plugin dropouts; load avg 9.5–14.9%, peak 19.3–23.4%
    under rt-debug (no same-project `master` comparison was run).
  - Found along the way (pre-existing on `master`): #92 (Godot sends `/project/init` several times at
    startup) and #93 (rotations within the same second overwrite session logs).
- Not done on purpose: #67 is not closed, and nothing was pushed.
