# 028 — VST3 hosting: implementation plan

Host VST3 plugins next to CLAP. Each one runs out of process in `plugin_host`, behind the same IPC
protocol, shared-memory audio path, crash recovery and GUI embedding that CLAP uses. VST2 is out
of scope for good. Its SDK is withdrawn and can't be licensed.

This is a lightweight plan, not a full Kiro spec. Work phase by phase. Each phase ends with
something that builds, passes tests and can be checked by hand. Commit at the end of each phase.

## Ground rules

- **Don't change CLAP behaviour.** VST3 is a parallel path. Don't refactor the clack code into a
  shared trait. Keep the two formats apart with a `match` on the format at a few points instead
  (see Phase 2). If you find yourself editing CLAP logic and not just dispatching around it, stop
  and ask.
- Follow the audio thread contract in `AGENTS.md` and ADR 0002. On the host's audio thread,
  preallocate every VST3 event list, parameter queue and `AudioBusBuffers` at activation, and
  never allocate in `process`.
- Every call into the VST3 controller (`IEditController`, `IPlugView`) must happen on the
  `plugin_host` main thread, which is the event loop thread. Calls into the processor
  (`IAudioProcessor::process`) happen only on the host's audio thread. This matches how the CLAP
  side already splits instance and processor.
- Use the `vst3` crate (coupler-rs, MIT/Apache). Its bindings are generated from the official SDK,
  which has been MIT licensed since 3.8. Check its current API on docs.rs before writing code
  (`ComPtr`, `ComWrapper`, the `Class` trait for implementing host interfaces). Use `libloading`
  to open the module.
- Engine commands: `cargo build --release`, `cargo test`, `cargo fmt` (from `Engine/`).
  Godot tests: `Godot/tests/run_all.sh`.
- Don't run more than 2–3 cargo builds in parallel.

## Reference: where the CLAP path lives

| Concern | File |
|---|---|
| IPC commands and responses (format-neutral) | `Engine/src/audio/ipc/protocol.rs` (`PluginCommand`, `PluginResponse`, `PluginEvent`, `BlockEvent`, `EVENT_*`) |
| Discovery (in-process, via clack) | `Engine/src/audio/devices/clap_host/discovery.rs` (`PluginScanner`, `PluginDescriptor`) |
| Scan command and `/plugin/info` encoding | `Engine/src/audio/command_worker/plugins.rs`, `Engine/src/osc/encode.rs` |
| Device creation by type string | `Engine/src/audio/devices/factory.rs` (`create`, `create_clap`), `Engine/src/audio/command_worker/devices.rs` (vendor lookup) |
| Engine-side adapter | `Engine/src/audio/devices/clap_host/subprocess_adapter/` |
| Host process main loop | `Engine/src/plugin_host/event_loop.rs` (`run_plugin_host`, `service_plugin_side`) |
| Command handling | `Engine/src/plugin_host/commands.rs` (`process_command`), `operations.rs` |
| Per-instance main-thread state, param map | `Engine/src/plugin_host/state.rs` (`PluginState`, `ParamMap`) |
| Host callbacks, timers, rescan flags | `Engine/src/plugin_host/host.rs` |
| Host audio thread | `Engine/src/plugin_host/audio_thread.rs` (`HostAudioCommand`, `InstanceSlot`, `process_request`) |
| Standalone debug probe | `Engine/src/plugin_host/probe.rs` |
| Godot plugin registry and cache | `Godot/data/DeviceRegistry.gd`, `Godot/data/Device.gd` (`DeviceType`) |
| Godot type string for `add_device` | `Godot/data/Channel.gd` `_get_device_type_string` |
| GUI embedding decision | `docs/adr/0016-plugin-guis-embed-via-x11-reparenting.md` |

Read ADR 0001 (out-of-process plugins), ADR 0009 (crash recovery and hosting modes), ADR 0016 and
`docs/subsystems/engine-plugin-architecture.md` before starting.

## Decisions

