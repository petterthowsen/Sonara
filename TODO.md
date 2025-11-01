# TODO

# Bugs / Issues
- [?] Moving a clip from one track to another causes playback of new clip to actually play on original track.
    ^ I think this is solved.
- [ ] Soloing a channel causes the signal to get louder (skipping fader when soloed?)
- [ ] Timeline Clips
    - [x] on project load/open, all TimelineClip nodes are all visually at tick 0 and have no name
- [ ] NoteContainer seems to assign IDs to midi notes. This responsibilitty should be moved elsewhere (Clip probably?)

## Audio Engine (Rust Backend)

### Debugging
- [x] Improve logging: split info/warn levels into separate files. Only keep last N session files. Name them last_info.txt, last_warn.txt and last_combined.txt

### Core Audio
- [ ] Keep audio engine running after playback so instruments (PolySynth) and reverb/delay effects can settle after stopping
- [x] RMS Metering
- [ ] Plugin latency compensation
- [ ] Improve logging of plugins
- [X] Performance profiling: emit engine load metrics via OSC for UI display
- [ ] CPU affinity for audio thread and plugin processing
- [ ] Realtime thread priority configuration
- [ ] CPU core assignment for plugin processing

### Devices & Plugins
- [ ] DeviceInstance and their UIs should init with loading state and wait for Engine updates
- [ ] Multi-in and multi-out for devices
- [ ] Add support for enum parameter type for builtins
- [x] Refactor DevicePanel and DeviceView system

### Plugins
- [ ] Crash / Error handling, send info to Godot for UI notifications
    - [x] Engine logs a warn and higher are sent over OSC
- [ ] Plugin GUI windows should be forced to stay above Godot App

### Built-in Devices
- [ ] Basic MVP Builins
    - [ ] Remove old Oscilator and Delay
    - [x] PolySynth Device
    - [x] Spectrum Analyzer
        - [ ] Stereo Combined mode or layered L/R or M/S
    - [ ] Filter Device: Resonant Filter with LP/BP/HP modes
    - [ ] EQ: 10-band parametic equalizer with adjustable type, freq, gain and Q. Built-in spectrum analyzer
    - [ ] Stereo Delay with time (ms) OR tempo control, feedback amount and wet/dry mix %
    - [ ] Simple Reverb plugin freeverb style
    - [ ] Compressor


### Save/Load
- [x] implementation for save/load projects

---

## Godot (UI/Frontend)

### Performance & Debugging
- [x] Show audio engine metrics dashboard

### Save/Load
- [x] Save and Load projects (frontend implementation)
- [ ] Welcome Screen with recent projects, templates and settings

### Export
- [ ] Export/rendering
    - [ ] bouncing tracks to audio clip
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
- [ ] TimelineClip should inherit color of the track it's on?

### Clips
- [x] ClipInstances can be dragged to other tracks
- [x] ClipInstances can be resized
- [x] Implement ClipInstance offset property in ticks to allow resizing a clip instance from the left edge, skipping part of the clip's content.
- [x] Multi-select clips with Shift+click < change this to ctrl instead of shift
- [x] Single-click deselects other tracks
- [x] Click empty area deselects all

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
- [ ] Connect TrackItem ui controls to target channel (fader, solo, mute)
- [ ] Delete, Duplicate Channels
- [ ] Smooth meter components (lerp?)

### UI Components & General
- [ ] **CRITICAL**: Undo/Redo using command pattern

### Hardware & MIDI
- [ ] Implement MIDI support
- [ ] Live MIDI input for armed tracks outputs to target track
- [ ] Caps lock toggles computer keyboard as a virtual midi device, mapping q,2,w,3,e,r,5,t,6,y,7,u,i,9,o,0,p,+ to midi keys, default octave 3, Z transposes down, X transposes up, C lowers vel, V increases velocity
- [ ] Modulation
    - [ ] Basic modulation, similar to bitwig, allow any channel and device parameter to be modulatable
