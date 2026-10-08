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
- [ ] Phase 3: Split `audio/types.rs`
- [ ] Phase 4: Split `audio/commands.rs`; `EngineState` gets its own module
- [ ] Phase 5: Command effects: statuses and drops after the lock is released (prep for #1)
- [ ] Phase 6: Device lookup helpers
- [ ] Phase 7: Split `audio/command_worker.rs`
- [ ] Phase 8: Split `osc/server.rs`
- [ ] Phase 9: OSC argument reader
- [ ] Phase 10: Split `audio/processing.rs` and `audio/mixing.rs`
- [ ] Phase 11: Group `audio/devices/`
- [ ] Phase 12: Split `audio/ipc/process_manager.rs` and `audio/devices/sampler.rs`
- [ ] Phase 13: Docs, command classification for #1, close-out

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

Goal: no production file over ~800 lines outside `devices/` DSP code, and no function over ~150
lines except the two dispatch matches (`commands/mod.rs`, `command_worker/mod.rs`) and
`encode_status`.

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
