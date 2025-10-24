# TODO

# Save/Load
- [ ] Save and Load projects

## Integration

- [ ] Keep audio engine running live so reverb/delay effects can settle after stopping.
    ^ I think that's implemented? sort of?
    - [ ] Live Midi input for armed tracks outputs to target track


## Audio Backend
- [ ] RMS Metering


# UI
- [ ] Arranger Timeline
    - [ ] Cut/Copy/Paste/Duplicate clips
- [ ] Connect TrackItem ui controls to target channel (fader, solo, mute)
- [ ] TimelineHeader
    - [x] TimelineHeader should be vertically resizable
    - [ ] Auxiliary Rulers/"Tracks" (real-time ruler, chord track, and marking tracks)
    - [ ] Ruler
        - [ ] Click-and-drag enters multidimension zoom mode (moving vertically zooms, horizontally scrolls), or simply emitt a signal and let Arranger/Timeine handle it.
- [ ] Clips
    - [x] ClipInstances can be dragged to other tracks
    - [ ] ClipInstances can be resized
    - [ ] Implement ClipInstance start/end offset properties to denote which portion of the clip is actually active (clip contents should persist and be visible in ClipEditor however). Also need to respect this in TimelineClip.
    - [x] Multi-select clips with Shift+click < change this to ctrl instead of shift
    - [x] Single-click deselects other tracks
    - [x] Click empty area deselects all
- [ ] Smooth meter components (lerp?)
- [ ] **CRITICAL**: Undo/Redo using command pattern
- [x] Save/Load projects
- [ ] Welcome Screen with recent projects, templates and settings
- [x] Browser metadata should save outside user://config.json, maybe user://assets.json
- [ ] Duplicate Channel
- [ ] Duplicate Track
- [ ] TimelineClip should inherit color of the track its on?
- [ ] Arranger: Tracks
    - [x] TrackItem color should inherit from bound channel
    - [x] Reorderable tracks
    - [x] Folder tracks
    - [ ] Right-click popup menu with:
        - [ ] Rename track
        - [ ] Change track color
        - [ ] Duplicate track
- [ ] Clip Editor / NoteEditor
    - [ ] NoteEditor bug: erase-mode is sometimes stuck on even after releasing right-mouse
        ^ maybe VisualNote is consuming the release event somehow?
    - [x] When editing a clip, closing the clip editor, deselecting the clip, reselecting it and opening the clip editor, current notes aren't visible
- [ ] Mixer
    - [x] double-clicking a device in a CompactDeviceList should select the channel and open DeviceLane (if hidden), then grab_focus the DevicePanel there.

## Hardware, MIDI
- [ ] Implement MIDI support
- [ ] Caps lock toggles computer keyboard as a virtual midi device, mapping q,2,w,3,e,r,5,t,6,y,7,u,i,9,o,0,p,+  to midi keys, default octave 3, Z transposes down, X transposes up, C lowers vel, V increases velocity
- [ ] Modulation
  - [ ] Basic modulation, should be similar to bitwig, allow any channel and device parameter to be modulatable

## Built in Devices

### PolySynth
- [ ] ADSR Envelope and Parameters
- [ ] A Filter (LP or HP) and Filter Envelope would be cool, making plucks possible

### Delay
- [ ] Feedback amount parameter
- [ ] BUG if applied on a bus?: wet amount does not properly mix dry and wet. Dry signal is lacking, even at 0.01% wet