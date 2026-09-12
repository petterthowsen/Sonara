# TODO

# Bugs / Issues

- [?] Moving a clip from one track to another causes playback of new clip to actually play on original track.
  ^ I think this is solved.

- [ ] NoteContainer seems to assign IDs to midi notes. This responsibilitty should be moved elsewhere (Clip probably?)

## Audio Engine (Rust Backend)

### Core Audio

- [x] Keep audio engine running after playback so instruments (PolySynth) and reverb/delay effects can settle after stopping
- [x] Solo causes a sharp click
- [x] RMS Metering
- [ ] Plugin latency compensation
- [ ] Improve logging of plugins
- [x] Performance profiling: emit engine load metrics via OSC for UI display
- [ ] CPU affinity for audio thread and plugin processing
- [ ] Realtime thread priority configuration
- [ ] CPU core assignment for plugin processing
- [ ] Remove the shared `Arc<Mutex<EngineState>>` (phase 2): the audio thread should own its state and drain a lock-free command queue, with removed objects sent back to be dropped off-thread
  - [ ] Phase 1, partly verified live (CLAP on a bus, large clip import during playback): slow commands (plugin scan, device create/drop, plugin GUI/activation IPC) run outside the lock in `CommandWorker`; the callback uses a bounded `try_lock` and outputs silence
- [ ] Audio thread allocations still left: unbounded status channel sends, `process_device_chain` sleep-change Vec, `audio_playback_positions` insert (String clone) on clip start, `poll_parameter_changes` sets a socket read timeout every buffer per CLAP plugin
  - [ ] Removed, needs live verification: per-buffer Vecs/HashMaps and buffer clones in `process_audio`/`mix_and_output`, debug `info!` logging in the callback
- [x] Mixing: reverb/delay tails on a routed bus cut off when playback pauses (verified live after the fix below)
- [x] Mixing: a bus or master that receives audio in more than one routing pass runs its devices and pan more than once per buffer (verified live with nested buses)
  - Fix: routing and sends run in dependency order (`pending_inputs` in `MixBuffers`). Each channel finishes once, after all its inputs; route targets run devices even with no input, then pan, then route onward.
- [ ] Mixing: pre-fader send audio is copied before the device pre-pass, so pre-fader sends from instrument channels are silent
- [ ] Read MIDI input directly in the engine instead of through Godot (Godot adds up to a frame of jitter)
- [ ] Make sample rate and buffer size configurable (currently constants in `engine.rs`)
- [x] Solo behavior: Bus channels should still sound when instrument/audio channels are soloed
- [x] Solo behavior: Bus solo is a group solo (route feeders stay fully audible; send-only feeders keep the send and mute dry)
  - Engine implemented; needs live verification
- [x] Mixer channel sends do not sync bus names until send knob is touched

### Devices & Plugins

- [ ] DeviceInstance and their UIs should init with loading state and wait for Engine updates
- [ ] Multi-in and multi-out for devices
- [ ] Add support for enum parameter type for builtins
- [ ] Verify drag-to-reorder devices with builtin, CLAP and SFZ devices (engine + UI implemented)
- [ ] In Engine: Simplify device advertisement to avoid creating temporary instances



### Plugins

- [ ] Crash / Error handling, send info to Godot for UI notifications
  - [x] Engine logs a warn and higher are sent over OSC
- [ ] Plugin GUI windows should be forced to stay above Godot App



### Built-in Devices

- [x] PolySynth Device
    - [ ] 
- [x] Spectrum Analyzer
- [x] Chain container (serial children + volume)
- [x] Layer container (parallel mix, per-slot mute/solo)
- [ ] L/R and M/S modes
- [x] Sampler and Drum Machine devices
- [ ] Reverb
- [ ] EQ: Parametric, built-in spectrum
- [ ] Limiter
- [ ] Compressor
- [ ] Saturator


---



## Godot (UI/Frontend)

- [x] Track and Channel color should be stored as-is. Only clamp color components When rendering/drawing.
- [x] For text/labels on any elements with a track/channel-colored background, use Dynamic black or white text depending on track color (luminance/lightness check?)
- [x] Changing track color of folder/group tracks in trackitem should sync to mixer view's bus channel and vice-versa.
- [ ] soloing a channel from mixer should sync to the linked track

- [ ] BUG: inline edit of channel names often has unreadable text color

### Save/Load

- [ ] Welcome Screen with recent projects, templates
- [x] bug: device CC values do not persist
- [x] bug: tracks in a folder initialize in the wrong correct position in the arranger



### Export

- [ ] Export/rendering
  - [ ] bouncing tracks or clips to audio clip on a new track
  - [ ] bounce in-place a midi clip to audio clip, replacing midi clip with audio and auto-converting channel to hybrid track (midi+audio) ?
- [ ] Export MIDI
- [ ] Export menu with separate track (stem) selection



### Arranger & Timeline

- Arranger Timeline
- TimelineHeader
  - Ruler
    - [ ] Auxiliary Rulers/"Tracks" (real-time ruler, chord track, and marking tracks)
- [ ] Arranger: Tracks
  - Trackitem context menu
    - [x] Change track color
    - [ ] Duplicate track
- [ ] Duplicate Track

### Clips

- [/] implement TimelineClip context menu, add to Timeline scene, TLC can emit request_show_context_menu, or Timeline can simply listen for gui input on clip? depends on current architecture.
  - [ ] SmartLineEdit for clip name
  - [x] Make Unique: makes clip unique (if ClipInstance shares underlyying clip with any other ClipInstance)
  - [ ] Select All Instances
  - [ ] Cut
  - [ ] Copy
  - [x] Delete

- [x] TimelineClip should include prefix or suffix in label if it's effectively unique.


### Clip Editor / Note Editor


- [ ] In track mode, notes from all clips should be visible 

- [ ] Ctrl+click and drag ON a VisualNote should initiate "drag to duplicate anywhere", which will:
  1. create VisualNotes of the selection (or the clicked visual if empty) and add them but tag them as "pending"
  2. while "duplicate-dragging", continually move the duplicates relative to mouse note position
- [ ] Track vs clip context mode:
  - [ ] In clip mode: ruler is relative to ClipInstance, draw clip start and end in ruler
  - [ ] In track mode: show all clips as they appear in entire track, ruler relative to entire track
  - [ ] In track mode, the track list should be ordered the same as the timeline
  - [ ] In track mode, draw a track-colored overlay on the ruler for clip start/end. Unfocused clips as gray/white below; clips of the active/focused tracks above
- [ ] Modifier+right-click to open context menu in NoteEditor


### Mixer

- [ ] Delete, Duplicate Channels
- [ ] Smooth meter components (lerp?)
- [ ] Sync selection of tracks and linked channels bidirectionally
  - [ ] Might make this behavior adjustable in settings
- [X] Improve channel drag-to-reorder UX
  - [X] Bug: sometimes the channel can only be dragged one step at a time


### UI Components & General


### Devices

- [ ] SamplerDefaultView, DrumMachineDefaultView etc should have their static layout in the scene rather than generated in code.


### Hardware & MIDI

- [ ] Modulation
  - [ ] Basic modulation, similar to bitwig, allow any channel and device parameter to be modulatable


### Quality of Life / Polish

- [ ] Asset Browser: Persist tree/list mode state and collapsed/uncollapsed folders.
- [ ] Assets: when discovering assets, generate a "essential name" for an asset, "Cello-Sec-PERF" becomes "Cello"