- **Identity.** A VST3 plugin's id is its processor class ID (the 16-byte `TUID`), written as
  32 uppercase hex characters. Its file is the path to the `.vst3` bundle directory. The type
  string is `"vst3"`. `/channel/{id}/add_device` already documents `"vst3"` as a type.
- **Bundles only.** The binary is `<bundle>/Contents/<arch>-linux/<Name>.so`, where `<arch>` is
  `x86_64` or `aarch64` for the build target. Legacy single-file `.so` VST3s are not supported.
- **Scan paths.** The defaults are `~/.vst3`, `/usr/lib/vst3` and `/usr/local/lib/vst3`, plus the
  `VST3_PATH` environment variable (`:`-separated), deduplicated the way `resolve_scan_paths`
  does it for CLAP. The paths configured in Godot stay CLAP-only for now.
- **Scanning never loads a plugin into the engine process.** If the bundle has
  `Contents/Resources/moduleinfo.json`, read it. Otherwise run `plugin_host --scan-vst3 <bundle>`,
  which loads the module in a throwaway process and prints the classes as JSON on stdout. Use a
  timeout (10 s) and skip the bundle on a crash or timeout. A crashing plugin must not take the
  engine down during a scan.
- **State blob.** VST3 has two state streams, one for the component and one for the controller.
  Pack them into the existing single `Vec<u8>` as
  `b"SVST3\0\0\x01"` + `u32 LE len` + component bytes + `u32 LE len` + controller bytes. On load,
  call `component.setState` first, then `controller.setComponentState` with the component bytes,
  then `controller.setState` with the controller bytes.
- **Parameters.** The engine parameter id is the index from `getParameterInfo`, as it is for CLAP.
  `ParamMap` gets a VST3 variant that maps index to `ParamID`. Values are already normalized
  (0–1 doubles), so no min/max mapping is needed.

## Out of scope for v1

Each of these is listed so nobody implements a half version.

- Modulation (`EVENT_PARAM_MOD`). VST3 has no non-destructive modulation. The audio thread drops
  these events for VST3 instances and logs once per instance. Godot should not offer VST3
  parameters as modulation targets. If that's easy, hide them; otherwise record it in the follow-up
  issue.
- Note choke (`EVENT_NOTE_CHOKE`). Ignore it.
- MIDI CC, pitch bend and `IMidiMapping`. The IPC block carries no CC events for CLAP either.
- Aux and sidechain buses, and multi-out. Activate only the main audio input and output and the
  first event input.
- Note expression, unit and program lists, `IContextMenu`.
- A floating GUI mode. VST3 always needs a parent window. If `OpenGui` has no `window_handle`,
  answer `GuiError`.
- DAWproject import and export. This is Phase 7, optional.

---

## Phase 1 — Dependency, module loading and `--probe`

**Goal:** `plugin_host --probe ~/.vst3/Surge\ XT.vst3` loads a VST3 plugin, prints its classes,
buses and parameters, processes audio with a note, and reports the output levels.

