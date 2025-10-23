# TODO

# Save/Load
- [ ] Save and Load projects

## Integration

- [x] implement ability to change clips position (and update over OSC)
- [x] move clips between tracks (drag vertically to move to other tracks, maintains relative positions)
- [ ] Keep audio engine running live so reverb/delay effects can settle after stopping
    - [ ] Live Midi input for armed tracks outputs to target track
- [x] Transport control improvements
    - [x] Play: starts from current playhead position
    - [x] Play while playing: pauses and seeks to start_position
    - [x] Shift+Space: smart play/pause toggle (plays if stopped, pause_here if playing)
    - [x] Stop: seeks to start_position if playing, resets to origin if stopped
    - [x] Start position indicator and click-to-set on ruler


## Audio Backend
- [ ] RMS Metering
- [ ] Critical: Need to refactor server.rs, currently monolithic file (!)


# UI
- [ ] Arranger Timeline
    - [x] Horizontal/Time zoom should be relative to current position, not 0,0
        - [x] Cursor-relative zoom (zooms toward cursor position)
        - [x] Snap-to-origin zoom (locks to 0,0 when scrolled close to start)
    - [ ] Cut/Copy/Paste/Duplicate clips
- [ ] Connect TrackItem ui controls to target channel (fader, solo, mute)
- [ ] Ruler
    - [x] Draw arrow at the current start_time (blue arrow pointing up from bottom)
    - [x] Click emits a signal with the tick position (snapped to grid)
    - [x] Clicking sets start_position and seeks playhead there
    - [ ] Click-and-drag enters multidimension zoom mode (moving vertically zooms, horizontally scrolls), or simply emitt a signal and let Arranger/Timeine handle it.
- [ ] TimelineHeader
    - [x] TimelineHeader should be vertically resizable
- [ ] Clips
    - [x] ClipInstances can be dragged to other tracks
    - [ ] ClipInstances can be resized
    - [ ] Implement ClipInstance start/end offset properties to denote which portion of the clip is actually active (clip contents should persist and be visible in ClipEditor however). Also need to respect this in TimelineClip.
    - [x] Multi-select clips with Shift+click < change this to ctrl instead of shift
    - [x] Single-click deselects other tracks
    - [x] Click empty area deselects all
- [ ] Smooth meter components (lerp?)
- [ ] Undo/Redo using command pattern
- [ ] Save/Load projects
- [ ] Browser metadata should save outside user://config.json, maybe user://assets.json
- [ ] Duplicate Channel
- [ ] Duplicate Track
- [ ] TimelineClip should inherit color of the track its on?
- [ ] Tracks
    - [ ] TrackItem color should inherit from bound channel
    - [ ] Context menu for tracks
- [ ] Clip Editor / NoteEditor
    - [ ] NoteEditor bug: erase-mode is sometimes stuck on even after releasing right-mouse
    - [ ] When editing a clip, closing the clip editor, deselecting the clip, reselecting it and opening the clip editor, current notes aren't visible


## Hardware, MIDI
- [ ] Implement MIDI support, should probably have a wrapper around it
- [ ] Caps lock toggles computer keyboard as a fake midi device, mapping q,2,w,3,e,r,5,t,6,y,7,u,i,9,o,0,p,+ mapped to piano octave, default octave 3, Z transposes down, X transposes up, C lowers vel, V increases velocity
- [ ] Modulation
  - [ ] Basic modulation, should be similar to bitwig, allow any channel and device parameter to be modulatable

## Built in Devices

### PolySynth
- [ ] ADSR Envelope and Parameters
- [ ] A Filter (LP or HP) and Filter Envelope would be cool, making plucks possible

### Delay
- [ ] Feedback amount parameter
- [ ] Maybe some stereo/pan effect?
- [ ] BUG if applied on a bus?: wet amount does not properly mix dry and wet. Dry signal is lacking, even at 0.01% wet