# TODO

# Bugs / Issues
- [?] Moving a clip from one track to another causes playback of new clip to actually play on original track.
    ^ I think this is solved.
- [ ] NoteContainer seems to assign IDs to midi notes. This responsibilitty should be moved elsewhere (Clip probably?)

## Audio Engine (Rust Backend)

### Core Audio
- [ ] Keep audio engine running after playback so instruments (PolySynth) and reverb/delay effects can settle after stopping
- [ ] Solo causes a sharp click
- [x] RMS Metering
- [ ] Plugin latency compensation
- [ ] Improve logging of plugins
- [X] Performance profiling: emit engine load metrics via OSC for UI display
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

### Devices & Plugins
- [ ] DeviceInstance and their UIs should init with loading state and wait for Engine updates
- [ ] Multi-in and multi-out for devices
- [ ] Add support for enum parameter type for builtins
- [x] Refactor DevicePanel and DeviceView system
- [ ] Verify drag-to-reorder devices with builtin, CLAP and SFZ devices (engine + UI implemented)
- [ ] In Engine: Simplify device advertizementt to avoid creating temporary instances

### Plugins
- [ ] Crash / Error handling, send info to Godot for UI notifications
    - [x] Engine logs a warn and higher are sent over OSC
- [ ] Plugin GUI windows should be forced to stay above Godot App

### Built-in Devices
- [ ] Basic MVP Builins
    - [x] Remove old Oscilator
    - [x] PolySynth Device
    - [x] Spectrum Analyzer
        - [ ] Stereo Combined mode or layered L/R or M/S
    - [ ] Filter Device: Resonant Filter with LP/BP/HP modes
    - [ ] EQ: 10-band parametic equalizer with adjustable type, freq, gain and Q. Built-in spectrum analyzer
    - [ ] Stereo Delay with time (ms) OR tempo control, feedback amount and wet/dry mix %
    - [ ] Simple Reverb plugin freeverb style
    - [ ] Compressor

---

## Godot (UI/Frontend)

### Performance & Debugging
- [x] Show audio engine metrics dashboard

### Save/Load
- [x] Save and Load projects (frontend implementation)
- [ ] Welcome Screen with recent projects, templates and settings

### Export
- [ ] Export/rendering
    - [ ] bouncing tracks or clips to audio clip on a new track
    - [ ] bounce in-place a midi clip to audio clip, replacing midi clip with audio and auto-converting channel to hybrid track (midi+audio) ?
- [ ] Export MIDI
- [ ] Export menu with separate track (stem) selection

### Arranger & Timeline
- [ ] Arranger Timeline
    - [ ] Cut/Copy/Paste/Duplicate clips
    
- [ ] TimelineHeader
    - [x] TimelineHeader should be vertically resizable
    - [ ] Auxiliary Rulers/"Tracks" (real-time ruler, chord track, and marking tracks)
    - [ ] Ruler
        - [ ] Click-and-drag enters multidimension zoom mode (moving vertically zooms, horizontally scrolls), or simply emit a signal and let Arranger/Timeline handle it
- [ ] Arranger: Tracks
    - [x] TrackItem color should inherit from bound channel
    - [x] Reorderable tracks
    - [x] Folder tracks
    - [ ] Right-click popup menu with:
        - [ ] Rename track
        - [ ] Change track color
        - [ ] Duplicate track
- [ ] Duplicate Track
- [x] TimelineClip should inherit color of the track it's on?

### Clips
- [x] ClipInstances can be dragged to other tracks
- [x] ClipInstances can be resized
- [x] Implement ClipInstance offset property in ticks to allow resizing a clip instance from the left edge, skipping part of the clip's content.
- [x] Multi-select clips with Shift+click < change this to ctrl instead of shift
- [x] Single-click deselects other tracks
- [x] Click empty area deselects all
- [/] implement TimelineClip context menu, add to Timeline scene, TLC can emit request_show_context_menu, or Timeline can simply listen for gui input on clip? depends on current architecture.
    - [ ] SmartLineEdit for clip name
    - [x] Make Unique: makes clip unique (if ClipInstance shares underlyying clip with any other ClipInstance)
    - [ ] Select All Instances
    - [ ] Cut
    - [ ] Copy
    - [x] Delete
- [x] TimelineClip should include prefix or suffix in label if it's effectively unique.

### Clip Editor / Note Editor
- [x] NoteEditor bug: erase-mode is sometimes stuck on even after releasing right-mouse
    ^ Fixed by adding global _input() handler to catch right-mouse release even when consumed by child nodes
- [x] When editing a clip, closing the clip editor, deselecting the clip, reselecting it and opening the clip editor, current notes aren't visible
- [x] BUG: note mouse position is slightly wrong when placing/moving notes
- [X] right-clicking an empty area should deselect any selected notes (and emit that)
- [x] box-selecting notes should ensure the start/end time of the NoteSelection is at least as large as the start of first note and end of last note.
- [x] need a clipinstance-local playhead visual (vertcal line) to visualize durring playback
- [ ] Ctrl+click and drag ON a VisualNote should initiate "drag to duplicate anywhere", which will:
    1. create VisualNotes of the selection (or the clicked visual if empty) and add them but tag them as "pending"
    2. while "duplicate-dragging", continually move the duplicates relative to mouse note position
- [x] Visualize current NoteSelection start and end range
- [ ] Track vs clip context mode:
    - [ ] In clip mode: ruler is relative to ClipInstance, draw clip start and end in ruler
    - [ ] In track mode: show all clips as they appear in entire track, ruler relative to entire track
- [ ] Multi-clip and multi-track editing: selecting multiple clips renders all notes
- [x] Color VisualNote by track color
- [ ] Modifier+right-click to open context menu in NoteEditor

### Mixer
- [x] Connect TrackItem ui controls to target channel (fader, solo, mute)
- [ ] Delete, Duplicate Channels
- [ ] Smooth meter components (lerp?)

### UI Components & General
- [~] Settings Menu: Nestable categories on the left as a tree, avaialble settings on the right.
    - Categories: Audio, Behavior, Appearence, Shortcuts
    - In progress: Settings.gd registry + SettingsDialog popup + SettingRow editor component
- [ ] **CRITICAL**: Undo/Redo using command pattern

### Hardware & MIDI
- [x] Implement MIDI support
- [x] Live MIDI input for armed tracks outputs to target track
- [x] Computer keyboard as a virtual midi device (note keys, transpose, velocity) in `MidiManager`
    - [ ] Caps lock toggles it on/off (currently always on via `midi/virtual_keyboard/enabled` config)
- [ ] Modulation
    - [ ] Basic modulation, similar to bitwig, allow any channel and device parameter to be modulatable
