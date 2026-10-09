# 0019 — VST3 hosting is a parallel path next to CLAP

Status: accepted (spec 028, `docs/specs/028-vst3-hosting/plan.md`).

## Context

Many Linux plugins (Surge XT, LSP, Dragonfly, most JUCE plugins) ship as VST3 as well as CLAP.
Sonara already runs CLAP plugins out of process in `plugin_host` (ADR 0001) with shared-memory
audio, crash recovery (ADR 0009) and embedded GUIs (ADR 0016). VST2 is out of scope for good: its
SDK is withdrawn and can't be licensed.

## Decision

- **A parallel path, not a shared trait.** `plugin_host` holds `HashMap<InstanceId, HostedInstance>`
  with `enum HostedInstance { Clap(PluginState), Vst3(Vst3State) }`. The event loop matches on the
  variant at a few dispatch points (commands, service step, audio-thread slot). The CLAP code is
  unchanged. VST3 lives in `plugin_host/vst3/` on the `vst3` crate (coupler-rs, bindings from the
  MIT-licensed SDK). The IPC protocol, `PluginResponse` variants, shared memory, hosting modes and
  crash handling are format-neutral; `PluginCommand::Initialize` carries a `PluginFormat`.
- **Identity.** A plugin's id is its processor class ID as 32 uppercase hex characters, its path
  the `.vst3` bundle directory, and its device type string `"vst3"`. Only bundles are supported.
- **Scanning never loads a plugin into the engine.** Discovery reads
  `Contents/Resources/moduleinfo.json` if present, otherwise runs `plugin_host --scan-vst3
  <bundle>` in a throwaway process with a 10 s timeout. A crashing plugin skips its bundle.
  Search paths are configurable (`assets/vst3/paths`, sent after a `--vst3` marker in
  `/plugin/scan`), plus `VST3_PATH`.
- **State blob.** The single state `Vec<u8>` is `b"SVST3\0\0\x01"` + `u32 LE len` + component
  state + `u32 LE len` + controller state. Loading calls `component.setState`, then
  `controller.setComponentState`, then `controller.setState`. Foreign or truncated blobs are
  refused, never a panic.
- **Threads.** All controller and view calls run on the host's main thread; `process` only on the
  host audio thread, with event lists, parameter queues and buffers preallocated at activation.
- **GUI.** The editor view attaches to the engine's host window as `X11EmbedWindowID`, so the
  ADR 0016 embedding works unchanged. VST3 has no floating mode: an open without a parent window
  is an error. The `IPlugFrame` handed to the view is one COM object that also implements
  `Linux::IRunLoop`, because JUCE plugins query the run loop from the frame; without it their GUIs
  never repaint. The event loop services the registered timers and file descriptors each pass.
- **Godot.** `Device.DeviceType.VST3` is appended to the enum; `/plugin/info` arg 8 carries the
  format. A plugin installed in both formats shows twice in the browser with a dim format tag.
  Both stay visible: there is no preferred-format setting in v1.

## Left out of v1

Parameter modulation (VST3 has no non-destructive modulation, so `EVENT_PARAM_MOD` is dropped and
VST3 parameters are not modulation targets), note choke, MIDI CC / pitch bend / `IMidiMapping`,
aux and sidechain buses and multi-out, note expression, units and program lists, `IContextMenu`,
a floating GUI, and DAWproject import and export.

## Consequences

Two code paths to keep in step when the IPC protocol changes. In return the CLAP behaviour is
untouched, and a VST3-specific fault can't regress CLAP.