1. Add `vst3` (and `libloading` if it's not already a direct dependency) to `Engine/Cargo.toml`.
2. Create `Engine/src/plugin_host/vst3/` with:
   - `module.rs`: `Vst3Module`. Resolve the `.so` path in the bundle, `dlopen` it, call
     `ModuleEntry(handle)`, then `GetPluginFactory`, and call `ModuleExit` before unloading in
     `Drop`. Keep the module alive for as long as any instance from it is alive.
   - `host_context.rs`: host-side COM objects, using `ComWrapper`. Start with `IHostApplication`
     (`getName` returns "Sonara"; `createInstance` supports `IMessage`/`IAttributeList` if the
     crate makes that easy, otherwise returns `kNotImplemented`).
   - `stream.rs`: a `MemoryStream` implementing `IBStream` over `Vec<u8>`, with unit tests for
     read, write, seek and tell.
   - `instance.rs`: `Vst3Instance`. Create the component from the class ID, `initialize`, then get
     the controller. Either the component also implements `IEditController` (query it), or
     `getControllerClassId` names a separate class that you create and `initialize`. Connect the
     component and controller through `IConnectionPoint` when both have it. Set up buses with
     `setBusArrangements` (stereo in and out; instruments have 0 audio inputs) and `activateBus`
     for main audio and event input 0. Then `setupProcessing` (`kRealtime`, `kSample32`, sample
     rate, max block size), `setActive(true)` and `setProcessing(true)`. Teardown runs in reverse
     order: disconnect, `terminate` the controller and then the component.
3. Extend `probe.rs`. When the path ends in `.vst3`, take a VST3 branch with the same output shape
   as the CLAP one (descriptor, buses, parameters, latency, 1 s of silence, then a note C3 held
   0.5 s, per-block timing and levels). A note-on is `Event { type: kNoteOnEvent, sampleOffset,
   noteOn { channel 0, pitch, velocity, noteId: -1 } }` in an `IEventList` you implement
   (`event_list.rs`, a fixed-capacity, preallocated list).
4. Add `--scan-vst3 <bundle>`. It prints one JSON object per audio-module class: class ID, name,
   vendor, version, subcategories string and category. Parse the same fields from
   `moduleinfo.json`.

**Check:** `cargo test` passes. The probe on Surge XT VST3 and on one effect (for example a
Dragonfly or LSP VST3) prints non-silent output for the instrument and passes audio through the
effect. Ask the user to run the probe if no VST3 plugins are installed.

## Phase 2 — Running VST3 instances in `plugin_host`

**Goal:** the engine can load a VST3 plugin onto a channel, play it, set parameters, and save and
restore its state, with no GUI yet.

1. **Protocol.** Add `format: PluginFormat` (`Clap | Vst3`, with serde default `Clap`) to
   `PluginCommand::Initialize`. Define `PluginFormat` in `audio/ipc/protocol.rs` and reuse it on
   the engine side.
2. **Event loop.** Change `instances: HashMap<InstanceId, PluginState>` in `run_plugin_host` to
   `HashMap<InstanceId, HostedInstance>`, where `enum HostedInstance { Clap(PluginState),
   Vst3(Vst3State) }`. The per-instance service step and `handle_incoming` match on the variant.
   The CLAP arm calls exactly the code it calls today.
3. **Commands.** Add `plugin_host/vst3/commands.rs` with a `process_vst3_command` that answers
   every `PluginCommand` with the same `PluginResponse` variants the CLAP path uses:
   - `Initialize`: load the module (cache `Vst3Module` by bundle path per host process, since
     hosting modes put several instances in one process), create the instance, map the shared
     memory exactly as the CLAP path does, and reply `InitializeSuccess` with the same fields.
   - `Activate` / `Deactivate` / `StartProcessing` / `StopProcessing`: `setupProcessing`,
     `setActive` and `setProcessing`, plus handing the processor to the audio thread and taking it
     back (step 4). Report latency from `IAudioProcessor::getLatencySamples`.
   - `GetParameterInfo` / `GetParameter` / `SetParameter`: use the controller (`getParameterCount`,
     `getParameterInfo`, `getParamNormalized`, `setParamNormalized`, and `getParamStringByValue`
     for value text; mirror `value_text.rs`). Map the `ParameterInfo` flags onto
     `PluginParameterInfo` the way the CLAP path maps `ParamInfoFlags` (read-only, hidden, stepped
     from `stepCount > 0`, automatable). `SetParameter` also goes to the audio thread as a
     parameter change at offset 0.
   - `SaveState` / `LoadState`: use the blob format from Decisions. Unit-test pack and unpack,
     including truncated and foreign blobs, which must be errors and never panics.
   - `Reset`: `setActive(false)` then `setActive(true)` (with processing stopped around it).
   - `SetRenderMode`: store it. It applies at the next `setupProcessing`
     (`kOffline`/`kRealtime`). Reply `RenderModeSet { applied }` accordingly.
   - `Unload`: as for CLAP, close the GUI, deactivate and drop.
4. **Audio thread.** Make the processor in `HostAudioCommand::SetProcessor`/`TakeProcessor` and
   `InstanceSlot` an enum with a `Vst3(Vst3Processor)` variant. `Vst3Processor` owns the
   `IAudioProcessor` pointer, the preallocated input `IEventList`, an `IParameterChanges` input and
   output (preallocated queues, one per parameter that changes in a block, with a fixed capacity),
   the `AudioBusBuffers` and the `ProcessContext`. In `process_request`, for a VST3 slot:
   - `EVENT_NOTE_ON` / `EVENT_NOTE_OFF` become `kNoteOnEvent`/`kNoteOffEvent` with
     `sampleOffset = BlockEvent::sample_offset`.
   - `EVENT_PARAM` becomes a point in that parameter's queue at `sample_offset`.
   - `EVENT_PARAM_MOD` and `EVENT_NOTE_CHOKE` are dropped (Out of scope).
   - Fill `ProcessContext` from `BlockTransport` (tempo, time signature, project time in samples
     and quarter notes, playing flag), mirroring `fill_transport_event`.
   - After `process`, read `outputParameterChanges` (the last point of each queue) and send them
     to the main thread the same way the CLAP path reports processor-side parameter changes. The
     main thread then calls `controller.setParamNormalized` and emits `ParameterValueChanged`.

   Add unit tests for the event translation that don't need a real plugin: translate a
   `BlockEvent` slice into the event list and parameter queues and assert the contents.
5. **Host callbacks.** Implement `IComponentHandler` (`beginEdit`/`performEdit`/`endEdit`/
   `restartComponent`) in `host_context.rs`, on a shared state struct like
   `SubprocessHostShared`:
   - `performEdit(id, value)` queues the change for the audio thread and sends
     `ParameterValueChanged` (engine index, value). Also mark the state dirty (`StateDirty`).
   - `restartComponent` flags: `kParamValuesChanged` sets the "values rescanned" flag,
     `kParamTitlesChanged`/`kReloadComponent` set "params rescanned", and `kLatencyChanged` asks
     for re-activation the way CLAP's `request_restart` does. The event loop already polls flags
     like these; reuse that pattern.
6. **Engine side.**
   - `factory.rs`: `"vst3"` creates the same `SubprocessClapAdapter` with
     `format: PluginFormat::Vst3`, threaded through to `Initialize`. Don't rename the adapter in
     this phase; a rename can be a separate commit at the end.
   - `command_worker/devices.rs`: look up the vendor for `"vst3"` too, so "By vendor" hosting
     works.
   - Discovery: add `format` to `PluginDescriptor`. Add `vst3_discovery.rs` next to
     `discovery.rs`, which finds `.vst3` bundles, reads `moduleinfo.json` or runs
     `plugin_host --scan-vst3`, and produces `PluginDescriptor`s. Get the category from the
     subcategories (`Instrument`/`Synth`/`Drum` mean Instrument, everything else Effect). Put the
     subcategories in `features`, lowercased and split on `|`. `PluginScanner::scan` runs both.
     Unit-test bundle path resolution, `moduleinfo.json` parsing and category inference.
   - `osc/encode.rs`: append arg 8, the format (`"clap"`/`"vst3"`), to `/plugin/info`. Update
     `docs/subsystems/osc-protocol.md` (the `/plugin/info` table and the heading "CLAP Plugins",
     which becomes "Plugins").

**Check:** `cargo test` passes. With an OSC smoke test (`oscsend`), add a VST3 instrument to a
channel by class ID and bundle path, play notes, change a parameter, save the state, reload the
plugin and get the same sound. Ask the user to listen.

## Phase 3 — Godot

1. `Godot/data/Device.gd`: append `VST3` to `enum DeviceType` (append it, so the existing ints
   don't change). Add `func is_plugin() -> bool` (CLAP or VST3), and use it in `has_gui()` and
   wherever `== Device.DeviceType.CLAP` means "is a plugin" (`DeviceContextMenu.gd`,
   `DevicePreset.gd`, `DeviceRegistry.gd`; grep for `DeviceType.CLAP` and check each use).
   `get_device_type_string()` returns "VST3".
2. `Godot/data/Channel.gd` `_get_device_type_string`: `VST3` maps to `"vst3"`.
3. `Godot/data/DeviceRegistry.gd` `_on_plugin_info_received`: read arg 8 (default `"clap"`) and set
   the `DeviceType` from it. The default description becomes "VST3 Plugin" or "CLAP Plugin". The
   cache already stores the type by key name; check that a cache written before this change still
   loads.
4. Find how a project saves a device's type and plugin path (grep `DeviceInstance.gd` and the
   project serializer) and check that VST3 devices round-trip through save and load.
5. **Browser: tell the formats apart when a plugin is installed in more than one.** Do this
   before any live testing in the app. Many Linux plugins (Surge XT, LSP, Dragonfly, most JUCE
   plugins) ship CLAP and VST3 side by side, so both copies show up in a single scan.
   - **Fix the overwrite first.** `Browser.gd` `_build_device_hierarchy_tree` keys leaves by
     `hierarchy[category][vendor][device_name]`, so the second plugin with the same name and vendor
     silently replaces the first. Key leaves by `asset.path` (the device id, which differs between
     formats) and keep the name only as the display text.
   - **Matching.** Two devices are "the same plugin" when they have the same category and the same
     normalized vendor and name (lowercase, with whitespace and punctuation removed, so
     "Surge Synth Team" and "surge synth team" match). Compute this once in `DeviceRegistry` after
     a scan or cache load (for example `Device.format_siblings` or a helper
     `DeviceRegistry.has_other_format(device) -> bool`), not per tree rebuild.
   - **Display.** When a device has a sibling in another format, show the format after the name in
     the browser tree and in search results: a dim "CLAP"/"VST3" tag in the same row (for example
     `Surge XT  VST3`, with the tag in `text_dim`). Plugins that exist in only one format show no
     tag, so the common case stays clean. Sort the siblings next to each other, CLAP first.
   - **Hover and drag.** The tooltip or info panel for any plugin always states its format and its
     bundle path. Dragging either entry adds exactly that format (the drag data already carries the
     device id).
   - **Search.** `AssetSearch.gd` should match "vst3" and "clap" against the format, so typing
     "surge vst3" finds the VST3 one.
   - **Device header.** Where the device frame or the device lane shows a plugin's name, add the
     format to the tooltip so the user can see which copy is loaded. Don't add a visible tag there.
   - Follow `docs/subsystems/godot-ui-components.md` for the tag styling.
   - No "preferred format" setting or hiding of duplicates in v1. Both stay visible.
6. Modulation: hide VST3 parameters as modulation targets if that's simple (see Out of scope).
7. Tests: extend or add `Godot/tests/test_*.gd` for `/plugin/info` parsing with and without
   arg 8, cache round-trip of a VST3 device, the `add_device` type string, and the browser: two
   devices with the same name and vendor in different formats both appear in the tree with format
   tags, and a plugin in one format has no tag.

**Check:** `Godot/tests/run_all.sh` passes. The user scans, finds VST3 plugins in the browser
(a plugin installed in both formats shows twice, tagged CLAP and VST3),
drags one onto a track, plays it, saves the project, reopens it and hears the same sound.

## Phase 4 — GUI

**Goal:** VST3 GUIs open embedded or in the engine's host window, resize correctly and repaint.
JUCE plugins included.

1. `plugin_host/vst3/gui.rs`: `OpenGui { window_handle: Some(xid) }` calls
   `controller.createView("editor")`, checks `isPlatformTypeSupported("X11EmbedWindowID")`, calls
   `setFrame(plug_frame)` **before** `attached(xid, "X11EmbedWindowID")`, then `getSize`, and
   replies `GuiOpened` with `floating: false`. `CloseGui` calls `removed()` then `setFrame(null)`
   and releases the view. `SetGuiVisible` has no VST3 equivalent: reply with the current size and
   leave it to the engine's window handling. `SetGuiSize` calls `canResize`, then
   `checkSizeConstraint`, then `onSize`, and replies `GuiSize`. `HasGui` creates the view to check
   that it isn't null and releases it again.
2. `IPlugFrame::resizeView(view, rect)` sends `PluginEvent::GuiResizeRequest` (as the CLAP
   `request_resize` does), and then calls `view.onSize(rect)`.
3. **`Linux::IRunLoop` is required.** JUCE plugins query it *from the `IPlugFrame` object*, so the
   same COM object must implement both `IPlugFrame` and `IRunLoop`. Without it, JUCE GUIs never
   repaint.
   - `registerTimer(handler, ms)` / `unregisterTimer` reuse the timer bookkeeping pattern in
     `host.rs` (`tick_timers`).
   - `registerEventHandler(handler, fd)` / `unregisterEventHandler` keep a list of `(fd, handler)`
     pairs.
   - In the event loop's per-instance service step, `poll()` the registered fds with a 0 timeout
     and call `onFDIsSet(fd)` for the readable ones, then fire due timers with `onTimer()`. The
     loop already wakes at least every 1 ms, which is fast enough.
   - Handlers may unregister themselves during a callback. Iterate over a copy of the list.
4. The engine-side GUI flow (`subprocess_adapter/gui.rs`, ADR 0016 reparenting) should work
   unchanged, because the plugin's parent stays the engine's host window. Check that the engine
   always passes a `window_handle` for VST3. If there's a path that asks for a floating CLAP GUI
   with `None`, give VST3 a host window there instead, or fail clearly.

**Check:** the user opens the GUIs of Surge XT (VST3), a JUCE plugin and, if installed, a
yabridge-wrapped Windows plugin. Each opens embedded and floating, resizes, repaints while
playing, and has knob moves show up in Sonara's parameter list. Ask the user to do this. It can't
be tested headless.

## Phase 5 — Crash recovery and hosting modes

1. Check that a crashing VST3 plugin goes to `Crashed` and passes audio through, and that a reload
   restores its last saved state (ADR 0009). This should come for free; verify it and fix any gaps.
2. Check all three hosting modes with two VST3 instances from the same bundle, plus a mixed host
   process holding one CLAP and one VST3 instance ("By vendor" with a vendor that ships both).

## Phase 6 — Docs

1. Write `docs/adr/0019-vst3-hosting.md`. Cover: the parallel `HostedInstance` path instead of a
   shared trait; scanning out of process or through `moduleinfo.json`; the state blob format; the
   v1 omissions (modulation, choke, CC); and that `IRunLoop` is implemented on the plug frame.
2. Update `docs/subsystems/engine-plugin-architecture.md`, the `AGENTS.md` "CLAP plugins" section
   (rename it "Plugins (CLAP, VST3)" and add the `plugin_host/vst3/` module), and `CONTEXT.md` if
   it defines plugin terms.
3. Open a GitHub follow-up issue (labels `engine`, `device`) for the Out-of-scope items.

## Phase 7 (optional) — DAWproject

`DawProjectImporter.gd` currently reports VST3 devices as unloadable (`FORMAT_DEVICES`,
`TransferReport.PLUGIN_FORMAT`). Map a `Vst3Plugin` element's `deviceID` to an installed VST3 by
class ID and load it, with its state from the referenced `.vstpreset` file (component state
chunk). On export, write VST3 devices as `Vst3Plugin`. Read `docs/subsystems/dawproject.md` first.
Do this only if the user asks for it.

## Risks to watch

- **Component and controller in one object versus separate objects.** Handle both, and don't
  `terminate` the same object twice.
- **Threading.** Some plugins assert when the controller is called off the thread that created
  it. All controller calls belong on the main thread.
- **A missing `ModuleEntry`/`ModuleExit` pairing** causes crashes at unload with JUCE plugins.
- **`IRunLoop`.** If a GUI opens black or frozen, check the run loop first.
- **Scan time.** Running a `plugin_host` per bundle is slow on big libraries. Cache the scan results
  by bundle mtime if it becomes a problem. Don't build that up front.
